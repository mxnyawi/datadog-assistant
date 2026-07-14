import Foundation

/// Where the app reads Datadog credentials from. An explicit, persisted choice
/// so opening the app never silently falls back to a source the user didn't
/// mean to use.
enum AuthMode: String {
    case sample                 // no credentials — run on sample data
    case device = "keychain"    // stored on this Mac (raw value kept for migration)
    case lastPass = "lastpass"  // fetched from the shared LastPass vault at runtime

    private static let defaultsKey = "authMode"

    /// The chosen mode. When the user hasn't chosen yet, infer a sensible one
    /// from what's configured (LastPass entry → lastPass, else device) so
    /// existing installs keep working without a migration step.
    static var current: AuthMode {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let mode = AuthMode(rawValue: raw) {
            return mode
        }
        return LastPassConfig.load() != nil ? .lastPass : .device
    }

    static func set(_ mode: AuthMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }

}

/// Datadog API credentials, stored securely on this Mac (see SecretStore) —
/// never the login Keychain, so opening the app doesn't prompt for a password.
///
/// Two credential shapes: a single scoped **access token** (personal
/// `ddpat_…` or service-account `ddsat_…`, Datadog's recommended credential
/// since 2026) sent as `Authorization: Bearer`, and the classic API +
/// Application key pair. The access token is the primary path; when it's set
/// the key pair is ignored.
struct Credentials: Equatable {
    var apiKey: String
    var appKey: String
    var site: String   // e.g. "datadoghq.com", "datadoghq.eu", "us3.datadoghq.com"
    /// Datadog access token (ddpat_/ddsat_). Empty → use the key pair.
    var accessToken: String = ""
    /// Org subdomain for browser links ("yourorg" → yourorg.datadoghq.com).
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

    // SecretStore keys (kept identical to the old Keychain service names).
    private static let apiKeyName = "datadog-assistant-api-key"
    private static let appKeyName = "datadog-assistant-app-key"
    private static let tokenName = "datadog-assistant-access-token"
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

    static func currentSite() -> String { storedSite() }
    static func setSite(_ site: String) {
        UserDefaults.standard.set(site, forKey: siteDefaultsKey)
    }

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
    /// cross-mode fallback. Environment variables always win for the dev loop.
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
            // Shared-vault mode: pull the team's credential from LastPass at
            // runtime. If the vault is locked/unreadable we return nil rather
            // than falling back to possibly-stale local secrets.
            guard let lastPass = LastPassConfig.load(), LastPass.isLoggedIn()
            else { return nil }
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
        case .device:
            // Password-manager commands win when configured (op/lpass/bw/
            // vault — stdout is the secret), then the on-device store. A token
            // takes precedence over a key pair (saving one clears the other).
            let cmdToken = SecretCommand.run(UserDefaults.standard.string(forKey: "accessTokenCmd") ?? "")
            if let token = cmdToken ?? SecretStore.read(tokenName) {
                return Credentials(apiKey: "", appKey: "", site: storedSite(),
                                   accessToken: token,
                                   subdomain: storedSubdomain())
            }
            let cmdAPI = SecretCommand.run(UserDefaults.standard.string(forKey: "apiKeyCmd") ?? "")
            let cmdApp = SecretCommand.run(UserDefaults.standard.string(forKey: "appKeyCmd") ?? "")
            let api = cmdAPI ?? SecretStore.read(apiKeyName)
            let app = cmdApp ?? SecretStore.read(appKeyName)
            guard let api, let app else { return nil }
            return Credentials(apiKey: api, appKey: app, site: storedSite(),
                               subdomain: storedSubdomain())
        }
    }

    /// Persist the key pair — and drop any stored access token, so the two
    /// credential shapes never shadow each other.
    func save() throws {
        try SecretStore.write(Self.apiKeyName, apiKey)
        try SecretStore.write(Self.appKeyName, appKey)
        SecretStore.delete(Self.tokenName)
        UserDefaults.standard.set(site, forKey: Self.siteDefaultsKey)
        AuthMode.set(.device)
    }

    /// Persist an access token (ddpat_/ddsat_) — and drop any stored key pair.
    static func saveAccessToken(_ token: String, site: String) throws {
        try SecretStore.write(tokenName, token)
        SecretStore.delete(apiKeyName)
        SecretStore.delete(appKeyName)
        UserDefaults.standard.set(site, forKey: siteDefaultsKey)
        AuthMode.set(.device)
    }

    /// Is an access token (rather than a key pair) stored on this Mac?
    static func hasStoredAccessToken() -> Bool {
        SecretStore.read(tokenName) != nil
    }

    /// Is a full API + Application key pair stored on this Mac?
    static func hasStoredKeyPair() -> Bool {
        SecretStore.read(apiKeyName) != nil && SecretStore.read(appKeyName) != nil
    }

    static func clear() {
        SecretStore.delete(apiKeyName)
        SecretStore.delete(appKeyName)
        SecretStore.delete(tokenName)
        UserDefaults.standard.removeObject(forKey: siteDefaultsKey)
        if AuthMode.current == .device { AuthMode.set(.sample) }
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
