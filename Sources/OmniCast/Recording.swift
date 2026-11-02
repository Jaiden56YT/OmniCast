import Foundation
import OmniEngine

enum RecordCodec: String, Codable, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC (H.265)" : "H.264" }
    var c: omni_codec { self == .hevc ? OMNI_CODEC_HEVC : OMNI_CODEC_H264 }
}

/// VideoToolbox constant-quality levels. Static screens stay tiny at every level;
/// the levels differ in how much detail fast motion keeps.
enum RecordQuality: String, Codable, CaseIterable, Identifiable {
    case balanced, high, pristine
    var id: String { rawValue }

    var label: String {
        switch self {
        case .balanced: "Balanced"
        case .high: "High"
        case .pristine: "Pristine"
        }
    }

    var value: UInt32 {
        switch self {
        case .balanced: 55
        case .high: 65
        case .pristine: 78
        }
    }

    var detail: String {
        switch self {
        case .balanced: "Smaller files, good for long sessions"
        case .high: "Clean motion and sharp text, the default"
        case .pristine: "Close to lossless for editing, large files"
        }
    }
}

enum RecordTarget: String, Codable, CaseIterable, Identifiable {
    case horizontal, vertical, both
    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: "16:9"
        case .vertical: "9:16"
        case .both: "Both"
        }
    }

    var canvases: Set<Canvas> {
        switch self {
        case .horizontal: [.horizontal]
        case .vertical: [.vertical]
        case .both: [.horizontal, .vertical]
        }
    }
}

struct RecordSettings: Codable, Equatable {
    var folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OmniCast", isDirectory: true).path
    var codec = RecordCodec.hevc
    var quality = RecordQuality.high
    var target = RecordTarget.horizontal
    var splitAudio = true

    private static let defaultsKey = "recordSettings"

    static func load() -> RecordSettings {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let settings = try? JSONDecoder().decode(RecordSettings.self, from: data) {
            return settings
        }
        return RecordSettings()
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

enum RecordState: Equatable {
    case idle, recording, finishing
}
