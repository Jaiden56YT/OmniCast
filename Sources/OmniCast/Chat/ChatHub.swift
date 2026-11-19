import Foundation
import Observation

/// Merges the YouTube, Twitch and Kick chats into one list for the overlay.
@MainActor
@Observable
final class ChatHub {
    static let shared = ChatHub()

    struct Settings: Codable, Equatable {
        var youtube = ""
        var twitch = ""
        var kick = ""
        var enabled: Set<ChatPlatform> = Set(ChatPlatform.allCases)
        /// For when Kick blocks the channel lookup: the chatroom number from kick.com.
        var kickChatroom: Int?
    }

    var settings: Settings = {
        if let data = UserDefaults.standard.data(forKey: "chat.settings"),
           let s = try? JSONDecoder().decode(Settings.self, from: data) { return s }
        return Settings()
    }() {
        didSet {
            guard settings != oldValue else { return }
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "chat.settings") }
            restart()
        }
    }

    private(set) var status: [ChatPlatform: ChatStatus] = [:]
    /// Newest last.
    private(set) var messages: [ChatMessage] = []
    var onChange: (() -> Void)?

    private var sources: [ChatPlatform: ChatSource] = [:]
    private static let keep = 50

    func start() { restart() }

    func restart() {
        sources.values.forEach { $0.stop() }
        sources = [:]
        for platform in ChatPlatform.allCases {
            guard settings.enabled.contains(platform), let source = makeSource(platform) else {
                status[platform] = .off
                continue
            }
            source.onStatus = { [weak self] in self?.status[platform] = $0 }
            source.onMessage = { [weak self] in self?.add($0) }
            source.onAlert = { AlertOverlay.shared.post($0) }
            sources[platform] = source
            source.start()
        }
    }

    private func makeSource(_ platform: ChatPlatform) -> ChatSource? {
        switch platform {
        case .youtube: settings.youtube.isEmpty ? nil : YouTubeChat(handle: settings.youtube)
        case .twitch: settings.twitch.isEmpty ? nil : TwitchChat(channel: settings.twitch)
        case .kick: settings.kick.isEmpty && settings.kickChatroom == nil ? nil
            : KickChat(channel: settings.kick, chatroomID: settings.kickChatroom)
        }
    }

    private func add(_ message: ChatMessage) {
        guard !messages.contains(message) else { return }
        messages.append(message)
        if messages.count > Self.keep { messages.removeFirst(messages.count - Self.keep) }
        onChange?()
    }

    /// A few made-up lines from each platform, to see and arrange the overlay offline.
    func addTestMessages() {
        let samples: [(ChatPlatform, String, String?, [ChatMessage.Badge], String)] = [
            (.youtube, "deku_vt", nil, [], "eepers time"),
            (.twitch, "Mr_Seasalt", "#FF4F9A", [.member], "It's been 9 hours and 20 minutes 😭"),
            (.kick, "ItsSoraval", "#53FC18", [], "I DONT HAVE THAT DUDE"),
            (.youtube, "BrandonSaber", nil, [.moderator], "wait you mean 1400 right?"),
            (.twitch, "T3mpex", "#9B7BFF", [.vip], "I gotta see the concept skins before I attempt getting this token"),
            (.youtube, "YourChannel", nil, [.owner], "yo welcome in everybody"),
        ]
        for (p, name, color, badges, text) in samples {
            add(ChatMessage(id: UUID().uuidString, platform: p, author: name, color: color, badges: badges,
                            parts: [.text(text)]))
        }
    }

    func clear() {
        messages = []
        onChange?()
    }

    /// One line for the Sources row, e.g. "Twitch, Kick · YouTube waiting".
    var summary: String {
        let on = ChatPlatform.allCases.filter { status[$0] == .connected }.map(\.name)
        let waiting = ChatPlatform.allCases.filter { status[$0] == .waitingForLive }.map { "\($0.name) waiting for live" }
        let failing = ChatPlatform.allCases.filter { if case .failed = status[$0] { return true }; return false }
            .map { "\($0.name) failed" }
        let parts: [String] = (on.isEmpty ? [] : [on.joined(separator: ", ")]) + waiting + failing
        let text = parts.joined(separator: " · ")
        return text.isEmpty ? "Not connected" : text
    }
}
