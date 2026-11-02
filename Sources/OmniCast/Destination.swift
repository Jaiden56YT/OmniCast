import Foundation
import Security

enum Canvas: String, Codable, CaseIterable, Identifiable {
    case horizontal, vertical
    var id: String { rawValue }
    var label: String { self == .horizontal ? "16:9" : "9:16" }
}

enum Platform: String, Codable, CaseIterable, Identifiable {
    case youtube, twitch, kick, tiktok, instagram, custom
    var id: String { rawValue }

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .twitch: "Twitch"
        case .kick: "Kick"
        case .tiktok: "TikTok"
        case .instagram: "Instagram"
        case .custom: "Custom RTMP"
        }
    }

    /// Ingest URL to start from. TikTok and Instagram hand out a URL per stream,
    /// so those still have to be pasted from the platform before going live.
    var defaultServer: String {
        switch self {
        case .youtube: "rtmps://a.rtmps.youtube.com:443/live2"
        case .twitch: "rtmp://live.twitch.tv/app"
        case .kick: "rtmps://fa723fc1b171.global-contribute.live-video.net/app"
        case .instagram: "rtmps://live-upload.instagram.com:443/rtmp/"
        case .tiktok, .custom: ""
        }
    }

    var defaultCanvas: Canvas {
        self == .tiktok || self == .instagram ? .vertical : .horizontal
    }

    var keyHelp: String {
        switch self {
        case .youtube: "YouTube Studio → Go live → Stream → Stream key"
        case .twitch: "Twitch dashboard → Settings → Stream → Primary stream key"
        case .kick: "Kick dashboard → Settings → Stream URL & Key"
        case .tiktok: "TikTok LIVE Producer → Server URL and Stream key (new each stream)"
        case .instagram: "Instagram (web) → Create → Live video → URL and key (new each stream)"
        case .custom: "Any RTMP/RTMPS server URL and key"
        }
    }
}

struct Destination: Identifiable, Codable, Equatable {
    var id = UUID()
    var platform: Platform
    var name: String
    var server: String
    var canvas: Canvas
    var enabled = false

    init(platform: Platform) {
        self.platform = platform
        name = platform.name
        server = platform.defaultServer
        canvas = platform.defaultCanvas
    }

    var key: String {
        get { Keychain.read(id.uuidString) ?? "" }
        nonmutating set { Keychain.write(id.uuidString, newValue) }
    }

    var isReady: Bool { !server.isEmpty && !key.isEmpty }
}

enum DestinationStore {
    private static let defaultsKey = "destinations"

    static func load() -> [Destination] {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let list = try? JSONDecoder().decode([Destination].self, from: data) {
            return list
        }
        return [.youtube, .twitch, .kick, .tiktok, .instagram].map(Destination.init(platform:))
    }

    static func save(_ list: [Destination]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Stream keys and Discord credentials live in the login keychain, never in UserDefaults.
enum Keychain {
    static let streamKeyService = "OmniCast stream key"
    static let discordService = "OmniCast Discord"

    static func read(_ account: String, service: String = streamKeyService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String, service: String = streamKeyService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
