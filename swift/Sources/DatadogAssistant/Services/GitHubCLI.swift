import Foundation

/// Bridge to the locally-authenticated GitHub CLI — the same trick as the
/// lpass integration: if the user is already logged into `gh` on this Mac,
/// the app borrows its token (`gh auth token`) instead of making them mint
/// and paste a fine-grained PAT. Also powers repo suggestions in Settings
/// via `gh repo list`.
enum GitHubCLI {
    /// Locate `gh`, checking the Homebrew paths a LaunchAgent's PATH misses.
    static func locate() -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // PATH lookup for setups that install gh elsewhere.
        let result = run(binary: "/usr/bin/env", args: ["which", "gh"], timeout: 5)
        let path = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (result?.status == 0 && !path.isEmpty) ? path : nil
    }

    static var isInstalled: Bool { locate() != nil }

    // Token cached briefly so credential loads don't spawn a subprocess on
    // every poll; failures aren't cached so a fresh `gh auth login` is picked
    // up immediately.
    private static let lock = NSLock()
    private static var cachedToken: (value: String, at: Date)?
    private static let tokenTTL: TimeInterval = 900

    /// The CLI's OAuth token, or nil when gh is missing or logged out.
    static func authToken() -> String? {
        lock.lock()
        if let cached = cachedToken, Date().timeIntervalSince(cached.at) < tokenTTL {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        guard let gh = locate(),
              let result = run(binary: gh, args: ["auth", "token"], timeout: 10),
              result.status == 0 else { return nil }
        let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        lock.lock()
        cachedToken = (token, Date())
        lock.unlock()
        return token
    }

    /// Repos ("owner/name") for `owner`, most recently pushed first — used to
    /// suggest watch candidates in Settings. With an empty owner it lists the
    /// signed-in user's own repos (`gh repo list`); pass an org/user login to
    /// list *their* repos (`gh repo list <owner>`), which is how members see
    /// the org repos they don't personally own. Best-effort; empty on failure.
    static func listRepos(owner: String = "", limit: Int = 100) -> [String] {
        guard let gh = locate() else { return [] }
        var args = ["repo", "list"]
        let trimmed = owner.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { args.append(trimmed) }
        args += ["--limit", String(limit), "--json", "nameWithOwner"]
        guard let result = run(binary: gh, args: args, timeout: 25),
              result.status == 0,
              let data = result.output.data(using: .utf8) else { return [] }
        struct Repo: Decodable { let nameWithOwner: String }
        return ((try? JSONDecoder().decode([Repo].self, from: data)) ?? [])
            .map(\.nameWithOwner)
    }

    /// Organizations the signed-in user belongs to (their logins). Uses the API
    /// so it works regardless of `gh` version; needs the token's read:org scope
    /// (which `gh auth login` grants by default). Empty on failure — the user
    /// can still type an org name manually.
    static func listOrgs(limit: Int = 100) -> [String] {
        guard let gh = locate(),
              let result = run(binary: gh,
                               args: ["api", "user/orgs", "--paginate", "--jq", ".[].login"],
                               timeout: 20),
              result.status == 0 else { return [] }
        return result.output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func run(binary: String, args: [String], timeout: TimeInterval)
        -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
