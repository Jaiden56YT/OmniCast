import AppKit
import CryptoKit
import Foundation
import Network

/// A signed-in account's tokens, kept in the keychain.
struct OAuthToken: Codable {
    var access: String
    var refresh: String?
    var expires: Date

    var isExpired: Bool { expires < Date().addingTimeInterval(60) }

    init(json: [String: Any], keepingRefresh old: String? = nil) throws {
        guard let access = json["access_token"] as? String else { throw AccountError.from(json) }
        self.access = access
        refresh = json["refresh_token"] as? String ?? old
        expires = Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)
    }
}

enum AccountError: LocalizedError {
    case notSetUp(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notSetUp(let what): "\(what) isn't connected. Connect it in Settings → Accounts."
        case .message(let text): text
        }
    }

    /// The most useful text from an OAuth or API error body.
    static func from(_ json: [String: Any]?, status: Int = 0) -> AccountError {
        let text = json?["message"] as? String ?? json?["error_description"] as? String
            ?? (json?["error"] as? [String: Any])?["message"] as? String ?? json?["error"] as? String
        return .message(text.map { "\($0)" } ?? "Request failed (\(status))")
    }
}

/// Keychain storage for client secrets and tokens. Reads run off the main
/// thread: a keychain prompt blocks the thread that asks until it's answered.
enum AccountStore {
    static let service = "OmniCast Accounts"

    static func secret(_ name: String) async -> String? {
        await Task.detached { Keychain.read(name, service: service) }.value
    }

    static func setSecret(_ name: String, _ value: String) {
        DispatchQueue.global(qos: .userInitiated).async { Keychain.write(name, value, service: service) }
    }

    static func token(_ platform: String) async -> OAuthToken? {
        await Task.detached {
            Keychain.read("\(platform).token", service: service)
                .flatMap { try? JSONDecoder().decode(OAuthToken.self, from: Data($0.utf8)) }
        }.value
    }

    static func setToken(_ platform: String, _ token: OAuthToken?) {
        let text = token.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        DispatchQueue.global(qos: .userInitiated).async { Keychain.write("\(platform).token", text, service: service) }
    }

    static func hasToken(_ platform: String) -> Bool { Keychain.exists("\(platform).token", service: service) }
}

enum HTTP {
    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:],
                        json body: Any? = nil, form: [String: String]? = nil) async throws -> (Int, Any?) {
        var r = URLRequest(url: url)
        r.httpMethod = method
        headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else if let form {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = encode(form).data(using: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(for: r)
        let json = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    static func encode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
    }

    static func url(_ base: String, _ query: [String: String]) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c.url!
    }
}

enum PKCE {
    /// A random verifier and its S256 challenge.
    static func make() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = base64url(Data(bytes))
        return (verifier, base64url(Data(SHA256.hash(data: Data(verifier.utf8)))))
    }

    static func state() -> String { base64url(Data((0..<16).map { _ in UInt8.random(in: 0...255) })) }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// Catches an OAuth redirect on this Mac: listens on the loopback interface
/// only (never the network), on a fixed port so the redirect URL can be
/// registered with the platform, and answers the browser with a short page.
enum LoopbackRedirect {
    static let port: UInt16 = 39651

    /// Opens the authorize URL in the browser and waits (up to 5 minutes) for
    /// the redirect carrying `code` for this `state`.
    static func authorize(_ url: URL, state: String) async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        defer { listener.cancel() }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (done: CheckedContinuation<String, Error>) in
                    var finished = false
                    let finish: (Result<String, Error>) -> Void = { result in
                        guard !finished else { return }
                        finished = true
                        done.resume(with: result)
                    }
                    listener.newConnectionHandler = { connection in
                        connection.start(queue: .global())
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                            let query = URLComponents(string: "http://localhost\(target)")?.queryItems ?? []
                            let value = { (name: String) in query.first { $0.name == name }?.value }
                            let ok = value("code") != nil && value("state") == state
                            let page = ok ? "Signed in. You can close this tab and go back to OmniCast."
                                : "Sign-in didn't finish: \(value("error_description") ?? value("error") ?? "no code"). Try again from OmniCast."
                            let html = "<html><body style=\"font:16px -apple-system;padding:40px\">\(page)</body></html>"
                            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                            // Browsers also ask for /favicon.ico; only the redirect carries a code or an error.
                            if let code = value("code"), value("state") == state {
                                finish(.success(code))
                            } else if let error = value("error") {
                                finish(.failure(AccountError.message(value("error_description") ?? error)))
                            }
                        }
                    }
                    listener.stateUpdateHandler = { s in
                        switch s {
                        case .failed(let error):
                            finish(.failure(AccountError.message("Couldn't listen for the sign-in (\(error.localizedDescription)). Is another sign-in open?")))
                        case .cancelled:
                            finish(.failure(AccountError.message("Sign-in timed out")))
                        default:
                            break
                        }
                    }
                    listener.start(queue: .global())
                    DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(300))
                // Ends the wait above: cancelling the listener resolves it.
                listener.cancel()
                throw AccountError.message("Sign-in timed out")
            }
            let code = try await group.next()!
            group.cancelAll()
            return code
        }
    }
}
