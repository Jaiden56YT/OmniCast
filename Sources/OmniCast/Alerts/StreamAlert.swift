import Foundation

/// One follow, sub, tip or raid from any platform, in a common shape for the
/// alert overlay: "**name** action **highlight**", e.g. "deku_vt cheered 500 bits".
struct StreamAlert: Identifiable, Equatable {
    /// The groups alerts can be turned on and off by.
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Twitch follows, YouTube subscribers, Kick follows.
        case follow
        /// Subs, resubs, YouTube memberships and milestones.
        case subscription
        /// Gifted subs and gifted memberships.
        case gift
        /// Bits, Super Chats, Super Stickers, YouTube gifts, Kicks.
        case money
        /// Twitch raids, Kick hosts.
        case raid

        var id: String { rawValue }

        var label: String {
            switch self {
            case .follow: "Follows and YouTube subscribers"
            case .subscription: "Subs and memberships"
            case .gift: "Gifted subs and memberships"
            case .money: "Bits, Super Chats, Kicks and gifts"
            case .raid: "Raids and hosts"
            }
        }

        var symbol: String {
            switch self {
            case .follow: "heart.fill"
            case .subscription: "star.fill"
            case .gift: "gift.fill"
            case .money: "sparkles"
            case .raid: "person.3.fill"
            }
        }

        var accent: String {
            switch self {
            case .follow: "#FF5FA2"
            case .subscription: "#B794FF"
            case .gift: "#4ED1A1"
            case .money: "#FFC93C"
            case .raid: "#6E8BFF"
            }
        }
    }

    let id = UUID()
    let platform: ChatPlatform
    let kind: Kind
    /// Who did it.
    let name: String
    /// What they did, e.g. "cheered", "just followed".
    let action: String
    /// Drawn in the accent colour after the action, e.g. "500 bits", "12 months".
    var highlight: String?
    /// Their message, if the event carried one (resub messages, Super Chats).
    var message: String?
    let received = Date()

    static func == (a: StreamAlert, b: StreamAlert) -> Bool { a.id == b.id }

    /// One line for lists in the app, e.g. "deku_vt cheered 500 bits".
    var summary: String {
        [name, action, highlight].compactMap { $0 }.joined(separator: " ")
    }
}
