import AppKit
import AVFoundation
import Foundation
import Observation
import OmniEngine

enum OutputState: Equatable {
    case idle, connecting, live, reconnecting, failed(String)

    init(_ state: omni_output_state, _ message: String) {
        switch state {
        case OMNI_OUTPUT_CONNECTING: self = .connecting
        case OMNI_OUTPUT_LIVE: self = .live
        case OMNI_OUTPUT_RECONNECTING: self = .reconnecting
        case OMNI_OUTPUT_FAILED: self = .failed(message)
        default: self = .idle
        }
    }
}

struct CanvasSettings {
    var width: UInt32
    var height: UInt32
    var fps: UInt32
    var bitrateKbps: UInt32

    var c: omni_canvas_config {
        omni_canvas_config(width: width, height: height, fps: fps, bitrate_kbps: bitrateKbps)
    }
}

@MainActor
@Observable
final class Engine {
    static let shared = Engine()

    let horizontal = CanvasSettings(width: 1920, height: 1080, fps: 60, bitrateKbps: 6000)
    let vertical = CanvasSettings(width: 1080, height: 1920, fps: 60, bitrateKbps: 6000)
    static let audioKbps: UInt32 = 160

    var destinations = DestinationStore.load() {
        didSet { DestinationStore.save(destinations) }
    }

    private(set) var running = false
    private(set) var startError: String?
    private(set) var renderer = ""
    private(set) var videoEncoder = ""
    private(set) var stats = omni_stats()
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    private(set) var freeDiskBytes: Int64?

    /// State per destination id while streaming.
    private(set) var outputStates: [UUID: OutputState] = [:]
    private(set) var live = false
    private(set) var liveSince: Date?
    private var liveIDs: [UUID] = []
    private var statsTimer: Timer?

    var recordSettings = RecordSettings.load() {
        didSet { recordSettings.save() }
    }
    private(set) var recordState = RecordState.idle
    private(set) var recordingSince: Date?
    private(set) var recordingCanvases: Set<Canvas> = []
    private(set) var recordingBytes: UInt64 = 0
    private(set) var recordError: String?
    private(set) var lastRecordings: [URL] = []
    /// Frames missed since the recording started: (render, encode). Both stay at 0 when nothing stutters.
    private(set) var recordingMissed = (render: UInt32(0), encode: UInt32(0))
    private var missedBaseline = (render: UInt32(0), encode: UInt32(0))
    private var openRecordings: Set<Canvas> = []

    /// Which canvas feeds the virtual camera. Only one at a time: the camera is a single device.
    var virtualCamCanvas: Canvas = Canvas(rawValue: UserDefaults.standard.string(forKey: "virtualCamCanvas") ?? "")
        ?? .horizontal {
        didSet {
            UserDefaults.standard.set(virtualCamCanvas.rawValue, forKey: "virtualCamCanvas")
            if virtualCamActive, oldValue != virtualCamCanvas { startVirtualCam() }
        }
    }
    private(set) var virtualCamActive = false
    private(set) var virtualCamAvailable = false
    private(set) var virtualCamError: String?

    /// Keeps App Nap and timer coalescing away from the render and encode threads
    /// for the app's whole life; frame pacing depends on precise wakeups.
    private var latencyActivity: NSObjectProtocol?
    /// Held while recording or live, so the Mac doesn't idle-sleep mid-session.
    private var sessionActivity: NSObjectProtocol?

    var preferMetal: Bool {
        get { UserDefaults.standard.object(forKey: "preferMetal") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "preferMetal") }
    }

    /// Upload needed for the destinations that are turned on.
    var uploadKbps: UInt32 {
        destinations.filter(\.enabled).reduce(0) {
            $0 + ($1.canvas == .horizontal ? horizontal.bitrateKbps : vertical.bitrateKbps) + Self.audioKbps
        }
    }

    var hevcAvailable: Bool { running && omni_codec_available(OMNI_CODEC_HEVC) }

    /// Asks for camera and mic access before libobs opens the devices: opening an
    /// undecided device blocks the main thread on the system prompt, which froze the
    /// window before it ever appeared. Calls `start()` once both are answered.
    func requestAccessThenStart() {
        for media in [AVMediaType.audio, .video] where AVCaptureDevice.authorizationStatus(for: media) == .notDetermined {
            AVCaptureDevice.requestAccess(for: media) { _ in
                DispatchQueue.main.async { Engine.shared.requestAccessThenStart() }
            }
            return
        }
        // macOS re-shows this prompt on every call, so only ask on the very first
        // launch; after that the Display source offers a link (requestScreenAccess).
        if !CGPreflightScreenCaptureAccess(), !UserDefaults.standard.bool(forKey: "askedScreenAccess") {
            UserDefaults.standard.set(true, forKey: "askedScreenAccess")
            CGRequestScreenCaptureAccess()
        }
        screenAccess = CGPreflightScreenCaptureAccess()
        start()
    }

    func start() {
        guard !running else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OmniCast/plugin_config", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        latencyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Compositing and encoding video")

        var h = horizontal.c, v = vertical.c
        var err = [CChar](repeating: 0, count: 512)
        guard omni_engine_start(support.path, preferMetal, &h, &v, &err, err.count) else {
            startError = String(cString: err)
            return
        }

        running = true
        renderer = String(cString: omni_engine_renderer())
        videoEncoder = String(cString: omni_engine_video_encoder())
        applySavedMixer()

        omni_set_status_callback({ index, state, message, _ in
            let msg = message.map { String(cString: $0) } ?? ""
            let index = Int(index)
            DispatchQueue.main.async {
                Engine.shared.outputChanged(index: index, state: OutputState(state, msg))
            }
        }, nil)

        omni_set_record_callback({ canvas, active, message, _ in
            let msg = message.map { String(cString: $0) } ?? ""
            let canvas: Canvas = canvas == OMNI_CANVAS_VERTICAL ? .vertical : .horizontal
            DispatchQueue.main.async {
                Engine.shared.recordingChanged(canvas: canvas, active: active, message: msg)
            }
        }, nil)

        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { Engine.shared.refreshStats() }
        }
        refreshStats()
        virtualCamAvailable = omni_virtualcam_available()
    }

    func shutdown() {
        guard running else { return }
        statsTimer?.invalidate()
        omni_engine_shutdown()
        running = false
        latencyActivity.map(ProcessInfo.processInfo.endActivity)
        latencyActivity = nil
        updateSessionActivity()
    }

    // MARK: Streaming

    func goLive() {
        let active = destinations.filter { $0.enabled && $0.isReady }
        guard !active.isEmpty else { return }

        // libobs copies these into its own settings, so they only need to
        // outlive the omni_stream_start call.
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func c(_ s: String) -> UnsafePointer<CChar> {
            let p = strdup(s)!
            owned.append(p)
            return UnsafePointer(p)
        }
        let dests = active.map {
            omni_destination(name: c($0.name), server: c($0.server), key: c($0.key),
                             canvas: $0.canvas == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL)
        }

        var err = [CChar](repeating: 0, count: 512)
        liveIDs = active.map(\.id)
        outputStates = [:]
        let ok = omni_stream_start(dests, Int32(dests.count), &err, err.count)

        if ok {
            live = true
            liveSince = Date()
        } else {
            startError = String(cString: err)
        }
        updateSessionActivity()
    }

    func stopLive() {
        omni_stream_stop()
        live = false
        liveSince = nil
        outputStates = [:]
        updateSessionActivity()
    }

    func state(for id: UUID) -> OutputState { outputStates[id] ?? .idle }

    /// Canvases that at least one live destination is using.
    var liveCanvases: Set<Canvas> {
        guard live else { return [] }
        return Set(destinations.filter { liveIDs.contains($0.id) }.map(\.canvas))
    }

    func outputStats(for id: UUID) -> (dropped: Int, bytes: UInt64)? {
        guard let index = liveIDs.firstIndex(of: id) else { return nil }
        var dropped: Int32 = 0
        var bytes: UInt64 = 0
        guard omni_stream_output_stats(Int32(index), &dropped, &bytes) else { return nil }
        return (Int(dropped), bytes)
    }

    private func outputChanged(index: Int, state: OutputState) {
        guard live, index < liveIDs.count else { return }
        outputStates[liveIDs[index]] = state
    }

    // MARK: Recording

    func toggleRecording() {
        switch recordState {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .finishing: break
        }
    }

    /// `override` records with other settings without saving them (the benchmark uses it).
    func startRecording(override: RecordSettings? = nil) {
        guard running, recordState == .idle else { return }
        let s = override ?? recordSettings
        let canvases = s.target.canvases
        var err = [CChar](repeating: 0, count: 512)
        let ok = s.folder.withCString { folder in
            var cfg = omni_record_config(
                directory: folder, codec: s.codec.c, quality: s.quality.value,
                horizontal: canvases.contains(.horizontal), vertical: canvases.contains(.vertical),
                split_audio: s.splitAudio)
            return omni_record_start(&cfg, &err, err.count)
        }
        guard ok else {
            recordError = String(cString: err)
            return
        }
        recordError = nil
        recordState = .recording
        recordingSince = Date()
        recordingCanvases = canvases
        openRecordings = canvases
        recordingBytes = 0
        omni_get_stats(&stats)
        missedBaseline = (stats.lagged_frames, skippedFrames(for: canvases))
        recordingMissed = (0, 0)
        updateSessionActivity()
    }

    func stopRecording() {
        guard recordState == .recording else { return }
        recordState = .finishing
        omni_record_stop()
    }

    func revealLastRecording() {
        guard !lastRecordings.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(lastRecordings)
    }

    private func recordingChanged(canvas: Canvas, active: Bool, message: String) {
        if !message.isEmpty { recordError = message }
        guard !active else { return }
        openRecordings.remove(canvas)
        guard openRecordings.isEmpty, recordState != .idle else { return }
        lastRecordings = recordingCanvases.sorted { $0.rawValue < $1.rawValue }.compactMap { c in
            let path = String(cString: omni_record_path(c == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL))
            return path.isEmpty ? nil : URL(fileURLWithPath: path)
        }
        recordState = .idle
        recordingSince = nil
        recordingCanvases = []
        updateSessionActivity()
    }

    private func skippedFrames(for canvases: Set<Canvas>) -> UInt32 {
        (canvases.contains(.horizontal) ? stats.skipped_frames_h : 0)
            + (canvases.contains(.vertical) ? stats.skipped_frames_v : 0)
    }

    // MARK: Virtual camera

    func toggleVirtualCam() {
        virtualCamActive ? stopVirtualCam() : startVirtualCam()
    }

    /// Starts the camera on `virtualCamCanvas`, or switches it there if it's already on.
    func startVirtualCam() {
        guard running else { return }
        var err = [CChar](repeating: 0, count: 512)
        let canvas = virtualCamCanvas == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL
        virtualCamActive = omni_virtualcam_start(canvas, &err, err.count)
        virtualCamError = virtualCamActive ? nil : String(cString: err)
        virtualCamAvailable = omni_virtualcam_available()
        updateSessionActivity()
    }

    func stopVirtualCam() {
        omni_virtualcam_stop()
        virtualCamActive = false
        updateSessionActivity()
    }

    // MARK: Sources and audio

    /// Real cameras only: virtual ones (OBS, Streamlabs) would loop OmniCast's own feed back in.
    var cameraDevices: [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video, position: .unspecified
        ).devices.filter { !$0.localizedName.lowercased().contains("virtual") }
    }

    private(set) var cameraDevice = ""

    /// What the screen slot shows; nil means the main display (the engine's default).
    private(set) var screenTarget: ScreenTarget?

    func setScreenTarget(_ target: ScreenTarget) {
        omni_screen_set_target(target.kind.c, target.id)
        screenTarget = target
        if let data = try? JSONEncoder().encode(target) {
            UserDefaults.standard.set(data, forKey: "screenTarget")
        }
    }

    private func applySavedScreenTarget() {
        guard let data = UserDefaults.standard.data(forKey: "screenTarget"),
              let saved = try? JSONDecoder().decode(ScreenTarget.self, from: data) else {
            screenTarget = ScreenTarget.mainDisplay
            return
        }
        // A window or app that's closed falls back to the main display for this
        // session, without forgetting the saved choice.
        if let target = saved.resolved() {
            omni_screen_set_target(target.kind.c, target.id)
            screenTarget = target
        } else {
            screenTarget = ScreenTarget.mainDisplay
        }
    }
    /// Whether macOS lets OmniCast capture the screen; it only changes after a relaunch.
    private(set) var screenAccess = true

    func requestScreenAccess() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func setCamera(_ uniqueID: String) {
        UserDefaults.standard.set(uniqueID, forKey: "cameraDevice")
        omni_camera_set_device(uniqueID)
        cameraDevice = uniqueID
    }

    func setSource(_ name: String, enabled: Bool) {
        omni_source_set_enabled(name, enabled)
    }

    private func applySavedMixer() {
        Mixer.shared.apply()
        if let saved = UserDefaults.standard.string(forKey: "cameraDevice"),
           cameraDevices.contains(where: { $0.uniqueID == saved }) {
            omni_camera_set_device(saved)
        }
        cameraDevice = String(cString: omni_camera_device())
        applySavedScreenTarget()
        for name in ["Display", "Camera"] where UserDefaults.standard.object(forKey: "source.\(name)") != nil {
            setSource(name, enabled: UserDefaults.standard.bool(forKey: "source.\(name)"))
        }
    }

    // MARK: Health

    private func updateSessionActivity() {
        let busy = live || recordState != .idle || virtualCamActive
        if busy, sessionActivity == nil {
            sessionActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
                reason: "Recording, streaming or virtual camera")
        } else if !busy, let activity = sessionActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sessionActivity = nil
        }
    }

    private func refreshStats() {
        omni_get_stats(&stats)
        // The extension's device can show up in this process a moment after camera
        // access is granted, so keep looking until it does.
        if !virtualCamAvailable { virtualCamAvailable = omni_virtualcam_available() }
        thermal = ProcessInfo.processInfo.thermalState
        let folder = URL(fileURLWithPath: recordSettings.folder)
        let probe = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        freeDiskBytes = (try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage

        if recordState != .idle {
            recordingBytes = recordingCanvases.reduce(0) {
                $0 + omni_record_bytes($1 == .vertical ? OMNI_CANVAS_VERTICAL : OMNI_CANVAS_HORIZONTAL)
            }
            recordingMissed = (stats.lagged_frames &- missedBaseline.render,
                               skippedFrames(for: recordingCanvases) &- missedBaseline.encode)
        }
    }
}
