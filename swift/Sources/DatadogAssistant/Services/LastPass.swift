import Foundation

/// Shared-vault credential mode: fetch the team's Datadog (and optionally
/// GitHub) keys from a LastPass secure note at runtime via the `lpass` CLI,
/// instead of provisioning API keys onto every machine. This mirrors the
/// Python app's LastPass integration — same binary discovery, same login
/// check, same `--field`/`--notes` retrieval, and the same field-name
/// defaults (`datadogAPIKey` / `datadogAPPKey`) — so one secure note serves
/// both apps. Secrets live only in the vault; nothing is written to disk here.
enum LastPass {
    /// Absolute path to `lpass`, or nil if it isn't installed. Checks the
    /// Homebrew paths that a LaunchAgent's trimmed PATH would miss (cheap file
    /// checks) before falling back to a PATH lookup. Re-resolved on each call
    /// so a freshly `brew install`ed binary is picked up without a relaunch.
    static func locate() -> String? {
        for path in ["/opt/homebrew/bin/lpass", "/usr/local/bin/lpass"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return which("lpass")
    }

    /// Is the `lpass` CLI installed?
    static var isInstalled: Bool { locate() != nil }

    /// The resolved path, or the bare name (which fails gracefully in `run`).
    static var binaryPath: String { locate() ?? "lpass" }

    // MARK: Login status (cached briefly, like the Python app)

    private static let lock = NSLock()
    private static var loginOK = false
    private static var loginCheckedAt = Date.distantPast
    private static let loginTTL: TimeInterval = 60

    /// Is the user logged into the LastPass CLI? A positive result is cached
    /// for a minute so repeated credential loads don't spawn `lpass status`
    /// every time; a logged-out result is never cached, so a fresh
    /// `lpass login` is picked up on the next check.
    static func isLoggedIn() -> Bool {
        lock.lock()
        if loginOK, Date().timeIntervalSince(loginCheckedAt) < loginTTL {
            lock.unlock()
            return true
        }
        lock.unlock()
        return statusLoggedIn()
    }

    /// Run `lpass status` right now (bypassing the cache) and refresh the
    /// cached result. Use immediately after a login/logout, where the cached
    /// value would otherwise be stale.
    @discardableResult
    static func statusLoggedIn() -> Bool {
        let result = run(["status"], timeout: 10)
        let ok = result?.status == 0 && (result?.output.contains("Logged in") ?? false)
        lock.lock()
        loginOK = ok
        loginCheckedAt = Date()
        lock.unlock()
        return ok
    }

    // MARK: Secret retrieval (successful lookups cached with TTL)

    private static var secretCache: [String: (value: String, at: Date)] = [:]
    private static let secretTTL: TimeInterval = 300

    /// Retrieve one field from a LastPass entry. Tries `lpass show --field`
    /// first (works for custom fields), then falls back to parsing
    /// `key=value` lines out of the secure note body (`--notes`). Returns nil
    /// when the field is absent or the vault is locked; failures are not
    /// cached, so they retry on the next load.
    static func get(entry: String, field: String) -> String? {
        guard !entry.isEmpty, !field.isEmpty else { return nil }
        let cacheKey = "\(entry)\u{0}\(field)"

        lock.lock()
        if let hit = secretCache[cacheKey], Date().timeIntervalSince(hit.at) < secretTTL {
            lock.unlock()
            return hit.value
        }
        lock.unlock()

        var value = ""
        // Custom fields respond to --field directly.
        if let result = run(["show", "--field", field, entry], timeout: 30),
           result.status == 0 {
            value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Secure notes store key=value lines in the body instead.
        if value.isEmpty,
           let result = run(["show", "--notes", entry], timeout: 30),
           result.status == 0 {
            for line in result.output.split(separator: "\n", omittingEmptySubsequences: false) {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                if key == field {
                    value = String(line[line.index(after: eq)...])
                        .trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }

        guard !value.isEmpty else { return nil }
        lock.lock()
        secretCache[cacheKey] = (value, Date())
        lock.unlock()
        return value
    }

    // MARK: Subprocess plumbing

    /// Run `lpass` with the given arguments, bounding the wait so a hung agent
    /// can't block the caller. Reading to EOF drains the pipe (no buffer
    /// deadlock) and unblocks as soon as the process exits or is terminated.
    private static func run(_ args: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = args
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func which(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }
}

/// Configuration for shared-vault mode: which LastPass entry holds the secure
/// note, and the field names to read from it. Field defaults match the Python
/// app (`datadogAPIKey` / `datadogAPPKey`) so a single note works for both.
/// Only the entry name and field names are persisted (in UserDefaults) — never
/// the secrets themselves. Env vars win for the dev loop and for setups driven
/// by `install.sh` (`DD_LASTPASS_ENTRY` and friends).
struct LastPassConfig: Equatable {
    var entry: String
    var apiKeyField: String = "datadogAPIKey"
    var appKeyField: String = "datadogAPPKey"
    var gitHubTokenField: String = "githubToken"
    var siteField: String = ""   // optional — read the org's site from the note too

    private static let entryKey = "lastpassEntry"
    private static let apiFieldKey = "lastpassAPIKeyField"
    private static let appFieldKey = "lastpassAPPKeyField"
    private static let gitHubFieldKey = "lastpassGitHubTokenField"
    private static let siteFieldKey = "lastpassSiteField"

    static func load() -> LastPassConfig? {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        guard let entry = env["DD_LASTPASS_ENTRY"] ?? defaults.string(forKey: entryKey),
              !entry.isEmpty else { return nil }
        return LastPassConfig(
            entry: entry,
            apiKeyField: env["DD_LASTPASS_API_FIELD"]
                ?? defaults.string(forKey: apiFieldKey) ?? "datadogAPIKey",
            appKeyField: env["DD_LASTPASS_APP_FIELD"]
                ?? defaults.string(forKey: appFieldKey) ?? "datadogAPPKey",
            gitHubTokenField: env["DD_LASTPASS_GITHUB_FIELD"]
                ?? defaults.string(forKey: gitHubFieldKey) ?? "githubToken",
            siteField: env["DD_LASTPASS_SITE_FIELD"]
                ?? defaults.string(forKey: siteFieldKey) ?? "")
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(entry, forKey: Self.entryKey)
        defaults.set(apiKeyField, forKey: Self.apiFieldKey)
        defaults.set(appKeyField, forKey: Self.appFieldKey)
        defaults.set(gitHubTokenField, forKey: Self.gitHubFieldKey)
        defaults.set(siteField, forKey: Self.siteFieldKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        for key in [entryKey, apiFieldKey, appFieldKey, gitHubFieldKey, siteFieldKey] {
            defaults.removeObject(forKey: key)
        }
    }

    /// The Datadog API + Application keys from the vault, or nil unless both
    /// are present.
    func datadogKeys() -> (api: String, app: String)? {
        guard let api = LastPass.get(entry: entry, field: apiKeyField),
              let app = LastPass.get(entry: entry, field: appKeyField) else { return nil }
        return (api, app)
    }

    /// The GitHub token from the vault, if a field name is configured.
    func gitHubToken() -> String? {
        guard !gitHubTokenField.isEmpty else { return nil }
        return LastPass.get(entry: entry, field: gitHubTokenField)
    }

    /// The Datadog site from the vault, if a field name is configured.
    func site() -> String? {
        guard !siteField.isEmpty else { return nil }
        return LastPass.get(entry: entry, field: siteField)
    }
}
