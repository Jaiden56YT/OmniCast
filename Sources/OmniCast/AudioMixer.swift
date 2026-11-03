import AppKit
import OmniEngine
import SwiftUI

/// Wave Link-style mixer: every channel has a stream level and a monitor level.
/// Channels are the mic, system audio, and any apps you add; app audio is taken
/// out of system audio and silenced at its source while OmniCast runs, so you hear
/// it only through the monitor mix.
@MainActor
@Observable
final class Mixer {
    static let shared = Mixer()

    struct Channel: Identifiable, Codable, Equatable {
        var id: String // "mic", "system", or an app's bundle ID
        var name: String
        var stream = 1.0
        var streamMuted = false
        var monitor = 1.0
        var monitorMuted = false

        var isApp: Bool { id != "mic" && id != "system" && id != Mixer.captureID }
    }

    static let pluginNames = ["STACKS", "Muze"]
    /// The capture card's channel (the screen slot's capture device, e.g. a game).
    nonisolated static let captureID = "capture"
    nonisolated static let spotifyID = "com.spotify.client"

    /// Shown only while the screen slot is a capture device.
    private(set) var captureShown = false

    /// Channels to show: the capture card's only while it's in use.
    var visibleChannels: [Channel] {
        channels.filter { $0.id != Self.captureID || (captureShown && indices[Self.captureID] != nil) }
    }

    private(set) var channels: [Channel]
    /// Engine channel index per channel id, once the engine is running.
    private(set) var indices: [String: Int32] = [:]

    var monitorDevice: String = UserDefaults.standard.string(forKey: "monitorDevice") ?? "" {
        didSet {
            UserDefaults.standard.set(monitorDevice, forKey: "monitorDevice")
            omni_monitor_set_device(monitorDevice)
        }
    }

    var micInput: Int = UserDefaults.standard.object(forKey: "micInput") as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(micInput, forKey: "micInput")
            omni_mic_set_input(omni_mic_input(rawValue: UInt32(micInput)))
        }
    }

    private(set) var pluginsOn: [Bool] = (UserDefaults.standard.array(forKey: "micPlugins") as? [Bool]) ?? [false, false]

    private init() {
        if let data = UserDefaults.standard.data(forKey: "mixerChannels"),
           let saved = try? JSONDecoder().decode([Channel].self, from: data) {
            channels = saved
        } else {
            // Carries over the levels from the old two-fader mixer. The mic starts
            // out of the monitor mix: most people don't want to hear themselves.
            let d = UserDefaults.standard
            channels = [
                Channel(id: "mic", name: "Mic", stream: d.object(forKey: "fader.mic") as? Double ?? 1,
                        streamMuted: d.bool(forKey: "muted.mic"), monitorMuted: true),
                Channel(id: "system", name: "System", stream: d.object(forKey: "fader.desktop") as? Double ?? 1,
                        streamMuted: d.bool(forKey: "muted.desktop")),
            ]
        }
    }

    var appsSupported: Bool { omni_mixer_apps_supported() }

    /// Pushes the saved mixer into the engine once it has started.
    func apply() {
        indices = ["mic": Int32(OMNI_CHANNEL_MIC), "system": Int32(OMNI_CHANNEL_SYSTEM)]
        addSpotifyOnce()
        for ch in channels where ch.isApp {
            let i = omni_mixer_add_app(ch.id)
            if i >= 0 { indices[ch.id] = i }
        }
        channels.forEach(push)
        omni_monitor_set_device(monitorDevice)
        omni_mic_set_input(omni_mic_input(rawValue: UInt32(micInput)))
        for (p, on) in pluginsOn.enumerated() where on {
            omni_plugin_set_enabled(omni_plugin(rawValue: UInt32(p)), true)
        }
    }

    /// Spotify gets a channel by default, once: removing it afterwards sticks.
    private func addSpotifyOnce() {
        let key = "mixer.addedSpotify"
        guard appsSupported, !UserDefaults.standard.bool(forKey: key),
              NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.spotifyID) != nil else { return }
        UserDefaults.standard.set(true, forKey: key)
        if !channels.contains(where: { $0.id == Self.spotifyID }) {
            channels.append(Channel(id: Self.spotifyID, name: "Spotify"))
            save()
        }
    }

    /// Call when the screen slot changes. `deviceName` is the capture device's name,
    /// or nil when the slot shows a display, window or app.
    func captureDeviceChanged(_ deviceName: String?) {
        let i = omni_mixer_capture_channel()
        guard let deviceName, i >= 0 else {
            // The engine freed the channel; its slot may go to an app next.
            captureShown = false
            indices.removeValue(forKey: Self.captureID)
            return
        }
        indices[Self.captureID] = i
        if let k = channels.firstIndex(where: { $0.id == Self.captureID }) {
            channels[k].name = deviceName
        } else {
            // Monitor on from the start: the point is to hear the game.
            channels.append(Channel(id: Self.captureID, name: deviceName))
        }
        captureShown = true
        save()
        if let ch = channels.first(where: { $0.id == Self.captureID }) { push(ch) }
    }

    func update(_ ch: Channel) {
        guard let i = channels.firstIndex(where: { $0.id == ch.id }), channels[i] != ch else { return }
        channels[i] = ch
        push(ch)
        save()
    }

    func addApp(bundleID: String, name: String) {
        guard !channels.contains(where: { $0.id == bundleID }) else { return }
        let i = omni_mixer_add_app(bundleID)
        guard i >= 0 else { return }
        let ch = Channel(id: bundleID, name: name)
        indices[bundleID] = i
        channels.append(ch)
        push(ch)
        save()
    }

    func remove(_ id: String) {
        if let i = indices.removeValue(forKey: id) { omni_mixer_remove_app(i) }
        channels.removeAll { $0.id == id }
        save()
    }

    func setPlugin(_ p: Int, on: Bool) {
        pluginsOn[p] = on
        UserDefaults.standard.set(pluginsOn, forKey: "micPlugins")
        omni_plugin_set_enabled(omni_plugin(rawValue: UInt32(p)), on)
    }

    func openPlugin(_ p: Int) {
        if !pluginsOn[p] {
            pluginsOn[p] = true
            UserDefaults.standard.set(pluginsOn, forKey: "micPlugins")
        }
        omni_plugin_show_editor(omni_plugin(rawValue: UInt32(p)))
    }

    func pluginInstalled(_ p: Int) -> Bool { omni_plugin_installed(omni_plugin(rawValue: UInt32(p))) }

    /// Peak levels in dBFS, before either fader. Cheap enough to call every frame.
    nonisolated static func levels(_ index: Int32) -> (Float, Float) {
        var l: Float = -.infinity, r: Float = -.infinity
        omni_mixer_levels(index, &l, &r)
        return (l, r)
    }

    /// Fader position 0...1 maps to gain with a cubic curve, like OBS's mixer.
    static func gain(_ fader: Double) -> Float { Float(pow(fader, 3)) }

    private func push(_ ch: Channel) {
        guard let i = indices[ch.id] else { return }
        omni_mixer_set_stream(i, Self.gain(ch.stream), ch.streamMuted)
        omni_mixer_set_monitor(i, Self.gain(ch.monitor), ch.monitorMuted)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(channels) {
            UserDefaults.standard.set(data, forKey: "mixerChannels")
        }
    }
}

// MARK: - Views

struct AudioMixerPanel: View {
    private var mixer: Mixer { .shared }

    var body: some View {
        Panel(title: "Audio") {
            HStack(spacing: 10) {
                MonitorPicker()
                if mixer.appsSupported { AddAppMenu() }
            }
        } content: {
            let rows = VStack(spacing: 12) {
                ForEach(mixer.visibleChannels) { ChannelStrip(channel: $0) }
            }
            // Four strips fit; more scroll, so the panel row doesn't grow over the preview.
            if mixer.visibleChannels.count > 4 {
                ScrollView { rows.padding(.trailing, 8) }.frame(height: 4 * 74)
            } else {
                rows
            }
        }
    }
}

struct ChannelStrip: View {
    let channel: Mixer.Channel
    @State private var fx = false
    private var mixer: Mixer { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                icon.frame(width: 14, height: 14)
                Text(channel.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
                if channel.id == "mic" {
                    Button { fx.toggle() } label: {
                        Text("FX").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(mixer.pluginsOn.contains(true) ? Theme.good : Theme.textDim)
                    }
                    .buttonStyle(.borderless)
                    .help("Mic input and plugins")
                    .popover(isPresented: $fx, arrowEdge: .trailing) { MicSettings() }
                }
                if channel.isApp {
                    Button { mixer.remove(channel.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.textDim)
                    .help("Remove; the app plays normally again")
                }
            }
            LevelMeter(index: mixer.indices[channel.id], muted: channel.streamMuted && channel.monitorMuted)
                .frame(height: 6)
            FaderRow(symbol: "dot.radiowaves.left.and.right", label: "Stream",
                     value: binding(\.stream), muted: binding(\.streamMuted))
            FaderRow(symbol: "headphones", label: "Monitor",
                     value: binding(\.monitor), muted: binding(\.monitorMuted))
        }
    }

    @ViewBuilder private var icon: some View {
        if channel.id == "mic" {
            Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        } else if channel.id == "system" {
            Image(systemName: "macwindow").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: channel.id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else {
            Image(systemName: "app").font(.system(size: 11)).foregroundStyle(Theme.textDim)
        }
    }

    private func binding<T>(_ key: WritableKeyPath<Mixer.Channel, T>) -> Binding<T> {
        Binding(get: { channel[keyPath: key] }, set: { new in
            var ch = channel
            ch[keyPath: key] = new
            Mixer.shared.update(ch)
        })
    }
}

struct FaderRow: View {
    let symbol: String
    let label: String
    @Binding var value: Double
    @Binding var muted: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9)).foregroundStyle(Theme.textDim).frame(width: 14)
                .help(label)
            Slider(value: $value, in: 0...1).controlSize(.mini).opacity(muted ? 0.4 : 1)
            Text(gainLabel).font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim)
                .frame(width: 44, alignment: .trailing)
            Button { muted.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10))
                    .frame(width: 16)
                    .foregroundStyle(muted ? Theme.record : .white.opacity(0.75))
            }
            .buttonStyle(.borderless)
            .help(muted ? "Unmute in the \(label.lowercased()) mix" : "Mute in the \(label.lowercased()) mix")
        }
    }

    private var gainLabel: String {
        let db = 20 * log10(pow(value, 3))
        return db < -60 ? "−∞ dB" : String(format: "%.1f dB", db)
    }
}

/// Picks where the monitor mix plays. The list is read when the menu opens.
struct MonitorPicker: View {
    @State private var devices: [(uid: String, name: String)] = []
    private var mixer: Mixer { .shared }

    var body: some View {
        Menu {
            Picker("Monitor output", selection: Binding(get: { mixer.monitorDevice },
                                                        set: { mixer.monitorDevice = $0 })) {
                Text("System output").tag("")
                ForEach(devices, id: \.uid) { Text($0.name).tag($0.uid) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "headphones")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Where the monitor mix plays")
        .onAppear(perform: load)
        .onHover { if $0 { load() } }
    }

    private func load() {
        var buf = [omni_audio_device](repeating: omni_audio_device(), count: 32)
        let n = Int(omni_monitor_devices(&buf, Int32(buf.count)))
        devices = buf.prefix(n).map { d in
            var d = d
            let uid = withUnsafeBytes(of: &d.uid) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let name = withUnsafeBytes(of: &d.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return (uid, name)
        }
    }
}

/// Adds a channel for a running app.
struct AddAppMenu: View {
    @State private var apps: [NSRunningApplication] = []
    private var mixer: Mixer { .shared }

    var body: some View {
        Menu {
            if apps.isEmpty { Text("No other apps running") }
            ForEach(apps, id: \.processIdentifier) { app in
                Button {
                    mixer.addApp(bundleID: app.bundleIdentifier!, name: app.localizedName ?? app.bundleIdentifier!)
                } label: {
                    if let icon = app.icon {
                        Label { Text(app.localizedName ?? "") } icon: { Image(nsImage: icon) }
                    } else {
                        Text(app.localizedName ?? "")
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Give an app its own channel")
        .onAppear(perform: load)
        .onHover { if $0 { load() } }
    }

    private func load() {
        let taken = Set(mixer.channels.map(\.id))
        apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !taken.contains($0.bundleIdentifier!)
            }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }
}

struct MicSettings: View {
    private var mixer: Mixer { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Input").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textDim)
            Picker("", selection: Binding(get: { mixer.micInput }, set: { mixer.micInput = $0 })) {
                Text("In 1").tag(0)
                Text("In 2").tag(1)
                Text("Stereo").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Which input of your interface the mic is plugged into")

            Text("Plugins").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textDim)
            ForEach(Mixer.pluginNames.indices, id: \.self) { p in
                HStack {
                    Toggle(Mixer.pluginNames[p], isOn: Binding(get: { mixer.pluginsOn[p] },
                                                              set: { mixer.setPlugin(p, on: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    Spacer()
                    Button("Open") { mixer.openPlugin(p) }
                        .controlSize(.small)
                }
                .disabled(!mixer.pluginInstalled(p))
                .help(mixer.pluginInstalled(p) ? "" : "\(Mixer.pluginNames[p]) isn't installed")
            }
            Text("Turned-off plugins aren't loaded at all.")
                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
        .padding(12)
        .frame(width: 230)
    }
}

/// Stereo peak meter, OBS-style colour zones. Drawn with Canvas from a 30 Hz
/// timeline that reads the audio thread's levels directly, so it never touches
/// observation or re-lays-out the window.
struct LevelMeter: View {
    let index: Int32?
    let muted: Bool
    @State private var hold = MeterHold()

    private static let floor: Float = -60

    private static let zones = Gradient(stops: [
        .init(color: Theme.good, location: 0),
        .init(color: Theme.good, location: 0.62),
        .init(color: Theme.warn, location: 0.78),
        .init(color: Theme.record, location: 0.9),
    ])
    private static let mutedZones = Gradient(colors: [.gray, .gray])

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            SwiftUI.Canvas { gc, size in
                draw(in: &gc, size: size, date: context.date)
            }
        }
    }

    private func draw(in gc: inout GraphicsContext, size: CGSize, date: Date) {
        let (l, r) = index.map(Mixer.levels) ?? (-.infinity, -.infinity)
        let shown = hold.update(l, r, at: date)
        let barH = (size.height - 1) / 2
        let fill = GraphicsContext.Shading.linearGradient(
            muted ? Self.mutedZones : Self.zones, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0))
        for (i, db) in [shown.0, shown.1].enumerated() {
            let y = CGFloat(i) * (barH + 1)
            let track = CGRect(x: 0, y: y, width: size.width, height: barH)
            gc.fill(Path(roundedRect: track, cornerRadius: 1), with: .color(.white.opacity(0.06)))
            let fraction = CGFloat(max(0, min(1, (db - Self.floor) / -Self.floor)))
            guard fraction > 0 else { continue }
            let bar = CGRect(x: 0, y: y, width: size.width * fraction, height: barH)
            gc.fill(Path(roundedRect: bar, cornerRadius: 1), with: fill)
        }
    }
}

/// Instant attack, smooth fall, so the meter is readable at 30 Hz.
final class MeterHold {
    private var shown: (Float, Float) = (-.infinity, -.infinity)
    private var last = Date()

    func update(_ l: Float, _ r: Float, at date: Date) -> (Float, Float) {
        let fall = Float(date.timeIntervalSince(last)) * 24 // dB per second
        last = date
        shown = (max(l, shown.0 - fall), max(r, shown.1 - fall))
        return shown
    }
}
