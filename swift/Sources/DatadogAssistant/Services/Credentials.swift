import Foundation
import Security

/// Where the app reads Datadog credentials from. An explicit, persisted choice
/// so opening the app never silently falls back to (and prompts for) the
/// Keychain when the user meant to use the shared LastPass vault.
enum AuthMode: String {
    case sample                 // no credentials — run on sample data
    case keychain               // keys stored in the macOS Keychain
    case lastPass = "lastpass"  // fetched from the shared LastPass vault at runtime

    private static let defaultsKey = "authMode"

    /// The chosen mode. When the user hasn't chosen yet, infer a sensible one
    /// from what's configured (LastPass entry → lastPass, else keychain) so
    /// existing installs keep working without a migration step.
    static var current: AuthMode {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let mode = AuthMode(rawValue: raw) {
            return mode
        }
        return LastPassConfig.load() != nil ? .lastPass : .keychain
    }

    static func set(_ mode: AuthMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }

    /// True until the user (or a migration) has picked a mode explicitly —
    /// the signal that first-run onboarding should appear.
    static var currentIsUnset: Bool {
        UserDefaults.standard.string(forKey: defaultsKey) == nil
    }
}

/// Datadog API credentials. Stored in the macOS Keychain under the same
/// service names the Python app uses, so an existing install carries over.
///
/// Two credential shapes are supported since Datadog's June 2026 auth
/// modernization: the classic API + Application key pair, and a single
/// scoped access token (personal `ddpat_…` or service-account `ddsat_…`)
/// sent as `Authorization: Bearer`. When `accessToken` is non-empty it wins
/// and the key pair is ignored.
struct Credentials: Equatable {
    var apiKey: String
    var appKey: String
    var site: String   // e.g. "datadoghq.com", "datadoghq.eu", "us3.datadoghq.com"
    /// Datadog access token (ddpat_/ddsat_). Empty → use the key pair.
    var accessToken: String = ""
    /// Org subdomain for browser links ("yourorg" → yourorg.datadoghq.com).
    /// Orgs with a custom subdomain get re-asked to log in when links open
    /// under the generic app.* host — same fix as the Python app's
    /// app_subdomain config.
    var subdomain: String = "app"

    static let knownSites = [
        "datadoghq.com", "datadoghq.eu", "us3.datadoghq.com",
        "us5.datadoghq.com", "ap1.datadoghq.com", "ddog-gov.com",
    ]

    var apiBaseURL: URL { URL(string: "https://api.\(site)")! }
    var appBaseURL: URL {
        let sub = subdomain.trimmingCharacters(in: .whitespaces)
        return URL(string: "https://\(sub.isEmpty ? "app" : sub).\(site)")!
    }

    /// Apply this credential's auth headers — the one place that knows both
    /// shapes. Access tokens use the Bearer scheme Datadog recommends; the
    /// key pair keeps the classic headers.
    func authorize(_ request: inout URLRequest) {
        if accessToken.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "DD-API-KEY")
            request.setValue(appKey, forHTTPHeaderField: "DD-APPLICATION-KEY")
        } else {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    // Same service names install.sh writes, so existing users need no re-entry.
    private static let apiService = "datadog-assistant-api-key"
    private static let appService = "datadog-assistant-app-key"
    private static let tokenService = "datadog-assistant-access-token"
    private static let siteDefaultsKey = "datadogSite"
    private static let subdomainDefaultsKey = "datadogSubdomain"

    private static func storedSite() -> String {
        UserDefaults.standard.string(forKey: siteDefaultsKey) ?? "datadoghq.com"
    }

    private static func storedSubdomain() -> String {
        let env = ProcessInfo.processInfo.environment
        return env["DD_APP_SUBDOMAIN"]
            ?? UserDefaults.standard.string(forKey: subdomainDefaultsKey) ?? "app"
    }

    /// The persisted Datadog site (shared across auth modes and with the
    /// Python app's config). Exposed so the LastPass setup sheet can pick and
    /// persist a site while testing keys.
    static func currentSite() -> String { storedSite() }
    static func setSite(_ site: String) {
        UserDefaults.standard.set(site, forKey: siteDefaultsKey)
    }

    /// The persisted org subdomain for browser links ("app" default).
    static func currentSubdomain() -> String { storedSubdomain() }
    static func setSubdomain(_ subdomain: String) {
        let trimmed = subdomain.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed.isEmpty ? "app" : trimmed,
                                  forKey: subdomainDefaultsKey)
    }

    /// Where browser links should point with the current config — usable even
    /// without credentials (e.g. the Tools tab's "Open Datadog").
    static func currentAppBaseURL() -> URL {
        URL(string: "https://\(storedSubdomain()).\(storedSite())")!
    }

    /// Load credentials for the *selected* auth mode only — no silent
    /// cross-mode fallback. This is what stops the app from prompting for the
    /// Keychain when the user chose the LastPass vault: in `.lastPass` mode the
    /// Keychain is never touched. Environment variables always win for the dev
    /// loop, regardless of mode.
    static func load() -> Credentials? {
        let env = ProcessInfo.processInfo.environment
        // DD_BEARER_TOKEN is the name the Datadog ecosystem settled on
        // (API clients, Terraform); DD_ACCESS_TOKEN accepted as an alias.
        if let token = env["DD_BEARER_TOKEN"] ?? env["DD_ACCESS_TOKEN"], !token.isEmpty {
            return Credentials(apiKey: "", appKey: "",
                               site: env["DD_SITE"] ?? storedSite(),
                               accessToken: token,
                               subdomain: storedSubdomain())
        }
        if let api = env["DD_API_KEY"], let app = env["DD_APP_KEY"], !api.isEmpty, !app.isEmpty {
            return Credentials(apiKey: api, appKey: app,
                               site: env["DD_SITE"] ?? "datadoghq.com",
                               subdomain: storedSubdomain())
        }
        switch AuthMode.current {
        case .sample:
            return nil
        case .lastPass:
            // Shared-vault mode: pull the team's keys from LastPass at runtime.
            // If the vault is locked or unreadable we return nil (→ sample data)
            // rather than falling back to possibly-stale Keychain keys.
            guard let lastPass = LastPassConfig.load(), LastPass.isLoggedIn()
            else { return nil }
            // An access-token field, when configured on the note, replaces
            // the key pair (one scoped credential for the whole team).
            if let token = lastPass.datadogAccessToken() {
                return Credentials(apiKey: "", appKey: "",
                                   site: lastPass.site() ?? storedSite(),
                                   accessToken: token,
                                   subdomain: storedSubdomain())
            }
            guard let keys = lastPass.datadogKeys() else { return nil }
            return Credentials(apiKey: keys.api, appKey: keys.app,
                               site: lastPass.site() ?? storedSite(),
                               subdomain: storedSubdomain())
        case .keychain:
            // Password-manager commands win when configured (lpass/op/bw/
            // vault — stdout is the secret), then the Keychain. A stored
            // access token takes precedence over a stored key pair (saving
            // one clears the other, so both existing means something odd).
            let cmdToken = SecretCommand.run(UserDefaults.standard.string(forKey: "accessTokenCmd") ?? "")
            if let token = cmdToken ?? Keychain.read(service: tokenService) {
                return Credentials(apiKey: "", appKey: "", site: storedSite(),
                                   accessToken: token,
                                   subdomain: storedSubdomain())
            }
            let cmdAPI = SecretCommand.run(UserDefaults.standard.string(forKey: "apiKeyCmd") ?? "")
            let cmdApp = SecretCommand.run(UserDefaults.standard.string(forKey: "appKeyCmd") ?? "")
            let api = cmdAPI ?? Keychain.read(service: apiService)
            let app = cmdApp ?? Keychain.read(service: appService)
            guard let api, let app else { return nil }
            return Credentials(apiKey: api, appKey: app, site: storedSite(),
                               subdomain: storedSubdomain())
        }
    }

    /// Persist the key pair — and drop any stored access token, so the two
    /// credential shapes never shadow each other.
    func save() throws {
        try Keychain.write(service: Self.apiService, value: apiKey)
        try Keychain.write(service: Self.appService, value: appKey)
        Keychain.delete(service: Self.tokenService)
        UserDefaults.standard.set(site, forKey: Self.siteDefaultsKey)
        AuthMode.set(.keychain)
    }

    /// Persist an access token (ddpat_/ddsat_) — and drop any stored key
    /// pair, same reasoning as save().
    static func saveAccessToken(_ token: String, site: String) throws {
        try Keychain.write(service: tokenService, value: token)
        Keychain.delete(service: apiService)
        Keychain.delete(service: appService)
        UserDefaults.standard.set(site, forKey: siteDefaultsKey)
        AuthMode.set(.keychain)
    }

    /// Is an access token (rather than a key pair) stored in the Keychain?
    static func hasStoredAccessToken() -> Bool {
        Keychain.read(service: tokenService) != nil
    }

    static func clear() {
        Keychain.delete(service: apiService)
        Keychain.delete(service: appService)
        Keychain.delete(service: tokenService)
        UserDefaults.standard.removeObject(forKey: siteDefaultsKey)
        if AuthMode.current == .keychain { AuthMode.set(.sample) }
    }
}

/// Pull a secret from any password-manager CLI (lpass, op, bw, vault…) — the
/// command's stdout is the secret. Companies centralize rotation this way
/// instead of provisioning keys onto every machine. Successful lookups cache
/// for 15 minutes so the vault isn't hit on every poll; failures don't cache
/// and retry next time.
enum SecretCommand {
    private static let lock = NSLock()
    private static var cache: [String: (value: String, at: Date)] = [:]
    private static let ttl: TimeInterval = 900

    static func run(_ command: String) -> String? {
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        lock.lock()
        if let hit = cache[command], Date().timeIntervalSince(hit.at) < ttl {
            lock.unlock()
            return hit.value
        }
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        lock.lock()
        cache[command] = (value, Date())
        lock.unlock()
        return value
    }
}

enum Keychain {
    enum Error: Swift.Error { case status(OSStatus) }

    static func read(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }

    static func write(service: String, value: String) throws {
        delete(service: service)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.status(status) }
    }

    static func delete(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
