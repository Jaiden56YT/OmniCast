import OmniEngine
import SwiftUI

struct ContentView: View {
    @Bindable private var engine = Engine.shared
    @State private var editing: Destination?
    @AppStorage("showPreview") private var showPreview = true

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if let error = engine.startError ?? engine.recordError ?? engine.virtualCamError {
                Banner(text: error)
            }
            stage
            HStack(alignment: .top, spacing: 10) {
                SourcesPanel(showPreview: $showPreview).frame(width: 190)
                AudioMixerPanel().frame(width: 250)
                DestinationsPanel(editing: $editing)
                ControlsPanel().frame(width: 250)
            }
            .padding(10)
            // Every panel gets the height of the tallest one's content, so nothing is clipped.
            .fixedSize(horizontal: false, vertical: true)
            StatusBar()
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { dest in
            DestinationEditor(destination: dest) { updated in
                if let i = engine.destinations.firstIndex(where: { $0.id == updated.id }) {
                    engine.destinations[i] = updated
                } else {
                    engine.destinations.append(updated)
                }
            }
        }
    }

    private var stage: some View {
        HStack(spacing: 14) {
            CanvasPreview(canvas: .horizontal, showPreview: showPreview)
            CanvasPreview(canvas: .vertical, showPreview: showPreview)
        }
        .padding(14)
        .frame(minHeight: 340, maxHeight: .infinity)
        .background(Theme.stage)
    }
}

// MARK: - Top bar

struct TopBar: View {
    private var engine: Engine { .shared }

    var body: some View {
        HStack(spacing: 10) {
            Text("OmniCast").font(.system(size: 13, weight: .semibold))
            Spacer()
            if let since = engine.recordingSince {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Badge(text: "REC " + formatDuration(ctx.date.timeIntervalSince(since)), color: Theme.record)
                }
            }
            if let since = engine.liveSince {
                TimelineView(.periodic(from: since, by: 1)) { ctx in
                    Badge(text: "LIVE " + formatDuration(ctx.date.timeIntervalSince(since)), color: Theme.live)
                }
            }
            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.background)
        .overlay(alignment: .bottom) { Theme.hairline.frame(height: 1) }
    }
}

struct Banner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.record.opacity(0.85))
    }
}

// MARK: - Previews

struct CanvasPreview: View {
    let canvas: Canvas
    let showPreview: Bool
    private var engine: Engine { .shared }

    private var aspect: CGFloat { canvas == .horizontal ? 16.0 / 9.0 : 9.0 / 16.0 }
    private var size: CanvasSettings { canvas == .horizontal ? engine.horizontal : engine.vertical }
    private var recording: Bool { engine.recordingCanvases.contains(canvas) }
    private var live: Bool { engine.liveCanvases.contains(canvas) }
    private var camera: Bool { engine.virtualCamActive && engine.virtualCamCanvas == canvas }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(canvas == .horizontal ? "Horizontal" : "Vertical")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(size.width)×\(size.height) · \(size.fps) fps")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textDim)
                Spacer(minLength: 0)
                if recording { Badge(text: "REC", color: Theme.record) }
                if live { Badge(text: "LIVE", color: Theme.live) }
                if camera { Badge(text: "CAM", color: Theme.camera) }
            }
            .frame(height: 22)
            ZStack {
                if engine.running {
                    PreviewView(canvas: canvas, enabled: showPreview)
                    if !showPreview {
                        Label("Preview paused", systemImage: "eye.slash")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                    }
                } else {
                    Color.black
                }
                if canvas == .horizontal, CallOverlay.shared.arranging {
                    CallArrangeLayer()
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(recording ? Theme.record : live ? Theme.live : Theme.hairline,
                              lineWidth: recording || live ? 2 : 1))
        }
        .fixedSize(horizontal: canvas == .vertical, vertical: false)
    }
}

// MARK: - Sources

struct SourcesPanel: View {
    @Binding var showPreview: Bool
    @State private var display = UserDefaults.standard.object(forKey: "source.Display") as? Bool ?? true
    @State private var camera = UserDefaults.standard.object(forKey: "source.Camera") as? Bool ?? true

    var body: some View {
        Panel(title: "Sources") {
            VStack(alignment: .leading, spacing: 6) {
                SourceRow(name: "Display", icon: "display", isOn: $display)
                ScreenPicker()
                if !Engine.shared.screenAccess {
                    Button("Allow screen access…") { Engine.shared.requestScreenAccess() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .padding(.leading, 26)
                        .help("Turn on OmniCast in System Settings → Privacy & Security → Screen & System Audio Recording, then reopen OmniCast")
                }
                SourceRow(name: "Camera", icon: "video", isOn: $camera)
                CameraPicker()
                CallSourceRow()
                SpotifySourceRow()
                Spacer(minLength: 8)
                Theme.hairline.frame(height: 1)
                Toggle(isOn: $showPreview) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Live preview").font(.system(size: 12))
                        Text("Off saves GPU time").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        }
    }
}

/// Chooses what the screen slot captures. The lists are read when the popover
/// opens, so windows opened since launch show up.
struct ScreenPicker: View {
    @State private var open = false
    private var engine: Engine { .shared }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: engine.screenTarget?.kind.icon ?? "display")
                Text(engine.screenTarget?.name ?? "Main display").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 26)
        .disabled(!engine.running)
        .help("Capture a display, one window, an app, or a capture card")
        .popover(isPresented: $open, arrowEdge: .trailing) {
            ScreenTargetList { target in
                engine.setScreenTarget(target)
                open = false
            }
        }
    }
}

struct ScreenTargetList: View {
    let onPick: (ScreenTarget) -> Void
    @State private var displays: [ScreenTarget] = []
    @State private var windows: [ScreenTarget] = []
    @State private var apps: [ScreenTarget] = []
    @State private var devices: [ScreenTarget] = []
    private var current: ScreenTarget? { Engine.shared.screenTarget }

    var body: some View {
        List {
            section("Displays", displays)
            section("Capture devices", devices, empty: "Plug in a capture card to see it here")
            section("Windows", windows, empty: "No windows found")
            section("Apps", apps)
            if !Engine.shared.screenAccess {
                Text("Window titles and screen capture need Screen Recording access.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 320, height: 420)
        .onAppear {
            displays = ScreenTarget.displays()
            windows = ScreenTarget.windows()
            apps = ScreenTarget.apps()
            devices = ScreenTarget.devices()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [ScreenTarget], empty: String? = nil) -> some View {
        Section(title) {
            if items.isEmpty, let empty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(items) { target in
                Button { onPick(target) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: target.kind.icon).frame(width: 16).foregroundStyle(.secondary)
                        Text(target.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                        if target.kind == current?.kind, target.id == current?.id {
                            Image(systemName: "checkmark").foregroundStyle(Theme.good)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct CameraPicker: View {
    @Bindable private var engine = Engine.shared

    var body: some View {
        Picker("Camera device", selection: Binding(get: { engine.cameraDevice },
                                                   set: { engine.setCamera($0) })) {
            ForEach(engine.cameraDevices, id: \.uniqueID) { device in
                Text(device.localizedName).tag(device.uniqueID)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .padding(.leading, 26)
        .disabled(!engine.running)
        .help("Which camera the Camera source shows")
    }
}

struct SourceRow: View {
    let name: String
    let icon: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
            UserDefaults.standard.set(isOn, forKey: "source.\(name)")
            Engine.shared.setSource(name, enabled: isOn)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).frame(width: 18)
                Text(name).font(.system(size: 12))
                Spacer()
                Image(systemName: isOn ? "eye" : "eye.slash")
                    .foregroundStyle(isOn ? .white.opacity(0.8) : Theme.textDim)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(isOn ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(isOn ? 1 : 0.6)
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide \(name)" : "Show \(name)")
    }
}

// MARK: - Controls

struct ControlsPanel: View {
    @Bindable private var engine = Engine.shared

    var body: some View {
        Panel(title: "Controls") {
            VStack(spacing: 10) {
                recordSection
                Theme.hairline.frame(height: 1)
                liveSection
                Theme.hairline.frame(height: 1)
                virtualCamSection
            }
        }
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Record", selection: $engine.recordSettings.target) {
                ForEach(RecordTarget.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(engine.recordState != .idle)

            Button { engine.toggleRecording() } label: {
                HStack(spacing: 8) {
                    Image(systemName: engine.recordState == .idle ? "record.circle" : "stop.fill")
                    Text(recordTitle).fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            .buttonStyle(ActionButtonStyle(color: Theme.record, active: engine.recordState != .idle))
            .disabled(!engine.running || engine.recordState == .finishing)

            HStack {
                Text(recordDetail).lineLimit(1)
                Spacer()
                if engine.recordState == .idle, !engine.lastRecordings.isEmpty {
                    Button("Show in Finder") { engine.revealLastRecording() }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.textDim)
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                engine.live ? engine.stopLive() : engine.goLive()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: engine.live ? "stop.fill" : "dot.radiowaves.left.and.right")
                    Text(engine.live ? "End Stream" : "Go Live").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            .buttonStyle(ActionButtonStyle(color: Theme.live, active: engine.live))
            .disabled(!engine.running || (!engine.live && !engine.destinations.contains { $0.enabled && $0.isReady }))

            let count = engine.destinations.filter { $0.enabled && $0.isReady }.count
            Text("\(count) destination\(count == 1 ? "" : "s") · "
                 + String(format: "%.1f Mbps up", Double(engine.uploadKbps) / 1000))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textDim)
        }
    }

    /// One canvas at a time; switching it while on moves the camera over without stopping.
    private var virtualCamSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "web.camera")
                .foregroundStyle(engine.virtualCamActive ? Theme.camera : Theme.textDim)
            Text("Virtual Camera").font(.system(size: 12))
            Spacer(minLength: 4)
            Picker("Canvas", selection: $engine.virtualCamCanvas) {
                Text("16:9").tag(Canvas.horizontal)
                Text("9:16").tag(Canvas.vertical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Which canvas apps like Zoom or Discord see. 9:16 is shown with side bars, since the camera is 16:9.")
            Toggle("", isOn: Binding(get: { engine.virtualCamActive }, set: { _ in engine.toggleVirtualCam() }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(engine.virtualCamAvailable
                      ? "Shows up as \"OBS Virtual Camera\" in other apps"
                      : "OBS Virtual Camera isn't installed: open OBS once and click Start Virtual Camera")
        }
        .disabled(!engine.running)
    }

    private var recordTitle: String {
        switch engine.recordState {
        case .idle: "Start Recording"
        case .recording: "Stop Recording"
        case .finishing: "Saving…"
        }
    }

    private var recordDetail: String {
        let s = engine.recordSettings
        switch engine.recordState {
        case .idle:
            return "\(s.codec == .hevc && engine.hevcAvailable ? "HEVC" : "H.264") · \(s.quality.label)"
        case .recording, .finishing:
            let missed = engine.recordingMissed.render + engine.recordingMissed.encode
            return "\(formatBytes(engine.recordingBytes)) · \(missed) missed frames"
        }
    }
}

/// Filled when active (recording/live), tinted outline when ready.
struct ActionButtonStyle: ButtonStyle {
    let color: Color
    let active: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(active ? .white : enabled ? color : Theme.textDim)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(active ? color : color.opacity(enabled ? 0.14 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(active ? .clear : color.opacity(enabled ? 0.45 : 0.1)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Status bar

struct StatusBar: View {
    private var engine: Engine { .shared }

    var body: some View {
        HStack(spacing: 14) {
            Text("\(engine.renderer) · \(encoderLabel)")
            Divider().frame(height: 10)
            Text(String(format: "%.0f fps", engine.stats.fps))
                .foregroundStyle(engine.running && engine.stats.fps < Double(engine.horizontal.fps) - 1 ? Theme.warn : Theme.textDim)
            Text(String(format: "render %.2f ms", engine.stats.render_ms))
            Text("missed: render \(engine.stats.lagged_frames) · encode \(engine.stats.skipped_frames_h + engine.stats.skipped_frames_v)")
                .help("Frames the compositor or the encoders couldn't deliver on time since launch. 0 means no stutter.")
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(thermalColor).frame(width: 6, height: 6)
                Text("Thermal \(thermalLabel)")
            }
            .help("MacBook Air has no fan: at Serious or Critical the chip slows down and frames can drop.")
            if let free = engine.freeDiskBytes {
                Text("\(formatBytes(free)) free")
                    .foregroundStyle(free < 10_000_000_000 ? Theme.warn : Theme.textDim)
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.textDim)
        .padding(.horizontal, 14)
        .frame(height: 26)
        .background(Theme.background)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }

    private var encoderLabel: String {
        let id = engine.videoEncoder
        guard id.contains("videotoolbox") else { return id }
        if id.contains("SW") || id.contains("software") { return "VideoToolbox (software)" }
        return engine.hevcAvailable ? "Media engine H.264 + HEVC" : "Media engine H.264"
    }

    private var thermalLabel: String {
        switch engine.thermal {
        case .nominal: "OK"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "?"
        }
    }

    private var thermalColor: Color {
        switch engine.thermal {
        case .nominal: Theme.good
        case .fair: Theme.warn
        default: Theme.record
        }
    }
}
