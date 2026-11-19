import Foundation
import Observation

/// The alert feeds that need a signed-in account (the chat connections bring
/// the rest): Twitch follows over EventSub, and YouTube's newest subscribers.
@MainActor
@Observable
final class AlertSources {
    static let shared = AlertSources()

    private(set) var twitchStatus = "Off"
    private(set) var youtubeStatus = "Off"

    private let twitch = TwitchFollows()
    private var youtubeSeen: Set<String>?
    private var youtubeTimer: Timer?
    private var youtubeBusy = false

    /// How often to ask YouTube while live. One call costs 1 unit of the
    /// project's 10,000-a-day quota, so a minute apart is ~60 units an hour.
    private static let youtubeInterval: TimeInterval = 60

    init() {
        twitch.onStatus = { [weak self] in self?.twitchStatus = $0 }
        twitch.onFollow = { name in
            AlertOverlay.shared.post(StreamAlert(platform: .twitch, kind: .follow, name: name, action: "just followed"))
        }
    }

    func start() { update() }

    /// Starts or stops the feeds to match the settings and signed-in accounts.
    func update() {
        let follows = AlertOverlay.shared.enabled && AlertOverlay.shared.kinds.contains(.follow)
        if follows, TwitchAccount.shared.isConnected {
            twitch.start()
        } else {
            twitch.stop()
            twitchStatus = TwitchAccount.shared.isConnected ? "Off" : "Not signed in (Settings → Accounts)"
        }
        if follows, YouTubeAccount.shared.isConnected {
            if youtubeTimer == nil {
                youtubeTimer = Timer.scheduledTimer(withTimeInterval: Self.youtubeInterval, repeats: true) { _ in
                    MainActor.assumeIsolated { AlertSources.shared.pollYouTube(onlyWhenLive: true) }
                }
                // Once now, to learn who's already subscribed and check the account works.
                pollYouTube(onlyWhenLive: false)
            }
        } else {
            youtubeTimer?.invalidate()
            youtubeTimer = nil
            youtubeSeen = nil
            youtubeStatus = YouTubeAccount.shared.isConnected ? "Off" : "Not signed in (Settings → Accounts)"
        }
    }

    /// Signs in again or a setting changed: start the feeds afresh.
    func restart() {
        twitch.stop()
        youtubeTimer?.invalidate()
        youtubeTimer = nil
        youtubeSeen = nil
        update()
    }

    private func pollYouTube(onlyWhenLive: Bool) {
        guard !youtubeBusy, !onlyWhenLive || Engine.shared.live else { return }
        youtubeBusy = true
        Task {
            defer { youtubeBusy = false }
            do {
                let subs = try await YouTubeAccount.shared.recentSubscribers()
                guard youtubeTimer != nil else { return }
                if let seen = youtubeSeen {
                    for sub in subs.reversed() where !seen.contains(sub.id) {
                        AlertOverlay.shared.post(StreamAlert(platform: .youtube, kind: .follow, name: sub.name,
                                                             action: "just subscribed"))
                    }
                }
                youtubeSeen = (youtubeSeen ?? []).union(subs.map(\.id))
                youtubeStatus = "Checking every minute while live"
            } catch {
                youtubeStatus = error.localizedDescription
            }
        }
    }
}

/// Twitch EventSub over a WebSocket: Twitch pushes each new follower of the
/// signed-in channel. Needs the moderator:read:followers scope.
@MainActor
final class TwitchFollows {
    var onStatus: ((String) -> Void)?
    var onFollow: ((String) -> Void)?

    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var retryDelay: TimeInterval = 2
    private var keepalive: TimeInterval = 10
    private var lastMessage = Date()
    private var watchdog: Timer?
    /// Follow, unfollow, follow again shouldn't alert twice in one session.
    private var alerted = Set<String>()

    static let url = URL(string: "wss://eventsub.wss.twitch.tv/ws")!

    func start() {
        guard !running else { return }
        running = true
        connect(Self.url)
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running, self.socket != nil else { return }
                // Twitch sends a keepalive at least this often; silence means the connection died.
                if Date().timeIntervalSince(self.lastMessage) > self.keepalive + 10 { self.reconnect() }
            }
        }
    }

    func stop() {
        running = false
        watchdog?.invalidate()
        watchdog = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func connect(_ url: URL) {
        guard running else { return }
        onStatus?("Connecting…")
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        lastMessage = Date()
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.socket === task else { return }
                    switch result {
                    case .success(.string(let text)):
                        self.handle(text, on: task)
                        self.receive(task)
                    case .success:
                        self.receive(task)
                    case .failure:
                        self.reconnect()
                    }
                }
            }
        }
    }

    private func reconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard running else { return }
        onStatus?("Reconnecting to Twitch…")
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.connect(Self.url) }
        }
    }

    private func handle(_ text: String, on task: URLSessionWebSocketTask) {
        lastMessage = Date()
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = (json["metadata"] as? [String: Any])?["message_type"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]
        let session = payload["session"] as? [String: Any]
        switch type {
        case "session_welcome":
            keepalive = session?["keepalive_timeout_seconds"] as? Double ?? 10
            // A welcome after a reconnect request keeps the old subscriptions.
            if reconnecting {
                reconnecting = false
                onStatus?("Listening for follows")
                return
            }
            guard let id = session?["id"] as? String else { return reconnect() }
            Task {
                do {
                    try await TwitchAccount.shared.subscribeToFollows(session: id)
                    guard self.socket === task else { return }
                    self.retryDelay = 2
                    self.onStatus?("Listening for follows")
                } catch {
                    guard self.socket === task else { return }
                    self.onStatus?(error.localizedDescription)
                    // Without a subscription Twitch closes the socket; don't keep retrying.
                    self.stop()
                }
            }
        case "session_reconnect":
            // Twitch is moving us: open the new URL, then drop the old socket.
            guard let url = (session?["reconnect_url"] as? String).flatMap(URL.init(string:)) else { return reconnect() }
            reconnecting = true
            task.cancel(with: .goingAway, reason: nil)
            connect(url)
        case "notification":
            let event = payload["event"] as? [String: Any] ?? [:]
            let id = event["user_id"] as? String ?? UUID().uuidString
            guard alerted.insert(id).inserted else { return }
            onFollow?(event["user_name"] as? String ?? event["user_login"] as? String ?? "Someone")
        case "revocation":
            onStatus?("Twitch stopped sending follows. Sign in to Twitch again in Settings → Accounts.")
            stop()
        default:
            break // session_keepalive
        }
    }
    private var reconnecting = false
}
