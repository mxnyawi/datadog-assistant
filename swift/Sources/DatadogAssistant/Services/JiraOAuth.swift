import Foundation
import Network
import Security

/// Jira Cloud OAuth 2.0 (3LO) — the client-credential flow the Python app
/// uses: client ID + secret (from the shared LastPass note's `jiraClientID` /
/// `jiraClientSecret` fields), browser consent at auth.atlassian.com, a local
/// one-shot callback server on port 8917, cloud-id resolution via
/// accessible-resources, and refresh-token rotation. Requests then go Bearer
/// against `api.atlassian.com/ex/jira/<cloudID>`.
///
/// Secrets at rest: the client secret and refresh token live in one Keychain
/// blob (service `datadog-assistant-jira-oauth`, same name as the Python
/// app). In LastPass mode the client secret is re-read from the vault instead
/// of being persisted. Only the client ID, cloud id, and site URL go to
/// UserDefaults.
enum JiraOAuth {
    static let callbackPort: UInt16 = 8917
    private static let redirectURI = "http://localhost:8917/callback"
    private static let scopes = "read:jira-work write:jira-work read:jira-user offline_access"

    private static let blobService = "datadog-assistant-jira-oauth"
    private static let clientIDKey = "jiraOAuthClientID"
    private static let cloudIDKey = "jiraOAuthCloudID"
    private static let siteURLKey = "jiraOAuthSiteURL"

    enum OAuthError: LocalizedError {
        case noCredentials
        case timedOut
        case stateMismatch
        case noCode(String)
        case tokenExchange(String)
        case noRefreshToken
        case noSite
        case notConnected

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No Jira client ID/secret — add jiraClientID and jiraClientSecret "
                    + "to the LastPass note, or enter them in Settings → Jira."
            case .timedOut: return "Jira sign-in timed out — no callback received."
            case .stateMismatch: return "OAuth state mismatch — try connecting again."
            case .noCode(let detail):
                return "Jira authorization failed\(detail.isEmpty ? "." : ": \(detail)")"
            case .tokenExchange(let detail): return "Jira token exchange failed: \(detail)"
            case .noRefreshToken:
                return "Atlassian returned no refresh token — remove the app's prior "
                    + "consent at id.atlassian.com and connect again."
            case .noSite: return "Your Atlassian account has no accessible Jira sites."
            case .notConnected: return "Jira isn't connected — run Connect in Settings → Jira."
            }
        }
    }

    // MARK: Credentials & state

    /// Client ID + secret: env → LastPass note (jiraClientID/jiraClientSecret,
    /// same fields the Python app reads) → stored (ID in defaults, secret in
    /// the Keychain blob).
    static func clientCredentials() -> (id: String, secret: String)? {
        let env = ProcessInfo.processInfo.environment
        if let id = env["JIRA_OAUTH_CLIENT_ID"], let secret = env["JIRA_OAUTH_CLIENT_SECRET"],
           !id.isEmpty, !secret.isEmpty {
            return (id, secret)
        }
        if AuthMode.current == .lastPass, let lastPass = LastPassConfig.load(),
           LastPass.isLoggedIn(),
           let id = LastPass.get(entry: lastPass.lookupRef, field: "jiraClientID"),
           let secret = LastPass.get(entry: lastPass.lookupRef, field: "jiraClientSecret"),
           !id.isEmpty, !secret.isEmpty {
            return (id, secret)
        }
        if let id = UserDefaults.standard.string(forKey: clientIDKey), !id.isEmpty,
           let secret = blob()?["client_secret"], !secret.isEmpty {
            return (id, secret)
        }
        return nil
    }

    /// Store manually-entered credentials (Settings → Jira). The secret rides
    /// in the Keychain blob alongside whatever refresh token exists.
    static func saveClientCredentials(id: String, secret: String) throws {
        UserDefaults.standard.set(id, forKey: clientIDKey)
        if !secret.isEmpty {
            var current = blob() ?? [:]
            current["client_secret"] = secret
            try writeBlob(current)
        }
    }

    static func storedClientID() -> String {
        UserDefaults.standard.string(forKey: clientIDKey) ?? ""
    }

    static var isConnected: Bool {
        blob()?["refresh_token"]?.isEmpty == false && cloudID() != nil
    }

    static func cloudID() -> String? {
        let id = UserDefaults.standard.string(forKey: cloudIDKey)
        return id?.isEmpty == false ? id : nil
    }

    /// The org's Jira site ("https://yourorg.atlassian.net") for browse links.
    static func siteURL() -> String? {
        let url = UserDefaults.standard.string(forKey: siteURLKey)
        return url?.isEmpty == false ? url : nil
    }

    static func disconnect() {
        Keychain.delete(service: blobService)
        UserDefaults.standard.removeObject(forKey: cloudIDKey)
        UserDefaults.standard.removeObject(forKey: siteURLKey)
        lock.lock(); cachedToken = nil; lock.unlock()
    }

    private static func blob() -> [String: String]? {
        guard let raw = Keychain.read(service: blobService),
              let data = raw.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return dict
    }

    private static func writeBlob(_ dict: [String: String]) throws {
        let data = try JSONEncoder().encode(dict)
        try Keychain.write(service: blobService, value: String(decoding: data, as: UTF8.self))
    }

    // MARK: Connect flow

    /// Run the full browser consent flow. `preferredHost` (e.g.
    /// "yourorg.atlassian.net") picks the matching site when the account can
    /// reach several. Returns the connected site URL.
    static func connect(preferredHost: String) async throws -> String {
        guard let creds = clientCredentials() else { throw OAuthError.noCredentials }
        let state = randomToken()

        var authorize = URLComponents(string: "https://auth.atlassian.com/authorize")!
        authorize.queryItems = [
            URLQueryItem(name: "audience", value: "api.atlassian.com"),
            URLQueryItem(name: "client_id", value: creds.id),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let callback = try await OAuthCallbackServer.waitForCallback(
            port: callbackPort, openURL: authorize.url!, timeout: 240)

        guard callback.queryValue("state") == state else { throw OAuthError.stateMismatch }
        guard let code = callback.queryValue("code"), !code.isEmpty else {
            throw OAuthError.noCode(callback.queryValue("error_description")
                                    ?? callback.queryValue("error") ?? "")
        }

        // Exchange the code (JSON body — Atlassian, unlike Datadog, wants JSON).
        let exchanged = try await tokenRequest([
            "grant_type": "authorization_code",
            "client_id": creds.id,
            "client_secret": creds.secret,
            "code": code,
            "redirect_uri": redirectURI,
        ])
        guard let refresh = exchanged.refreshToken, !refresh.isEmpty else {
            throw OAuthError.noRefreshToken
        }

        // Which Jira site does this token reach? Prefer the configured host.
        let resources = try await accessibleResources(accessToken: exchanged.accessToken)
        guard !resources.isEmpty else { throw OAuthError.noSite }
        let preferred = preferredHost.lowercased()
        let site = resources.first { preferred.isEmpty ? false : $0.url.lowercased().contains(preferred) }
            ?? resources[0]

        try writeBlob(["client_secret": creds.secret, "refresh_token": refresh])
        UserDefaults.standard.set(creds.id, forKey: clientIDKey)
        UserDefaults.standard.set(site.id, forKey: cloudIDKey)
        UserDefaults.standard.set(site.url, forKey: siteURLKey)
        lock.lock()
        cachedToken = (exchanged.accessToken, Date().addingTimeInterval(exchanged.expiresIn - 60))
        lock.unlock()
        return site.url
    }

    // MARK: Access tokens (cached ~1h, refresh rotates)

    private static let lock = NSLock()
    private static var cachedToken: (token: String, expiresAt: Date)?

    static func accessToken() async throws -> String {
        lock.lock()
        if let cached = cachedToken, cached.expiresAt > Date() {
            lock.unlock()
            return cached.token
        }
        lock.unlock()

        guard let creds = clientCredentials(),
              let refresh = blob()?["refresh_token"], !refresh.isEmpty else {
            throw OAuthError.notConnected
        }
        let refreshed = try await tokenRequest([
            "grant_type": "refresh_token",
            "client_id": creds.id,
            "client_secret": creds.secret,
            "refresh_token": refresh,
        ])
        // Atlassian rotates refresh tokens: persist the new one or the next
        // refresh fails.
        if let rotated = refreshed.refreshToken, !rotated.isEmpty, rotated != refresh {
            try? writeBlob(["client_secret": creds.secret, "refresh_token": rotated])
        }
        lock.lock()
        cachedToken = (refreshed.accessToken, Date().addingTimeInterval(refreshed.expiresIn - 60))
        lock.unlock()
        return refreshed.accessToken
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
    }

    private static func tokenRequest(_ body: [String: String]) async throws
        -> (accessToken: String, refreshToken: String?, expiresIn: TimeInterval) {
        var request = URLRequest(url: URL(string: "https://auth.atlassian.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw OAuthError.tokenExchange(
                "HTTP \(code) \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return (decoded.access_token, decoded.refresh_token, decoded.expires_in ?? 3600)
    }

    private struct Resource: Decodable {
        let id: String
        let url: String
    }

    private static func accessibleResources(accessToken: String) async throws -> [Resource] {
        var request = URLRequest(
            url: URL(string: "https://api.atlassian.com/oauth/token/accessible-resources")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONDecoder().decode([Resource].self, from: data)) ?? []
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One-shot local HTTP server for the OAuth redirect: accepts a single
/// connection on 127.0.0.1:<port>, parses the request line's path+query,
/// replies with a friendly "close this tab" page, and shuts down.
enum OAuthCallbackServer {
    struct Callback {
        let components: URLComponents?
        func queryValue(_ name: String) -> String? {
            components?.queryItems?.first { $0.name == name }?.value
        }
    }

    static func waitForCallback(port: UInt16, openURL: URL, timeout: TimeInterval)
        async throws -> Callback {
        let listener = try NWListener(
            using: .tcp, on: NWEndpoint.Port(rawValue: port)!)

        return try await withCheckedThrowingContinuation { continuation in
            let finished = ProtectedFlag()

            func finish(_ result: Result<Callback, Error>) {
                guard finished.trySet() else { return }
                listener.cancel()
                continuation.resume(with: result)
            }

            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
                    data, _, _, _ in
                    let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    // "GET /callback?code=...&state=... HTTP/1.1"
                    let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let body = "<html><body style='font-family:-apple-system;background:#111;"
                        + "color:#eee;text-align:center;padding-top:20vh'>"
                        + "<h2>🐶 Connected — you can close this tab.</h2></body></html>"
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
                        + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    finish(.success(Callback(
                        components: URLComponents(string: "http://localhost\(target)"))))
                }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { finish(.failure(error)) }
            }
            listener.start(queue: .global())

            DispatchQueue.main.async { LinkOpener.open(openURL) }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(JiraOAuth.OAuthError.timedOut))
            }
        }
    }

    /// Tiny thread-safe once-flag so the continuation resumes exactly once.
    private final class ProtectedFlag {
        private let lock = NSLock()
        private var isSet = false
        func trySet() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if isSet { return false }
            isSet = true
            return true
        }
    }
}
