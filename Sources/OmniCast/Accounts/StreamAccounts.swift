import AppKit
import Foundation
import Observation

struct StreamCategory: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let image: URL?
}

struct ChannelInfo {
    var title: String
    var category: StreamCategory?
}

/// The token for one platform: loaded from the keychain on first use (off the
/// main thread), refreshed when it's about to expire, saved back when it changes.
@MainActor
final class TokenKeeper {
    let key: String
    let name: String
    private var cached: OAuthToken?
    private var loaded = false
    var refresher: ((OAuthToken) async throws -> OAuthToken)?

    init(_ key: String, name: String) {
        self.key = key
        self.name = name
    }

    func valid() async throws -> OAuthToken {
        if !loaded {
            cached = await AccountStore.token(key)
            loaded = true
        }
        guard var token = cached else { throw AccountError.notSetUp(name) }
        if token.isExpired {
            guard token.refresh != nil, let refresher else { throw AccountError.notSetUp(name) }
            do {
                token = try await refresher(token)
            } catch {
                store(nil)
                throw AccountError.message("\(name) signed you out. Connect again in Settings → Accounts.")
            }
            store(token)
        }
        return token
    }

    func store(_ token: OAuthToken?) {
        cached = token
        loaded = true
        AccountStore.setToken(key, token)
    }
}

// MARK: - Twitch

/// Twitch Helix with a user token (scopes channel:manage:broadcast for the
/// title and game, moderator:read:followers for follow alerts). Sign-in is
/// Twitch's device-code flow: the app shows a code, you approve it at
/// twitch.tv/activate, and only a Client ID is needed (a "Public" app).
@MainActor
@Observable
final class TwitchAccount {
    static let shared = TwitchAccount()

    var clientID = UserDefaults.standard.string(forKey: "accounts.twitch.clientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "accounts.twitch.clientID") }
    }
    private(set) var login = UserDefaults.standard.string(forKey: "accounts.twitch.login")
    private var userID = UserDefaults.standard.string(forKey: "accounts.twitch.userID")
    /// While connecting: the code to type at twitch.tv/activate.
    private(set) var pendingCode: String?

    private let tokens = TokenKeeper("twitch", name: "Twitch")
    private static let scopes = "channel:manage:broadcast \(followScope)"
    static let followScope = "moderator:read:followers"

    init() {
        tokens.refresher = { [weak self] old in
            guard let self else { throw AccountError.notSetUp("Twitch") }
            let (_, json) = try await HTTP.request(URL(string: "https://id.twitch.tv/oauth2/token")!, method: "POST",
                form: ["grant_type": "refresh_token", "refresh_token": old.refresh ?? "", "client_id": self.clientID])
            return try OAuthToken(json: json as? [String: Any] ?? [:], keepingRefresh: old.refresh)
        }
    }

    var isConnected: Bool { login != nil }

    func connect() async throws {
        guard !clientID.isEmpty else { throw AccountError.message("Paste your Twitch Client ID first") }
        let (_, start) = try await HTTP.request(URL(string: "https://id.twitch.tv/oauth2/device")!, method: "POST",
                                                form: ["client_id": clientID, "scopes": Self.scopes])
        guard let s = start as? [String: Any], let device = s["device_code"] as? String,
              let code = s["user_code"] as? String,
              let page = (s["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw AccountError.from(start as? [String: Any])
        }
        pendingCode = code
        defer { pendingCode = nil }
        NSWorkspace.shared.open(page)
        let interval = max(s["interval"] as? Double ?? 5, 2)
        let deadline = Date().addingTimeInterval(s["expires_in"] as? Double ?? 1800)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let (status, json) = try await HTTP.request(URL(string: "https://id.twitch.tv/oauth2/token")!, method: "POST",
                form: ["client_id": clientID, "scopes": Self.scopes, "device_code": device,
                       "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let body = json as? [String: Any] ?? [:]
            if status == 200 {
                tokens.store(try OAuthToken(json: body))
                try await loadUser()
                return
            }
            if (body["message"] as? String) != "authorization_pending" { throw AccountError.from(body, status: status) }
        }
        throw AccountError.message("The Twitch code expired. Try again.")
    }

    func signOut() {
        tokens.store(nil)
        login = nil
        userID = nil
        UserDefaults.standard.removeObject(forKey: "accounts.twitch.login")
        UserDefaults.standard.removeObject(forKey: "accounts.twitch.userID")
    }

    private func api(_ path: String, _ query: [String: String] = [:], method: String = "GET",
                     body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await tokens.valid()
        let (status, json) = try await HTTP.request(HTTP.url("https://api.twitch.tv/helix/\(path)", query), method: method,
            headers: ["Authorization": "Bearer \(token.access)", "Client-Id": clientID], json: body)
        guard (200..<300).contains(status) else { throw AccountError.from(json as? [String: Any], status: status) }
        return json as? [String: Any] ?? [:]
    }

    private func loadUser() async throws {
        let json = try await api("users")
        guard let user = (json["data"] as? [[String: Any]])?.first, let id = user["id"] as? String else {
            throw AccountError.message("Twitch didn't return your account")
        }
        userID = id
        login = user["display_name"] as? String ?? user["login"] as? String
        UserDefaults.standard.set(id, forKey: "accounts.twitch.userID")
        UserDefaults.standard.set(login, forKey: "accounts.twitch.login")
    }

    func current() async throws -> ChannelInfo {
        if userID == nil { try await loadUser() }
        let json = try await api("channels", ["broadcaster_id": userID ?? ""])
        let c = (json["data"] as? [[String: Any]])?.first ?? [:]
        let game = (c["game_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ChannelInfo(title: c["title"] as? String ?? "",
                           category: game.map { StreamCategory(id: $0, name: c["game_name"] as? String ?? "", image: nil) })
    }

    func update(title: String?, category: StreamCategory?) async throws {
        if userID == nil { try await loadUser() }
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let category { body["game_id"] = category.id }
        guard !body.isEmpty else { return }
        _ = try await api("channels", ["broadcaster_id": userID ?? ""], method: "PATCH", body: body)
    }

    /// Asks Twitch to send follows of your channel to an EventSub WebSocket
    /// session. Accounts connected before follow alerts existed lack the scope
    /// and have to sign in again.
    func subscribeToFollows(session: String) async throws {
        let token = try await tokens.valid()
        let (status, json) = try await HTTP.request(URL(string: "https://id.twitch.tv/oauth2/validate")!,
                                                    headers: ["Authorization": "OAuth \(token.access)"])
        guard status == 200 else { throw AccountError.message("Twitch signed you out. Connect again in Settings → Accounts.") }
        let scopes = (json as? [String: Any])?["scopes"] as? [String] ?? []
        guard scopes.contains(Self.followScope) else {
            throw AccountError.message("Sign in to Twitch again (Settings → Accounts) to allow follow alerts")
        }
        if userID == nil { try await loadUser() }
        let id = userID ?? ""
        _ = try await api("eventsub/subscriptions", method: "POST", body: [
            "type": "channel.follow", "version": "2",
            "condition": ["broadcaster_user_id": id, "moderator_user_id": id],
            "transport": ["method": "websocket", "session_id": session],
        ])
    }

    func search(_ query: String) async throws -> [StreamCategory] {
        let json = try await api("search/categories", ["query": query, "first": "12"])
        return (json["data"] as? [[String: Any]] ?? []).compactMap { c in
            guard let id = c["id"] as? String, let name = c["name"] as? String else { return nil }
            let art = (c["box_art_url"] as? String)?
                .replacingOccurrences(of: "{width}", with: "52").replacingOccurrences(of: "{height}", with: "72")
            return StreamCategory(id: id, name: name, image: art.flatMap(URL.init(string:)))
        }
    }
}

// MARK: - Kick

/// Kick's official public API (api.kick.com) with OAuth 2.1 + PKCE. Needs a
/// Kick app (Client ID + Secret) with http://localhost:39651/callback as its
/// redirect URL.
@MainActor
@Observable
final class KickAccount {
    static let shared = KickAccount()
    static let redirect = "http://localhost:\(LoopbackRedirect.port)/callback"

    var clientID = UserDefaults.standard.string(forKey: "accounts.kick.clientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "accounts.kick.clientID") }
    }
    private(set) var login = UserDefaults.standard.string(forKey: "accounts.kick.login")
    var hasSecret: Bool { Keychain.exists("kick.secret", service: AccountStore.service) }

    private let tokens = TokenKeeper("kick", name: "Kick")

    init() {
        tokens.refresher = { [weak self] old in
            guard let self, let secret = await AccountStore.secret("kick.secret") else { throw AccountError.notSetUp("Kick") }
            let (_, json) = try await HTTP.request(URL(string: "https://id.kick.com/oauth/token")!, method: "POST",
                form: ["grant_type": "refresh_token", "refresh_token": old.refresh ?? "",
                       "client_id": self.clientID, "client_secret": secret])
            return try OAuthToken(json: json as? [String: Any] ?? [:], keepingRefresh: old.refresh)
        }
    }

    var isConnected: Bool { login != nil }

    func setSecret(_ secret: String) { AccountStore.setSecret("kick.secret", secret.trimmingCharacters(in: .whitespaces)) }

    func connect() async throws {
        guard !clientID.isEmpty, let secret = await AccountStore.secret("kick.secret"), !secret.isEmpty else {
            throw AccountError.message("Paste your Kick Client ID and Secret first")
        }
        let pkce = PKCE.make(), state = PKCE.state()
        let url = HTTP.url("https://id.kick.com/oauth/authorize", [
            "response_type": "code", "client_id": clientID, "redirect_uri": Self.redirect,
            "scope": "user:read channel:read channel:write", "code_challenge": pkce.challenge,
            "code_challenge_method": "S256", "state": state,
        ])
        let code = try await LoopbackRedirect.authorize(url, state: state)
        let (status, json) = try await HTTP.request(URL(string: "https://id.kick.com/oauth/token")!, method: "POST",
            form: ["grant_type": "authorization_code", "client_id": clientID, "client_secret": secret,
                   "redirect_uri": Self.redirect, "code_verifier": pkce.verifier, "code": code])
        guard status == 200 else {
            // Kick answers a bad ID or secret with a bare 401.
            if status == 400 || status == 401 {
                throw AccountError.message("Kick didn't accept the Client ID or Secret, or the app's redirect URL isn't \(Self.redirect)")
            }
            throw AccountError.from(json as? [String: Any], status: status)
        }
        tokens.store(try OAuthToken(json: json as? [String: Any] ?? [:]))
        _ = try await current()
    }

    func signOut() {
        tokens.store(nil)
        login = nil
        UserDefaults.standard.removeObject(forKey: "accounts.kick.login")
    }

    private func api(_ path: String, _ query: [String: String] = [:], method: String = "GET",
                     body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await tokens.valid()
        let (status, json) = try await HTTP.request(HTTP.url("https://api.kick.com/public/\(path)", query), method: method,
            headers: ["Authorization": "Bearer \(token.access)", "Accept": "application/json"], json: body)
        guard (200..<300).contains(status) else { throw AccountError.from(json as? [String: Any], status: status) }
        return json as? [String: Any] ?? [:]
    }

    /// Without a broadcaster id, /channels returns the signed-in user's channel.
    func current() async throws -> ChannelInfo {
        let json = try await api("v1/channels")
        let c = (json["data"] as? [[String: Any]])?.first ?? [:]
        if let slug = c["slug"] as? String {
            login = slug
            UserDefaults.standard.set(slug, forKey: "accounts.kick.login")
        }
        let cat = c["category"] as? [String: Any]
        let category = (cat?["id"] as? Int).map {
            StreamCategory(id: String($0), name: cat?["name"] as? String ?? "",
                           image: (cat?["thumbnail"] as? String).flatMap(URL.init(string:)))
        }
        return ChannelInfo(title: c["stream_title"] as? String ?? "", category: category)
    }

    func update(title: String?, category: StreamCategory?) async throws {
        var body: [String: Any] = [:]
        if let title { body["stream_title"] = title }
        if let category, let id = Int(category.id) { body["category_id"] = id }
        guard !body.isEmpty else { return }
        _ = try await api("v1/channels", method: "PATCH", body: body)
    }

    func search(_ query: String) async throws -> [StreamCategory] {
        // v2 is the current search; v1 is the older one some accounts still get.
        let json: [String: Any]
        do { json = try await api("v2/categories", ["name": query, "limit": "12"]) } catch {
            json = try await api("v1/categories", ["q": query])
        }
        return (json["data"] as? [[String: Any]] ?? []).prefix(12).compactMap { c in
            guard let id = c["id"] as? Int, let name = c["name"] as? String else { return nil }
            return StreamCategory(id: String(id), name: name, image: (c["thumbnail"] as? String).flatMap(URL.init(string:)))
        }
    }
}

// MARK: - YouTube

/// YouTube Data API v3 with Google OAuth (desktop client + PKCE, loopback
/// redirect). Renames the live (or next scheduled) broadcast. YouTube's game
/// isn't settable through the API, so YouTube gets the title only.
@MainActor
@Observable
final class YouTubeAccount {
    static let shared = YouTubeAccount()
    static let redirect = "http://127.0.0.1:\(LoopbackRedirect.port)"

    var clientID = UserDefaults.standard.string(forKey: "accounts.youtube.clientID") ?? "" {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespaces), forKey: "accounts.youtube.clientID") }
    }
    private(set) var login = UserDefaults.standard.string(forKey: "accounts.youtube.login")
    var hasSecret: Bool { Keychain.exists("youtube.secret", service: AccountStore.service) }

    private let tokens = TokenKeeper("youtube", name: "YouTube")

    init() {
        tokens.refresher = { [weak self] old in
            guard let self, let secret = await AccountStore.secret("youtube.secret") else { throw AccountError.notSetUp("YouTube") }
            let (_, json) = try await HTTP.request(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST",
                form: ["grant_type": "refresh_token", "refresh_token": old.refresh ?? "",
                       "client_id": self.clientID, "client_secret": secret])
            return try OAuthToken(json: json as? [String: Any] ?? [:], keepingRefresh: old.refresh)
        }
    }

    var isConnected: Bool { login != nil }

    func setSecret(_ secret: String) { AccountStore.setSecret("youtube.secret", secret.trimmingCharacters(in: .whitespaces)) }

    func connect() async throws {
        guard !clientID.isEmpty, let secret = await AccountStore.secret("youtube.secret"), !secret.isEmpty else {
            throw AccountError.message("Paste your Google Client ID and Secret first")
        }
        let pkce = PKCE.make(), state = PKCE.state()
        let url = HTTP.url("https://accounts.google.com/o/oauth2/v2/auth", [
            "client_id": clientID, "redirect_uri": Self.redirect, "response_type": "code",
            "scope": "https://www.googleapis.com/auth/youtube", "code_challenge": pkce.challenge,
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent", "state": state,
        ])
        let code = try await LoopbackRedirect.authorize(url, state: state)
        let (status, json) = try await HTTP.request(URL(string: "https://oauth2.googleapis.com/token")!, method: "POST",
            form: ["grant_type": "authorization_code", "client_id": clientID, "client_secret": secret,
                   "redirect_uri": Self.redirect, "code_verifier": pkce.verifier, "code": code])
        guard status == 200 else { throw AccountError.from(json as? [String: Any], status: status) }
        tokens.store(try OAuthToken(json: json as? [String: Any] ?? [:]))
        let me = try await api("channels", ["part": "snippet", "mine": "true"])
        let snippet = ((me["items"] as? [[String: Any]])?.first?["snippet"]) as? [String: Any]
        login = snippet?["customUrl"] as? String ?? snippet?["title"] as? String ?? "YouTube"
        UserDefaults.standard.set(login, forKey: "accounts.youtube.login")
    }

    func signOut() {
        tokens.store(nil)
        login = nil
        UserDefaults.standard.removeObject(forKey: "accounts.youtube.login")
    }

    private func api(_ path: String, _ query: [String: String], method: String = "GET",
                     body: [String: Any]? = nil) async throws -> [String: Any] {
        let token = try await tokens.valid()
        let (status, json) = try await HTTP.request(HTTP.url("https://www.googleapis.com/youtube/v3/\(path)", query),
            method: method, headers: ["Authorization": "Bearer \(token.access)"], json: body)
        guard (200..<300).contains(status) else { throw AccountError.from(json as? [String: Any], status: status) }
        return json as? [String: Any] ?? [:]
    }

    /// The live broadcast, or else the next scheduled one.
    private func broadcast() async throws -> [String: Any] {
        for status in ["active", "upcoming"] {
            let json = try await api("liveBroadcasts", ["part": "snippet", "broadcastStatus": status, "broadcastType": "all"])
            if let item = (json["items"] as? [[String: Any]])?.first { return item }
        }
        throw AccountError.message("No live or scheduled YouTube stream to rename yet. Go live (or schedule one) first.")
    }

    /// Your newest subscribers, newest first. YouTube only lists people whose
    /// subscriptions are public, and only the most recent ones.
    func recentSubscribers() async throws -> [(id: String, name: String)] {
        let json = try await api("subscriptions", ["part": "subscriberSnippet", "myRecentSubscribers": "true",
                                                   "maxResults": "50"])
        return (json["items"] as? [[String: Any]] ?? []).compactMap { item in
            let snippet = item["subscriberSnippet"] as? [String: Any]
            guard let id = snippet?["channelId"] as? String ?? item["id"] as? String else { return nil }
            return (id, snippet?["title"] as? String ?? "Someone")
        }
    }

    func current() async throws -> ChannelInfo {
        let snippet = try await broadcast()["snippet"] as? [String: Any]
        return ChannelInfo(title: snippet?["title"] as? String ?? "", category: nil)
    }

    func update(title: String) async throws {
        let b = try await broadcast()
        guard let id = b["id"] as? String, let old = b["snippet"] as? [String: Any] else { return }
        // An update replaces the whole snippet, so carry the rest over.
        var snippet: [String: Any] = ["title": title]
        for key in ["description", "scheduledStartTime", "scheduledEndTime"] { snippet[key] = old[key] }
        _ = try await api("liveBroadcasts", ["part": "snippet"], method: "PUT", body: ["id": id, "snippet": snippet])
    }
}
