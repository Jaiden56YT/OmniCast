import Foundation
import Observation

struct CallMember: Identifiable, Equatable {
    let id: String
    var name: String
    var avatarURL: URL
    var speaking = false
    var muted = false
    var deafened = false
}

/// Who's in the user's current Discord voice call and who is talking, read from
/// the Discord app through its local RPC socket.
///
/// Discord only gives voice events to an app the user registers themselves
/// (Client ID + Secret, with http://localhost as a redirect). The user approves
/// it once in Discord; the token is kept in the keychain and refreshed.
@MainActor
@Observable
final class DiscordCall {
    static let shared = DiscordCall()

    enum Status: Equatable {
        case notSetUp, disconnected, connecting, waitingForApproval, noCall
        case inCall(String)
        case failed(String)
    }

    private(set) var status = Status.notSetUp
    /// In the order they joined.
    private(set) var members: [CallMember] = []

    /// Called on every join/leave/rename, and on talking changes with the user id.
    var onMembersChanged: (() -> Void)?
    var onSpeaking: ((String, Bool) -> Void)?

    static let redirectURI = "http://localhost"
    private static let scopes = ["rpc", "rpc.voice.read"]

    var clientID: String {
        get { UserDefaults.standard.string(forKey: "discord.clientID") ?? "" }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespaces), forKey: "discord.clientID") }
    }

    var clientSecret: String {
        get { Keychain.read("discord.secret", service: Keychain.discordService) ?? "" }
        set { Keychain.write("discord.secret", newValue.trimmingCharacters(in: .whitespaces), service: Keychain.discordService) }
    }

    var isSetUp: Bool { !clientID.isEmpty && !clientSecret.isEmpty }

    // MARK: Sessions

    /// One per running Discord client; the one the user is in a call on is `active`.
    private final class Session {
        let ipc: DiscordIPC
        var authenticated = false
        var channelID: String?
        var pending: [String: ([String: Any]) -> Void] = [:]
        init(ipc: DiscordIPC) { self.ipc = ipc }
    }

    private var sessions: [Session] = []
    private weak var active: Session?
    private var authorizing = false
    private var wantConnected = false
    private var retryTimer: Timer?

    private struct Token: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }

    private var token: Token? {
        get {
            Keychain.read("discord.token", service: Keychain.discordService)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(Token.self, from: $0) }
        }
        set {
            let text = newValue.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
            Keychain.write("discord.token", text ?? "", service: Keychain.discordService)
        }
    }

    func connect() {
        guard isSetUp else { status = .notSetUp; return }
        wantConnected = true
        UserDefaults.standard.set(true, forKey: "discord.autoConnect")
        openSessions()
    }

    func disconnect() {
        wantConnected = false
        UserDefaults.standard.set(false, forKey: "discord.autoConnect")
        retryTimer?.invalidate()
        retryTimer = nil
        closeSessions()
        status = isSetUp ? .disconnected : .notSetUp
    }

    /// Forgets the approval; the next connect asks in Discord again.
    func signOut() {
        token = nil
        disconnect()
    }

    /// Reconnects on launch if the user left it connected.
    func resume() {
        status = isSetUp ? .disconnected : .notSetUp
        if isSetUp, UserDefaults.standard.bool(forKey: "discord.autoConnect") { connect() }
    }

    private func openSessions() {
        closeSessions()
        let paths = DiscordIPC.socketPaths()
        guard !paths.isEmpty else {
            status = .failed("Discord isn't running")
            scheduleRetry()
            return
        }
        status = .connecting
        for path in paths {
            let ipc = DiscordIPC(path: path)
            let session = Session(ipc: ipc)
            ipc.onMessage = { [weak self, weak session] msg in
                guard let self, let session else { return }
                self.handle(msg, from: session)
            }
            ipc.onClose = { [weak self, weak session] reason in
                guard let self, let session else { return }
                self.closed(session, reason: reason)
            }
            guard ipc.connect() else { continue }
            sessions.append(session)
            ipc.send(.handshake, ["v": 1, "client_id": clientID])
        }
        if sessions.isEmpty {
            status = .failed("Couldn't reach Discord")
            scheduleRetry()
        }
    }

    private func closeSessions() {
        for session in sessions {
            session.ipc.onClose = nil
            session.ipc.close()
        }
        sessions = []
        active = nil
        authorizing = false
        setMembers([])
    }

    private func closed(_ session: Session, reason: String) {
        sessions.removeAll { $0 === session }
        if active === session {
            active = nil
            setMembers([])
        }
        guard sessions.isEmpty else { return }
        if reason.contains("Invalid Client ID") {
            status = .failed("Discord doesn't recognise the Client ID")
            return
        }
        status = wantConnected ? .failed("Lost the connection to Discord") : .disconnected
        scheduleRetry()
    }

    private func scheduleRetry() {
        guard wantConnected, retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { _ in
            MainActor.assumeIsolated {
                let call = DiscordCall.shared
                call.retryTimer = nil
                if call.wantConnected, call.sessions.isEmpty { call.openSessions() }
            }
        }
    }

    // MARK: Protocol

    private func send(_ session: Session, _ cmd: String, args: [String: Any] = [:], evt: String? = nil,
                      reply: (([String: Any]) -> Void)? = nil) {
        let nonce = UUID().uuidString
        var payload: [String: Any] = ["cmd": cmd, "args": args, "nonce": nonce]
        if let evt { payload["evt"] = evt }
        if let reply { session.pending[nonce] = reply }
        session.ipc.send(.frame, payload)
    }

    private func handle(_ msg: [String: Any], from session: Session) {
        if let nonce = msg["nonce"] as? String, let reply = session.pending.removeValue(forKey: nonce) {
            reply(msg)
            return
        }
        guard msg["cmd"] as? String == "DISPATCH", let evt = msg["evt"] as? String else { return }
        let data = msg["data"] as? [String: Any] ?? [:]
        switch evt {
        case "READY": authenticate(session)
        case "VOICE_CHANNEL_SELECT": channelSelected(data["channel_id"] as? String, on: session)
        case "VOICE_STATE_CREATE", "VOICE_STATE_UPDATE":
            guard session === active, let member = Self.member(from: data) else { return }
            upsert(member)
        case "VOICE_STATE_DELETE":
            guard session === active, let id = (data["user"] as? [String: Any])?["id"] as? String else { return }
            setMembers(members.filter { $0.id != id })
        case "SPEAKING_START", "SPEAKING_STOP":
            guard session === active, let id = data["user_id"] as? String,
                  let i = members.firstIndex(where: { $0.id == id }) else { return }
            let speaking = evt == "SPEAKING_START"
            guard members[i].speaking != speaking else { return }
            members[i].speaking = speaking
            onSpeaking?(id, speaking)
        default: break
        }
    }

    private static func error(in msg: [String: Any]) -> (code: Int, message: String)? {
        guard msg["evt"] as? String == "ERROR" else { return nil }
        let data = msg["data"] as? [String: Any] ?? [:]
        return (data["code"] as? Int ?? 0, data["message"] as? String ?? "Discord returned an error")
    }

    private func authenticate(_ session: Session) {
        guard let token else {
            authorize(session)
            return
        }
        if token.expires < Date().addingTimeInterval(60) {
            Task { await refresh(token, then: session) }
            return
        }
        send(session, "AUTHENTICATE", args: ["access_token": token.access]) { [weak self, weak session] msg in
            guard let self, let session else { return }
            if Self.error(in: msg) != nil {
                // Revoked or expired early: try the refresh token, then a fresh approval.
                Task { await self.refresh(token, then: session) }
                return
            }
            session.authenticated = true
            self.subscribe(session)
        }
    }

    /// Asks the user to approve OmniCast in Discord. Only one session asks; the
    /// others authenticate with the same token once it arrives.
    private func authorize(_ session: Session) {
        guard !authorizing else { return }
        authorizing = true
        status = .waitingForApproval
        send(session, "AUTHORIZE", args: ["client_id": clientID, "scopes": Self.scopes]) { [weak self] msg in
            guard let self else { return }
            if let err = Self.error(in: msg) {
                self.authorizing = false
                self.status = .failed(err.code == 5000 ? "Not approved in Discord" : err.message)
                return
            }
            guard let code = (msg["data"] as? [String: Any])?["code"] as? String else { return }
            Task { await self.exchange(["grant_type": "authorization_code", "code": code]) }
        }
    }

    private func refresh(_ old: Token, then session: Session) async {
        token = nil
        if await exchange(["grant_type": "refresh_token", "refresh_token": old.refresh]) { return }
        authorize(session)
    }

    /// Trades a code or refresh token for an access token, then authenticates
    /// every session that's waiting.
    @discardableResult
    private func exchange(_ grant: [String: String]) async -> Bool {
        var form = grant
        form["client_id"] = clientID
        form["client_secret"] = clientSecret
        form["redirect_uri"] = Self.redirectURI
        var request = URLRequest(url: URL(string: "https://discord.com/api/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)

        authorizing = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status = .failed("Couldn't reach discord.com to finish signing in")
            return false
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            let reason = json["error_description"] as? String ?? json["error"] as? String ?? "sign-in failed"
            status = .failed(reason.contains("client") ? "Check the Client ID and Secret" : "Discord: \(reason)")
            return false
        }
        let expires = Date().addingTimeInterval(json["expires_in"] as? Double ?? 604_800)
        token = Token(access: access, refresh: refresh, expires: expires)
        for session in sessions where !session.authenticated { authenticate(session) }
        return true
    }

    private func subscribe(_ session: Session) {
        if active == nil { status = .noCall }
        send(session, "SUBSCRIBE", evt: "VOICE_CHANNEL_SELECT")
        send(session, "GET_SELECTED_VOICE_CHANNEL") { [weak self, weak session] msg in
            guard let self, let session, let channel = msg["data"] as? [String: Any] else { return }
            self.enter(channel, on: session)
        }
    }

    private func channelSelected(_ channelID: String?, on session: Session) {
        guard let channelID else {
            if session === active { leave() }
            return
        }
        send(session, "GET_CHANNEL", args: ["channel_id": channelID]) { [weak self, weak session] msg in
            guard let self, let session, let channel = msg["data"] as? [String: Any] else { return }
            self.enter(channel, on: session)
        }
    }

    private static let channelEvents = ["VOICE_STATE_CREATE", "VOICE_STATE_UPDATE", "VOICE_STATE_DELETE",
                                        "SPEAKING_START", "SPEAKING_STOP"]

    private func enter(_ channel: [String: Any], on session: Session) {
        guard let id = channel["id"] as? String else { return }
        if active !== session || active?.channelID != id { leave() }
        active = session
        session.channelID = id
        for evt in Self.channelEvents {
            send(session, "SUBSCRIBE", args: ["channel_id": id], evt: evt)
        }
        let states = channel["voice_states"] as? [[String: Any]] ?? []
        setMembers(states.compactMap(Self.member(from:)))
        status = .inCall(channel["name"] as? String ?? "Voice call")
    }

    private func leave() {
        if let session = active, let id = session.channelID {
            for evt in Self.channelEvents {
                send(session, "UNSUBSCRIBE", args: ["channel_id": id], evt: evt)
            }
            session.channelID = nil
        }
        active = nil
        setMembers([])
        if !sessions.isEmpty { status = .noCall }
    }

    private func upsert(_ member: CallMember) {
        var list = members
        if let i = list.firstIndex(where: { $0.id == member.id }) {
            var updated = member
            updated.speaking = list[i].speaking
            list[i] = updated
        } else {
            list.append(member)
        }
        setMembers(list)
    }

    private func setMembers(_ list: [CallMember]) {
        guard list != members else { return }
        members = list
        onMembersChanged?()
    }

    /// A voice state from GET_CHANNEL or a VOICE_STATE event.
    private static func member(from state: [String: Any]) -> CallMember? {
        guard let user = state["user"] as? [String: Any], let id = user["id"] as? String else { return nil }
        let voice = state["voice_state"] as? [String: Any] ?? [:]
        let name = (state["nick"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (user["global_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? user["username"] as? String ?? "Someone"
        let avatar: URL
        if let hash = user["avatar"] as? String {
            avatar = URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(hash).png?size=256")!
        } else {
            let index = ((UInt64(id) ?? 0) >> 22) % 6
            avatar = URL(string: "https://cdn.discordapp.com/embed/avatars/\(index).png")!
        }
        return CallMember(
            id: id, name: name, avatarURL: avatar,
            muted: (voice["self_mute"] as? Bool ?? false) || (voice["mute"] as? Bool ?? false)
                || (voice["suppress"] as? Bool ?? false),
            deafened: (voice["self_deaf"] as? Bool ?? false) || (voice["deaf"] as? Bool ?? false))
    }
}
