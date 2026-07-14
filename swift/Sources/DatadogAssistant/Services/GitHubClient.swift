import Foundation

/// GitHub configuration: a token and repos to watch for merges. Repos map to
/// services ("payments=acme/payments-api") so a merge can be tied to the
/// firing monitor's service; a bare "acme/platform" entry watches org-wide.
struct GitHubConfig: Equatable {
    var token: String
    /// e.g. ["payments=acme/payments-api", "acme/platform"]
    var repoSpecs: [String]

    private static let tokenService = "datadog-assistant-github-token"
    private static let reposDefaultsKey = "githubRepos"

    struct Repo: Equatable {
        let fullName: String   // "owner/name"
        let service: String?
    }

    var repos: [Repo] {
        repoSpecs.compactMap { spec in
            let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
            switch parts.count {
            case 1 where parts[0].contains("/"):
                return Repo(fullName: parts[0], service: nil)
            case 2 where parts[1].contains("/"):
                return Repo(fullName: parts[1], service: parts[0])
            default:
                return nil
            }
        }
    }

    static func load() -> GitHubConfig? {
        let env = ProcessInfo.processInfo.environment
        // Repos aren't secret, so they come from env/UserDefaults regardless of
        // credential mode; without any there's nothing to watch.
        let specs = env["GITHUB_REPOS"].map { $0.split(separator: ",").map(String.init) }
            ?? UserDefaults.standard.stringArray(forKey: reposDefaultsKey)
        guard let specs, !specs.isEmpty else { return nil }
        // Env wins (dev loop), then the shared LastPass vault, then a stored
        // token, then the locally-authenticated gh CLI — so a machine that's
        // already logged into `gh` needs zero token setup.
        var token = env["GITHUB_TOKEN"]
        if token?.isEmpty ?? true, let lastPass = LastPassConfig.load(), LastPass.isLoggedIn() {
            token = lastPass.gitHubToken()
        }
        if token?.isEmpty ?? true { token = SecretStore.read(tokenService) }
        if token?.isEmpty ?? true { token = GitHubCLI.authToken() }
        guard let token, !token.isEmpty else { return nil }
        let config = GitHubConfig(token: token, repoSpecs: specs)
        return config.repos.isEmpty ? nil : config
    }

    func save() throws {
        try SecretStore.write(Self.tokenService, token)
        UserDefaults.standard.set(repoSpecs, forKey: Self.reposDefaultsKey)
    }

    /// Persist just the repo list — LastPass mode, where the token resolves
    /// from the shared vault at load time instead of the on-device store.
    static func saveRepoSpecsOnly(_ specs: [String]) {
        UserDefaults.standard.set(specs, forKey: reposDefaultsKey)
    }

    static func clear() {
        SecretStore.delete(tokenService)
        UserDefaults.standard.removeObject(forKey: reposDefaultsKey)
    }
}

/// Minimal GitHub REST client: recently merged PRs per watched repo, mapped
/// into DeployEvents so the store can correlate them with alert start times.
/// Everything is best-effort — a bad token degrades to an empty feed, never
/// an error banner.
final class GitHubClient {
    private let config: GitHubConfig
    private let session: URLSession

    init(config: GitHubConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: cfg)
    }

    private struct PullDTO: Decodable {
        struct User: Decodable { let login: String? }
        let number: Int
        let title: String?
        let merged_at: String?
        let html_url: String?
        let user: User?
    }

    func recentMerges(within window: TimeInterval) async -> [DeployEvent] {
        let cutoff = Date().addingTimeInterval(-window)
        var all: [DeployEvent] = []
        await withTaskGroup(of: [DeployEvent].self) { group in
            for repo in config.repos {
                group.addTask { [self] in
                    await merges(in: repo, since: cutoff)
                }
            }
            for await events in group { all.append(contentsOf: events) }
        }
        return all.sorted { $0.occurredAt > $1.occurredAt }
    }

    // MARK: - Actions runs

    private struct RunsDTO: Decodable {
        struct Run: Decodable {
            let id: Int
            let name: String?
            let status: String?        // queued | in_progress | completed
            let conclusion: String?    // success | failure | cancelled | …
            let head_branch: String?
            let html_url: String?
            let run_started_at: String?
        }
        let workflow_runs: [Run]?
    }

    /// Latest run per workflow per watched repo (runs come newest-first, so
    /// the first run seen per workflow name wins). Failures sort first.
    func latestRuns(maxPerRepo: Int = 3) async -> [CIRun] {
        var all: [CIRun] = []
        await withTaskGroup(of: [CIRun].self) { group in
            for repo in config.repos {
                group.addTask { [self] in
                    await runs(in: repo, limit: maxPerRepo)
                }
            }
            for await runs in group { all.append(contentsOf: runs) }
        }
        return all.sorted { lhs, rhs in
            if (lhs.state == .failure) != (rhs.state == .failure) {
                return lhs.state == .failure
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    private func runs(in repo: GitHubConfig.Repo, limit: Int) async -> [CIRun] {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(repo.fullName)/actions/runs?per_page=15")!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(RunsDTO.self, from: data),
              let runs = decoded.workflow_runs else { return [] }

        let iso = ISO8601DateFormatter()
        var seenWorkflows = Set<String>()
        var out: [CIRun] = []
        for run in runs {
            let workflow = run.name ?? "workflow"
            guard !seenWorkflows.contains(workflow) else { continue }
            seenWorkflows.insert(workflow)

            let state: CIRun.State
            switch (run.status, run.conclusion) {
            case (_, "success"):                       state = .success
            case (_, "failure"), (_, "timed_out"):     state = .failure
            case ("in_progress", _), ("queued", _):    state = .running
            default:                                   state = .other
            }
            out.append(CIRun(
                id: "run-\(repo.fullName)-\(run.id)",
                repo: repo.fullName,
                workflow: workflow,
                state: state,
                branch: run.head_branch,
                startedAt: run.run_started_at.flatMap(iso.date(from:)) ?? Date(),
                url: run.html_url.flatMap(URL.init(string:))
            ))
            if out.count >= limit { break }
        }
        return out
    }

    private func merges(in repo: GitHubConfig.Repo, since cutoff: Date) async -> [DeployEvent] {
        var request = URLRequest(url: URL(string:
            "https://api.github.com/repos/\(repo.fullName)/pulls?state=closed&sort=updated&direction=desc&per_page=20")!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let pulls = try? JSONDecoder().decode([PullDTO].self, from: data)
        else { return [] }

        let iso = ISO8601DateFormatter()
        return pulls.compactMap { pull in
            guard let mergedRaw = pull.merged_at,
                  let merged = iso.date(from: mergedRaw),
                  merged > cutoff else { return nil }
            return DeployEvent(
                id: "gh-\(repo.fullName)-\(pull.number)",
                title: "PR #\(pull.number) · \(pull.title ?? "untitled")",
                source: .github,
                occurredAt: merged,
                url: pull.html_url.flatMap(URL.init(string:)),
                service: repo.service
            )
        }
    }
}
