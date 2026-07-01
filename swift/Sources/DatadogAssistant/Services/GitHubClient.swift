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
        let token = env["GITHUB_TOKEN"] ?? Keychain.read(service: tokenService)
        let specs = env["GITHUB_REPOS"].map { $0.split(separator: ",").map(String.init) }
            ?? UserDefaults.standard.stringArray(forKey: reposDefaultsKey)
        guard let token, !token.isEmpty, let specs, !specs.isEmpty else { return nil }
        let config = GitHubConfig(token: token, repoSpecs: specs)
        return config.repos.isEmpty ? nil : config
    }

    func save() throws {
        try Keychain.write(service: Self.tokenService, value: token)
        UserDefaults.standard.set(repoSpecs, forKey: Self.reposDefaultsKey)
    }

    static func clear() {
        Keychain.delete(service: tokenService)
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
