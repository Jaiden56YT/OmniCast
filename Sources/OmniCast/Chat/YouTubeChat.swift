import Foundation

/// Reads a YouTube channel's live chat without an API key: finds the live video
/// from the channel's /live page, then follows the same live-chat feed that
/// youtube.com's own chat window polls. Unofficial, so it can break if YouTube
/// changes its pages; it has no daily quota, unlike the Data API.
final class YouTubeChat: ChatSource {
    var onMessage: ((ChatMessage) -> Void)?
    var onStatus: ((ChatStatus) -> Void)?
    var onAlert: ((StreamAlert) -> Void)?

    private let handle: String
    private var running = false
    private var session = 0 // bumped on stop, so stale callbacks are dropped
    private var seen = Set<String>()

    init(handle: String) {
        var h = handle.trimmingCharacters(in: .whitespaces)
        if let range = h.range(of: "youtube.com/") { h = String(h[range.upperBound...]) }
        h = h.trimmingCharacters(in: CharacterSet(charactersIn: "/@"))
        self.handle = h
    }

    func start() {
        guard !running, !handle.isEmpty else { return }
        running = true
        session += 1
        findLiveVideo(session)
    }

    func stop() {
        running = false
        session += 1
        onStatus?(.off)
    }

    // MARK: Requests

    private func get(_ url: URL, _ done: @escaping (String?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(ChatHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Skips the cookie consent page shown in some regions.
        request.setValue("CONSENT=YES+1; SOCS=CAI", forHTTPHeaderField: "Cookie")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) }
            DispatchQueue.main.async { done(text) }
        }.resume()
    }

    private func current(_ s: Int) -> Bool { running && s == session }

    private func retry(_ s: Int, after seconds: TimeInterval, _ step: @escaping (Int) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.current(s) else { return }
            step(s)
        }
    }

    // MARK: Finding the stream

    /// /@handle/live redirects to the watch page while the channel is live (or
    /// has a stream scheduled), and to the channel page otherwise.
    private func findLiveVideo(_ s: Int) {
        onStatus?(.connecting)
        get(URL(string: "https://www.youtube.com/@\(handle)/live")!) { [weak self] html in
            guard let self, self.current(s) else { return }
            guard let html else {
                self.onStatus?(.failed("Couldn't reach YouTube"))
                return self.retry(s, after: 30, self.findLiveVideo)
            }
            if html.contains("This page isn't available") || html.contains("404 Not Found") {
                self.onStatus?(.failed("YouTube channel @\(self.handle) not found"))
                return self.retry(s, after: 120, self.findLiveVideo)
            }
            guard let video = Self.match(#"<link rel="canonical" href="https://www\.youtube\.com/watch\?v=([\w-]{11})""#, in: html),
                  html.contains("\"isLiveNow\":true") || html.contains("\"isLive\":true") else {
                self.onStatus?(.waitingForLive)
                return self.retry(s, after: 30, self.findLiveVideo)
            }
            self.openChat(video, s)
        }
    }

    private func openChat(_ video: String, _ s: Int) {
        get(URL(string: "https://www.youtube.com/live_chat?is_popout=1&v=\(video)")!) { [weak self] html in
            guard let self, self.current(s) else { return }
            guard let html,
                  let version = Self.match(#""INNERTUBE_CLIENT_VERSION":"([^"]+)""#, in: html),
                  let continuation = Self.match(#""continuation":"([^"]+)""#, in: html) else {
                self.onStatus?(.failed("This stream's chat is off or unavailable"))
                return self.retry(s, after: 30, self.findLiveVideo)
            }
            let key = Self.match(#""INNERTUBE_API_KEY":"([^"]+)""#, in: html)
            self.onStatus?(.connected)
            self.poll(continuation, version: version, key: key, s)
        }
    }

    // MARK: Following the chat

    private func poll(_ continuation: String, version: String, key: String?, _ s: Int) {
        var comps = URLComponents(string: "https://www.youtube.com/youtubei/v1/live_chat/get_live_chat")!
        comps.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
            + (key.map { [URLQueryItem(name: "key", value: $0)] } ?? [])
        var request = URLRequest(url: comps.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ChatHTTP.userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "context": ["client": ["clientName": "WEB", "clientVersion": version, "hl": "en"]],
            "continuation": continuation,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            DispatchQueue.main.async {
                guard let self, self.current(s) else { return }
                let chat = (json?["continuationContents"] as? [String: Any])?["liveChatContinuation"] as? [String: Any]
                for action in chat?["actions"] as? [[String: Any]] ?? [] { self.handle(action) }
                // The next continuation and how long to wait, under one of several names.
                let next = ((chat?["continuations"] as? [[String: Any]])?.first?.values.first as? [String: Any])
                guard let token = next?["continuation"] as? String else {
                    // No continuation: the stream ended (or the request failed). Look again.
                    self.onStatus?(.waitingForLive)
                    return self.retry(s, after: 15, self.findLiveVideo)
                }
                let wait = min(max((next?["timeoutMs"] as? Double ?? 2000) / 1000, 1), 8)
                self.retry(s, after: wait) { self.poll(token, version: version, key: key, $0) }
            }
        }.resume()
    }

    private func handle(_ action: [String: Any]) {
        guard let item = (action["addChatItemAction"] as? [String: Any])?["item"] as? [String: Any] else { return }
        alert(item)
        let renderer = (item["liveChatTextMessageRenderer"] ?? item["liveChatPaidMessageRenderer"]) as? [String: Any]
        guard let r = renderer, let id = r["id"] as? String, seen.insert(id).inserted else { return }
        if seen.count > 2000 { seen.removeAll() }

        let author = (r["authorName"] as? [String: Any])?["simpleText"] as? String ?? "someone"
        var parts: [ChatMessage.Part] = []
        if let amount = (r["purchaseAmountText"] as? [String: Any])?["simpleText"] as? String {
            parts.append(.text("[\(amount)] "))
        }
        for run in (r["message"] as? [String: Any])?["runs"] as? [[String: Any]] ?? [] {
            if let text = run["text"] as? String {
                parts.append(.text(text))
            } else if let emoji = run["emoji"] as? [String: Any] {
                let shortcut = (emoji["shortcuts"] as? [String])?.first ?? ""
                if emoji["isCustomEmoji"] as? Bool == true,
                   let thumbs = (emoji["image"] as? [String: Any])?["thumbnails"] as? [[String: Any]],
                   let url = (thumbs.last?["url"] as? String).flatMap(URL.init(string:)) {
                    parts.append(.emote(url, fallback: shortcut))
                } else {
                    parts.append(.text(emoji["emojiId"] as? String ?? shortcut)) // standard emoji: the character itself
                }
            }
        }
        var badges: [ChatMessage.Badge] = []
        for b in r["authorBadges"] as? [[String: Any]] ?? [] {
            guard let badge = b["liveChatAuthorBadgeRenderer"] as? [String: Any] else { continue }
            switch (badge["icon"] as? [String: Any])?["iconType"] as? String {
            case "OWNER": badges.append(.owner)
            case "MODERATOR": badges.append(.moderator)
            case "VERIFIED": badges.append(.verified)
            default: if badge["customThumbnail"] != nil { badges.append(.member) }
            }
        }
        onMessage?(ChatMessage(id: id, platform: .youtube, author: author, color: nil, badges: badges, parts: parts))
    }

    /// Super Chats, Super Stickers, memberships, gifted memberships and YouTube
    /// gifts. Super Chats also stay in the chat as a line.
    private func alert(_ item: [String: Any]) {
        func text(_ value: Any?) -> String? {
            guard let v = value as? [String: Any] else { return nil }
            let s = v["simpleText"] as? String ?? v["content"] as? String
                ?? (v["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            return s.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        }
        guard let (key, value) = item.first, let r = value as? [String: Any] else { return }
        // Super Chats are de-duplicated with the chat lines (after this); the rest here.
        if let id = r["id"] as? String {
            if key == "liveChatPaidMessageRenderer" {
                guard !seen.contains(id) else { return }
            } else {
                guard seen.insert("alert-" + id).inserted else { return }
            }
        }
        let author = text(r["authorName"]) ?? "Someone"
        let alert: StreamAlert? = switch key {
        case "liveChatPaidMessageRenderer":
            StreamAlert(platform: .youtube, kind: .money, name: author, action: "sent a Super Chat",
                        highlight: text(r["purchaseAmountText"]), message: text(r["message"]))
        case "liveChatPaidStickerRenderer":
            StreamAlert(platform: .youtube, kind: .money, name: author, action: "sent a Super Sticker",
                        highlight: text(r["purchaseAmountText"]))
        case "liveChatMembershipItemRenderer":
            // A milestone has "Member for 6 months" as its header; a new member has only a subtext.
            if let milestone = text(r["headerPrimaryText"]) {
                StreamAlert(platform: .youtube, kind: .subscription, name: author, action: "membership milestone:",
                            highlight: milestone.replacingOccurrences(of: "Member for ", with: ""),
                            message: text(r["message"]))
            } else {
                StreamAlert(platform: .youtube, kind: .subscription, name: author, action: "just became a member")
            }
        case "liveChatSponsorshipsGiftPurchaseAnnouncementRenderer":
            Self.giftedMemberships(r, author: text)
        case "giftMessageViewModel":
            // YouTube Gifts, bought with Jewels: "sent Star".
            StreamAlert(platform: .youtube, kind: .money, name: author.trimmingCharacters(in: .whitespaces),
                        action: "sent a gift:",
                        highlight: text(r["text"]).map { $0.hasPrefix("sent ") ? String($0.dropFirst(5)) : $0 })
        default:
            nil
        }
        if let alert { onAlert?(alert) }
    }

    /// "Gifted 5 Channel memberships": the count is the only number in the header.
    private static func giftedMemberships(_ r: [String: Any], author: ((Any?) -> String?)) -> StreamAlert {
        let header = ((r["header"] as? [String: Any])?["liveChatSponsorshipsHeaderRenderer"] as? [String: Any]) ?? [:]
        let line = author(header["primaryText"]) ?? ""
        let count = match(#"(\d+)"#, in: line).flatMap(Int.init) ?? 1
        return StreamAlert(platform: .youtube, kind: .gift, name: author(header["authorName"]) ?? "Someone",
                           action: "gifted", highlight: count == 1 ? "1 membership" : "\(count) memberships")
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
