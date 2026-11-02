import AppKit
import Foundation

/// `OmniCast --benchmark-record <seconds> [--folder <dir>] [--target horizontal|vertical|both]`
/// records for that long, writes benchmark.json next to the recording and quits.
/// Use it to check that a canvas records without missed frames on this Mac.
@MainActor
enum RecordBenchmark {
    struct Result: Encodable {
        var seconds: Double
        var target: String
        var codec: String
        var renderer: String
        var fpsSamples: [Double] = []
        var renderMsSamples: [Double] = []
        var renderedFrames: UInt32 = 0
        var missedRender: UInt32 = 0
        var missedEncode: UInt32 = 0
        var bytes: UInt64 = 0
        var thermal: String = ""
        var files: [String] = []
        var error: String?
    }

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--benchmark-record"), i + 1 < args.count,
              let seconds = Double(args[i + 1]) else { return }
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }

        let engine = Engine.shared
        var settings = engine.recordSettings
        if let folder = value("--folder") { settings.folder = folder }
        if let target = value("--target").flatMap(RecordTarget.init(rawValue:)) { settings.target = target }

        var result = Result(seconds: seconds, target: settings.target.rawValue,
                            codec: settings.codec.rawValue, renderer: engine.renderer)
        let folder = URL(fileURLWithPath: settings.folder)

        // Wait for the engine (it may be waiting on permission prompts), then let
        // capture sources deliver their first frames before measuring.
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { wait in
            MainActor.assumeIsolated {
                guard engine.running || engine.startError != nil else { return }
                wait.invalidate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { measure() }
            }
        }

        func measure() {
            result.renderer = engine.renderer
            let framesBefore = engine.stats.total_frames
            engine.startRecording(override: settings)
            guard engine.recordState == .recording else {
                result.error = engine.recordError ?? "Recording did not start"
                finish(result, folder)
                return
            }
            var elapsed = 0.0
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                MainActor.assumeIsolated {
                    elapsed += 1
                    result.fpsSamples.append(engine.stats.fps)
                    result.renderMsSamples.append((engine.stats.render_ms * 100).rounded() / 100)
                    guard elapsed >= seconds else { return }
                    timer.invalidate()
                    result.renderedFrames = engine.stats.total_frames &- framesBefore
                    result.missedRender = engine.recordingMissed.render
                    result.missedEncode = engine.recordingMissed.encode
                    result.bytes = engine.recordingBytes
                    result.thermal = "\(ProcessInfo.processInfo.thermalState.rawValue)"
                    engine.stopRecording()
                    waitForSave(result, folder)
                }
            }
        }
    }

    private static func waitForSave(_ partial: Result, _ folder: URL) {
        var result = partial
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            MainActor.assumeIsolated {
                guard Engine.shared.recordState == .idle else { return }
                timer.invalidate()
                result.files = Engine.shared.lastRecordings.map(\.path)
                result.error = Engine.shared.recordError
                finish(result, folder)
            }
        }
    }

    private static func finish(_ result: Result, _ folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(result) {
            try? data.write(to: folder.appendingPathComponent("benchmark.json"))
            FileHandle.standardOutput.write(data)
        }
        NSApp.terminate(nil)
    }
}
