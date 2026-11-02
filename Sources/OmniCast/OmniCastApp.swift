import AppKit
import SwiftUI

@main
struct OmniCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("OmniCast") {
            ContentView()
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("Controls") {
                RecordCommand()
                LiveCommand()
            }
        }
        Settings {
            SettingsView()
        }
    }
}

private struct RecordCommand: View {
    private var engine: Engine { .shared }

    var body: some View {
        Button(engine.recordState == .idle ? "Start Recording" : "Stop Recording") { engine.toggleRecording() }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!engine.running || engine.recordState == .finishing)
    }
}

private struct LiveCommand: View {
    private var engine: Engine { .shared }

    var body: some View {
        Button(engine.live ? "End Stream" : "Go Live") { engine.live ? engine.stopLive() : engine.goLive() }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(!engine.running || (!engine.live && !engine.destinations.contains { $0.enabled && $0.isReady }))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The engine has to be up before the preview views attach.
        MainActor.assumeIsolated { Engine.shared.requestAccessThenStart() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { RecordBenchmark.runIfRequested() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Engine.shared.shutdown() }
    }
}
