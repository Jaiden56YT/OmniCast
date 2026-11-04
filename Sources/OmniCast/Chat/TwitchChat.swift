import Foundation

/// Reads a Twitch channel's chat anonymously over Twitch's official IRC
/// WebSocket ("justinfan" login, read-only, no account or key).
final class TwitchChat: ChatSource {
    var onMessage: ((ChatMessage) -> Void)?
    var onStatus: ((ChatStatus) -> Void)?

    private let channel: String
    private var socket: URLSessionWebSocketTask?
    private var running = false
    private var retryDelay: TimeInterval = 2

    init(channel: String) {
        self.channel = channel.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# @").union(.whitespaces))
    }

    func start() {
        guard !running, !channel.isEmpty else { return }
        running = true
        connect()
    }

    func stop() {
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onStatus?(.off)
    }

    private func connect() {
        guard running else { return }
        onStatus?(.connecting)
        let task = URLSession.shared.webSocketTask(with: URL(string: "wss://irc-ws.chat.twitch.tv:443")!)
        socket = task
        task.resume()
        for line in ["CAP REQ :twitch.tv/tags twitch.tv/commands", "PASS SCHMOOPIIE",
                     "NICK justinfan\(Int.random(in: 10000...99999))", "JOIN #\(channel)"] {
            task.send(.string(line)) { _ in }
        }
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.socket === task else { return }
                switch result {
                case .success(.string(let text)):
                    text.split(separator: "\r\n").forEach { self.handle(String($0), on: task) }
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
        guard running else { return }
        onStatus?(.failed("Reconnecting to Twitch…"))
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 60)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }

    private func handle(_ line: String, on task: URLSessionWebSocketTask) {
        if line.hasPrefix("PING") {
            task.send(.string("PONG" + line.dropFirst(4))) { _ in }
            return
        }
        // "@tags :nick!nick@nick.tmi.twitch.tv COMMAND #channel :text"
        var rest = Substring(line)
        var tags: [String: String] = [:]
        if rest.hasPrefix("@"), let space = rest.firstIndex(of: " ") {
            for pair in rest[rest.index(after: rest.startIndex)..<space].split(separator: ";") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                tags[String(kv[0])] = kv.count > 1 ? Self.unescape(String(kv[1])) : ""
            }
            rest = rest[rest.index(after: space)...]
        }
        let fields = rest.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard fields.count >= 2 else { return }
        switch fields[1] {
        case "ROOMSTATE", "366":
            retryDelay = 2
            onStatus?(.connected)
        case "PRIVMSG":
            guard fields.count == 4 else { return }
            var text = String(fields[3])
            if text.hasPrefix(":") { text.removeFirst() }
            let login = fields[0].dropFirst().split(separator: "!").first.map(String.init) ?? "someone"
            let name = tags["display-name"].flatMap { $0.isEmpty ? nil : $0 } ?? login
            onMessage?(ChatMessage(
                id: tags["id"] ?? UUID().uuidString, platform: .twitch, author: name,
                color: tags["color"].flatMap { $0.isEmpty ? nil : $0 },
                badges: Self.badges(tags["badges"] ?? ""),
                parts: Self.parts(text, emotes: tags["emotes"] ?? "")))
        case "CLEARCHAT", "CLEARMSG":
            break // moderation; the overlay simply lets old lines scroll away
        default:
            break
        }
    }

    private static func badges(_ tag: String) -> [ChatMessage.Badge] {
        tag.split(separator: ",").compactMap { badge in
            switch badge.split(separator: "/").first {
            case "broadcaster": .owner
            case "moderator": .moderator
            case "vip": .vip
            case "subscriber", "founder": .member
            case "partner": .verified
            default: nil
            }
        }
    }

    /// emotes tag: "25:0-4,12-16/1902:6-10", positions in Unicode scalars.
    private static func parts(_ text: String, emotes: String) -> [ChatMessage.Part] {
        let scalars = Array(text.unicodeScalars)
        var ranges: [(Int, Int, String)] = []
        for emote in emotes.split(separator: "/") {
            let idAndSpans = emote.split(separator: ":")
            guard idAndSpans.count == 2 else { continue }
            for span in idAndSpans[1].split(separator: ",") {
                let ends = span.split(separator: "-").compactMap { Int($0) }
                if ends.count == 2, ends[0] <= ends[1], ends[1] < scalars.count {
                    ranges.append((ends[0], ends[1], String(idAndSpans[0])))
                }
            }
        }
        ranges.sort { $0.0 < $1.0 }
        var parts: [ChatMessage.Part] = []
        var at = 0
        func slice(_ a: Int, _ b: Int) -> String {
            var s = String.UnicodeScalarView()
            s.append(contentsOf: scalars[a..<b])
            return String(s)
        }
        for (start, end, id) in ranges where start >= at {
            if start > at { parts.append(.text(slice(at, start))) }
            let url = URL(string: "https://static-cdn.jtvnw.net/emoticons/v2/\(id)/default/dark/2.0")!
            parts.append(.emote(url, fallback: slice(start, end + 1)))
            at = end + 1
        }
        if at < scalars.count { parts.append(.text(slice(at, scalars.count))) }
        return parts
    }

    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s", with: " ")
            .replacingOccurrences(of: "\\:", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
