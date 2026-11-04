import Foundation

/// Reads a Kick channel's chat the way kick.com does (unofficial): the channel's
/// public record gives its ids, Kick's realtime API hands out the chat server
/// (Centrifugo) and a guest token without any login, and the chatroom's
/// channel carries every message.
final class KickChat: ChatSource {
    var onMessage: ((ChatMessage) -> Void)?
    var onStatus: ((ChatStatus) -> Void)?

    /// Used if asking Kick for the chat server fails.
    static let defaultServer = URL(string: "wss://realtime.us-east-1.platform.kick.com/connection/websocket")!

    private let slug: String
    private var channelID: Int?
    private var chatroomID: Int?
    private let clientID = UUID().uuidString.lowercased()
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var retryDelay: TimeInterval = 2
    private var renewal: DispatchWorkItem?

    init(channel: String, chatroomID: Int? = nil) {
        slug = channel.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "@ ").union(.whitespaces))
        self.chatroomID = chatroomID
    }

    func start() {
        guard !running, !slug.isEmpty || chatroomID != nil else { return }
        running = true
        if chatroomID != nil { connect() } else { lookUpChannel() }
    }

    func stop() {
        running = false
        renewal?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onStatus?(.off)
    }

    // MARK: Requests

    private func request(_ url: String, body: [String: Any]? = nil,
                         _ done: @escaping (Int, [String: Any]?) -> Void) {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(ChatHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        URLSession.shared.dataTask(with: r) { data, response, _ in
            // Kick's channel records can hold raw control characters (bios), so parse leniently.
            let json = data.flatMap { d -> Any? in
                (try? JSONSerialization.jsonObject(with: d))
                    ?? String(data: d, encoding: .utf8).flatMap { text in
                        try? JSONSerialization.jsonObject(with: Data(text.unicodeScalars
                            .filter { $0.value >= 0x20 || $0 == "\n" }.map(String.init).joined().utf8))
                    }
            } as? [String: Any]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async { done(status, json) }
        }.resume()
    }

    private func lookUpChannel() {
        onStatus?(.connecting)
        request("https://kick.com/api/v2/channels/\(slug)") { [weak self] status, json in
            guard let self, self.running else { return }
            guard let room = (json?["chatroom"] as? [String: Any])?["id"] as? Int else {
                self.onStatus?(.failed(status == 404 ? "Kick channel not found"
                    : "Kick blocked the lookup (\(status)). Paste the chatroom ID in Settings."))
                return
            }
            self.channelID = json?["id"] as? Int
            self.chatroomID = room
            self.connect()
        }
    }

    /// Asks Kick which chat server to use, gets a guest token, then connects.
    private func connect() {
        guard running, let chatroomID else { return }
        onStatus?(.connecting)
        let capabilities: [String: Any] = [
            "client": ["id": clientID, "type": "web"],
            "capabilities": ["accepted_providers": [["provider": "centrifugo"]]],
        ]
        let channel = channelID ?? chatroomID
        request("https://web.kick.com/api/v1/realtime/channels/\(channel)/chat/connection", body: capabilities) {
            [weak self] _, json in
            guard let self, self.running else { return }
            let connections = (json?["data"] as? [String: Any])?["connections"] as? [[String: Any]] ?? []
            let server = connections.first { $0["provider"] as? String == "centrifugo" }
                .flatMap { ($0["credentials"] as? [String: Any])?["url"] as? String }
                .flatMap(URL.init(string:)) ?? Self.defaultServer
            self.request("https://web.kick.com/api/v1/realtime/auth/connection", body: ["client_id": self.clientID]) {
                [weak self] _, json in
                guard let self, self.running else { return }
                guard let token = (json?["data"] as? [String: Any])?["token"] as? String else {
                    self.onStatus?(.failed("Kick didn't hand out a chat token"))
                    return self.reconnect()
                }
                self.open(server, token: token, chatroom: chatroomID)
            }
        }
    }

    private func open(_ server: URL, token: String, chatroom: Int) {
        let task = URLSession.shared.webSocketTask(with: server)
        socket = task
        task.resume()
        send(task, ["id": 1, "connect": ["token": token, "name": "js"]])
        send(task, ["id": 2, "subscribe": ["channel": "chatrooms.\(chatroom).v2"]])
        receive(task)
    }

    private func send(_ task: URLSessionWebSocketTask, _ command: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: command),
              let text = String(data: body, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === task else { return }
                switch result {
                case .success(.string(let text)):
                    // Several replies can share one frame, one JSON object per line.
                    for line in text.split(separator: "\n") { self.handle(String(line), on: task) }
                    self.receive(task)
                case .success:
                    self.receive(task)
                case .failure:
                    self.reconnect()
                }
            }
        }
    }

    private func reconnect() {
        socket = nil
        renewal?.cancel()
        guard running else { return }
        onStatus?(.failed("Reconnecting to Kick…"))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func handle(_ line: String, on task: URLSessionWebSocketTask) {
        // An empty object is the server's ping; answering keeps the connection open.
        if line == "{}" {
            task.send(.string("{}")) { _ in }
            return
        }
        guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        if let connect = message["connect"] as? [String: Any] {
            // Guest tokens expire (ttl, seconds): start a fresh session a minute before.
            if let ttl = connect["ttl"] as? Double, ttl > 120 {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.socket === task else { return }
                    task.cancel(with: .goingAway, reason: nil)
                    self.socket = nil
                    self.retryDelay = 2
                    self.connect()
                }
                renewal?.cancel()
                renewal = work
                DispatchQueue.main.asyncAfter(deadline: .now() + ttl - 60, execute: work)
            }
            return
        }
        if message["subscribe"] != nil, message["id"] as? Int == 2 {
            retryDelay = 2
            onStatus?(.connected)
            return
        }
        if message["error"] != nil {
            onStatus?(.failed("Kick chat refused the connection"))
            return
        }
        guard let pub = ((message["push"] as? [String: Any])?["pub"] as? [String: Any])?["data"] as? [String: Any],
              pub["event"] as? String == "App\\Events\\ChatMessageEvent",
              let raw = pub["data"] as? String,
              let data = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any],
              let sender = data["sender"] as? [String: Any] else { return }
        let identity = sender["identity"] as? [String: Any] ?? [:]
        let badges = (identity["badges"] as? [[String: Any]] ?? []).compactMap { b -> ChatMessage.Badge? in
            switch b["type"] as? String {
            case "broadcaster": .owner
            case "moderator": .moderator
            case "vip": .vip
            case "subscriber", "founder", "og": .member
            case "verified": .verified
            default: nil
            }
        }
        onMessage?(ChatMessage(
            id: (data["id"] as? String) ?? UUID().uuidString, platform: .kick,
            author: sender["username"] as? String ?? "someone",
            color: identity["color"] as? String, badges: badges,
            parts: Self.parts(data["content"] as? String ?? "")))
    }

    /// Emotes arrive inline as "[emote:12345:name]".
    private static func parts(_ content: String) -> [ChatMessage.Part] {
        var parts: [ChatMessage.Part] = []
        var rest = Substring(content)
        while let open = rest.range(of: "[emote:") {
            guard let close = rest[open.upperBound...].firstIndex(of: "]") else { break }
            if open.lowerBound > rest.startIndex { parts.append(.text(String(rest[..<open.lowerBound]))) }
            let fields = rest[open.upperBound..<close].split(separator: ":", maxSplits: 1)
            if let id = fields.first, let url = URL(string: "https://files.kick.com/emotes/\(id)/fullsize") {
                parts.append(.emote(url, fallback: fields.count > 1 ? String(fields[1]) : ""))
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { parts.append(.text(String(rest))) }
        return parts
    }
}

enum ChatHTTP {
    /// A desktop browser's user agent: YouTube and Kick serve their normal pages to it.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}
