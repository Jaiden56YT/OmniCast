import Foundation
import Observation

/// The title and games to send to the platforms, and how each update went.
@MainActor
@Observable
final class StreamInfo {
    static let shared = StreamInfo()

    enum Outcome: Equatable {
        case working, done
        case failed(String)
    }

    var title = UserDefaults.standard.string(forKey: "info.title") ?? "" {
        didSet { UserDefaults.standard.set(title, forKey: "info.title") }
    }
    /// Platforms whose title gets updated.
    var titleOn: Set<ChatPlatform> = Set(
        (UserDefaults.standard.stringArray(forKey: "info.titleOn") ?? ChatPlatform.allCases.map(\.rawValue))
            .compactMap(ChatPlatform.init(rawValue:))) {
        didSet { UserDefaults.standard.set(titleOn.map(\.rawValue), forKey: "info.titleOn") }
    }
    var twitchGame: StreamCategory? = StreamInfo.loadCategory("info.twitchGame") {
        didSet { Self.saveCategory(twitchGame, "info.twitchGame") }
    }
    var kickGame: StreamCategory? = StreamInfo.loadCategory("info.kickGame") {
        didSet { Self.saveCategory(kickGame, "info.kickGame") }
    }
    private(set) var recents: [ChatPlatform: [StreamCategory]] = [
        .twitch: StreamInfo.loadRecents(.twitch), .kick: StreamInfo.loadRecents(.kick),
    ]
    private(set) var results: [ChatPlatform: Outcome] = [:]
    private(set) var loading = false

    var twitch: TwitchAccount { .shared }
    var kick: KickAccount { .shared }
    var youtube: YouTubeAccount { .shared }

    func isConnected(_ p: ChatPlatform) -> Bool {
        switch p {
        case .twitch: twitch.isConnected
        case .kick: kick.isConnected
        case .youtube: youtube.isConnected
        }
    }

    /// Fills in what's set now, preferring Twitch's title, then Kick's, then YouTube's.
    func loadCurrent() async {
        loading = true
        defer { loading = false }
        var titles: [ChatPlatform: String] = [:]
        if twitch.isConnected, let info = try? await twitch.current() {
            titles[.twitch] = info.title
            if let game = info.category { twitchGame = game }
        }
        if kick.isConnected, let info = try? await kick.current() {
            titles[.kick] = info.title
            if let game = info.category { kickGame = game }
        }
        if youtube.isConnected, let info = try? await youtube.current() { titles[.youtube] = info.title }
        if let current = [ChatPlatform.twitch, .kick, .youtube].lazy.compactMap({ titles[$0] }).first(where: { !$0.isEmpty }) {
            title = current
        }
    }

    /// Sends everything at once; each platform reports on its own.
    func apply() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await withTaskGroup(of: Void.self) { group in
            for p in ChatPlatform.allCases where isConnected(p) {
                let sendTitle = titleOn.contains(p) && !trimmed.isEmpty ? trimmed : nil
                let game: StreamCategory? = p == .twitch ? twitchGame : p == .kick ? kickGame : nil
                guard sendTitle != nil || game != nil else { continue }
                results[p] = .working
                group.addTask { @MainActor in
                    do {
                        switch p {
                        case .twitch: try await self.twitch.update(title: sendTitle, category: game)
                        case .kick: try await self.kick.update(title: sendTitle, category: game)
                        case .youtube: if let sendTitle { try await self.youtube.update(title: sendTitle) }
                        }
                        self.results[p] = .done
                        if let game { self.remember(game, for: p) }
                    } catch {
                        self.results[p] = .failed(error.localizedDescription)
                    }
                }
            }
        }
    }

    func search(_ query: String, on p: ChatPlatform) async -> [StreamCategory] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        switch p {
        case .twitch: return (try? await twitch.search(q)) ?? []
        case .kick: return (try? await kick.search(q)) ?? []
        case .youtube: return []
        }
    }

    /// Picks Kick's game with the same name as the Twitch one, if Kick has it.
    func matchKickToTwitch() async -> Bool {
        guard let name = twitchGame?.name else { return false }
        let found = await search(name, on: .kick)
        guard let match = found.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) ?? found.first
        else { return false }
        kickGame = match
        return true
    }

    func clearResults() { results = [:] }

    private func remember(_ game: StreamCategory, for p: ChatPlatform) {
        var list = recents[p] ?? []
        list.removeAll { $0.id == game.id }
        list.insert(game, at: 0)
        recents[p] = Array(list.prefix(6))
        if let data = try? JSONEncoder().encode(recents[p]) { UserDefaults.standard.set(data, forKey: "info.recents.\(p.rawValue)") }
    }

    private static func loadRecents(_ p: ChatPlatform) -> [StreamCategory] {
        UserDefaults.standard.data(forKey: "info.recents.\(p.rawValue)")
            .flatMap { try? JSONDecoder().decode([StreamCategory].self, from: $0) } ?? []
    }

    private static func loadCategory(_ key: String) -> StreamCategory? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(StreamCategory.self, from: $0) }
    }

    private static func saveCategory(_ c: StreamCategory?, _ key: String) {
        if let data = c.flatMap({ try? JSONEncoder().encode($0) }) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
