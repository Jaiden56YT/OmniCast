import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            RecordingSettingsView()
                .tabItem { Label("Recording", systemImage: "record.circle") }
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle.badge.checkmark") }
            ChatSettingsView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.text.bubble.right") }
            DiscordSettingsView()
                .tabItem { Label("Discord", systemImage: "person.2.wave.2") }
            VideoSettingsView()
                .tabItem { Label("Video", systemImage: "cpu") }
        }
        .frame(width: 560)
    }
}

struct RecordingSettingsView: View {
    @Bindable private var engine = Engine.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text((engine.recordSettings.folder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Canvas", selection: $engine.recordSettings.target) {
                    Text("Horizontal 16:9").tag(RecordTarget.horizontal)
                    Text("Vertical 9:16").tag(RecordTarget.vertical)
                    Text("Both (two files)").tag(RecordTarget.both)
                }
            }
            Section {
                Picker("Codec", selection: $engine.recordSettings.codec) {
                    ForEach(RecordCodec.allCases) { codec in
                        Text(codec.label).tag(codec)
                    }
                }
                Picker("Quality", selection: $engine.recordSettings.quality) {
                    ForEach(RecordQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                Text(engine.recordSettings.quality.detail + ". "
                     + (engine.recordSettings.codec == .hevc
                        ? "HEVC makes files about half the size of H.264 at the same quality."
                        : "H.264 opens everywhere, including older editors."))
                    .font(.caption).foregroundStyle(.secondary)
                if engine.recordSettings.codec == .hevc, engine.running, !engine.hevcAvailable {
                    Text("No hardware HEVC encoder was found, so recordings use H.264.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Encoding")
            } footer: {
                Text("Recordings use a separate encode on the M4's media engine at 60 fps, so a low stream bitrate never lowers recording quality.")
            }
            Section {
                Toggle("Separate audio tracks", isOn: $engine.recordSettings.splitAudio)
                Text("Track 1 is the full mix. Tracks 2 and 3 hold desktop audio and the mic on their own, for editing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(engine.recordState != .idle)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: engine.recordSettings.folder)
        if panel.runModal() == .OK, let url = panel.url {
            engine.recordSettings.folder = url.path
        }
    }
}

struct VideoSettingsView: View {
    @State private var preferMetal = Engine.shared.preferMetal

    var body: some View {
        Form {
            Toggle("Use the Metal renderer (falls back to OpenGL)", isOn: $preferMetal)
                .onChange(of: preferMetal) { Engine.shared.preferMetal = preferMetal }
            Text("Renderer changes apply the next time OmniCast starts. Running: \(Engine.shared.renderer)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
