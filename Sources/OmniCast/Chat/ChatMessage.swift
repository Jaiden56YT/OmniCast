import Foundation

enum ChatPlatform: String, Codable, CaseIterable, Identifiable {
    case youtube, twitch, kick
    var id: String { rawValue }

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .twitch: "Twitch"
        case .kick: "Kick"
        }
    }
}

/// One chat line from any platform, in a common shape for the overlay.
struct ChatMessage: Identifiable, Equatable {
    enum Badge: String, Equatable {
        case owner, moderator, vip, member, verified
    }

    enum Part: Equatable {
        case text(String)
        /// An emote or custom emoji drawn inline; `fallback` is shown until it loads.
        case emote(URL, fallback: String)
    }

    let id: String
    let platform: ChatPlatform
    let author: String
    /// Hex like "#FF4500" when the platform gives one (Twitch, Kick).
    let color: String?
    let badges: [Badge]
    let parts: [Part]
    let received = Date()

    var plainText: String {
        parts.map {
            switch $0 {
            case .text(let s): s
            case .emote(_, let fallback): fallback
            }
        }.joined()
    }

    static func == (a: ChatMessage, b: ChatMessage) -> Bool { a.id == b.id && a.platform == b.platform }
}

/// How a platform connection is doing, for the settings and the Sources row.
enum ChatStatus: Equatable {
    case off
    case connecting
    case connected
    /// YouTube: connected to the channel but it isn't live yet.
    case waitingForLive
    case failed(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .waitingForLive: "Waiting for you to go live"
        case .failed(let message): message
        }
    }
}

/// A platform's chat reader. Calls back on the main queue.
protocol ChatSource: AnyObject {
    var onMessage: ((ChatMessage) -> Void)? { get set }
    var onStatus: ((ChatStatus) -> Void)? { get set }
    func start()
    func stop()
}
