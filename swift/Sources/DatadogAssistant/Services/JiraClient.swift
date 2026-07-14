import Foundation

/// Jira configuration for ticket creation from alerts. Two auth modes,
/// mirroring the Python app:
/// - **oauth** (default): client ID + secret — from the shared LastPass
///   note's `jiraClientID`/`jiraClientSecret` fields, or entered manually —
///   with browser consent (see JiraOAuth). Requests go Bearer against
///   api.atlassian.com/ex/jira/<cloudID>.
/// - **token**: legacy email + API token Basic auth against the site host.
/// Non-secret fields persist in UserDefaults; secrets on-device/LastPass.
struct JiraConfig: Equatable {
    enum Auth: String { case oauth, token }

    var auth: Auth = .oauth
    /// Site host for browse links and OAuth site matching,
    /// e.g. "yourorg.atlassian.net". In OAuth mode this may be filled from
    /// accessible-resources at connect time.
    var baseURL: String
    var email: String = ""
    var projectKey: String
    var issueType: String = "Task"
    /// LastPass note field holding the API token (token mode only).
    var lastPassTokenField: String = "jiraToken"
    /// Auto-create tickets when a monitor fires: 0 = off, 1 = P1 only,
    /// 2 = P1+P2.
    var autoCreatePriority: Int = 0

    static let issueTypes = ["Task", "Bug", "Incident", "Story"]

    private static let authKey = "jiraAuthMode"
    private static let baseURLKey = "jiraBaseURL"
    private static let emailKey = "jiraEmail"
    private static let projectKey_ = "jiraProjectKey"
    private static let issueTypeKey = "jiraIssueType"
    private static let lastPassFieldKey = "jiraLastPassTokenField"
    private static let autoCreateKey = "jiraAutoCreatePriority"
    private static let tokenService = "datadog-assistant-jira-token"

    /// Loaded config, or nil until it's actually usable for ticket creation:
    /// a project key plus either a connected OAuth session or token-mode
    /// coordinates.
    static func load() -> JiraConfig? {
        let stored = loadStored()
        guard !stored.projectKey.isEmpty else { return nil }
        switch stored.auth {
        case .oauth:
            return JiraOAuth.isConnected ? stored : nil
        case .token:
            return (!stored.baseURL.isEmpty && !stored.email.isEmpty) ? stored : nil
        }
    }

    /// The persisted fields regardless of connection state — what Settings
    /// edits.
    static func loadStored() -> JiraConfig {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        var config = JiraConfig(
            baseURL: env["JIRA_BASE_URL"] ?? defaults.string(forKey: baseURLKey) ?? "",
            projectKey: defaults.string(forKey: projectKey_) ?? "")
        config.auth = Auth(rawValue: defaults.string(forKey: authKey) ?? "oauth") ?? .oauth
        config.email = env["JIRA_EMAIL"] ?? defaults.string(forKey: emailKey) ?? ""
        config.issueType = defaults.string(forKey: issueTypeKey) ?? "Task"
        config.lastPassTokenField = defaults.string(forKey: lastPassFieldKey) ?? "jiraToken"
        config.autoCreatePriority = defaults.integer(forKey: autoCreateKey)
        return config
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(auth.rawValue, forKey: Self.authKey)
        defaults.set(baseURL, forKey: Self.baseURLKey)
        defaults.set(email, forKey: Self.emailKey)
        defaults.set(projectKey, forKey: Self.projectKey_)
        defaults.set(issueType, forKey: Self.issueTypeKey)
        defaults.set(lastPassTokenField, forKey: Self.lastPassFieldKey)
        defaults.set(autoCreatePriority, forKey: Self.autoCreateKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        for key in [authKey, baseURLKey, emailKey, projectKey_, issueTypeKey,
                    lastPassFieldKey, autoCreateKey] {
            defaults.removeObject(forKey: key)
        }
        SecretStore.delete(tokenService)
        JiraOAuth.disconnect()
    }

    static func saveToken(_ token: String) throws {
        try SecretStore.write(tokenService, token)
    }

    /// Token-mode secret: env → LastPass vault → on-device store.
    func resolveToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let token = env["JIRA_API_TOKEN"], !token.isEmpty { return token }
        if AuthMode.current == .lastPass, !lastPassTokenField.isEmpty,
           let lastPass = LastPassConfig.load(), LastPass.isLoggedIn(),
           let token = LastPass.get(entry: lastPass.lookupRef, field: lastPassTokenField) {
            return token
        }
        return SecretStore.read(Self.tokenService)
    }

    /// The site host used for browse links.
    var browseHost: String {
        let stored = baseURL
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !stored.isEmpty { return stored }
        if let site = JiraOAuth.siteURL() {
            return site.replacingOccurrences(of: "https://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        return ""
    }
}

/// Which ticket belongs to which monitor, persisted across launches. This is
/// the local dedupe: an alert that already has a ticket shows "Open PROJ-123"
/// instead of minting duplicates. (createIssue additionally checks Jira
/// itself via JQL, so tickets created elsewhere are respected too.)
enum JiraTicketStore {
    private static let key = "jiraTicketsByMonitor"

    static func ticket(for monitorID: Int) -> (key: String, url: URL)? {
        guard let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String],
              let raw = map[String(monitorID)] else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let url = URL(string: parts[1]) else { return nil }
        return (parts[0], url)
    }

    static func record(ticketKey: String, url: URL, for monitorID: Int) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map[String(monitorID)] = "\(ticketKey)|\(url.absoluteString)"
        UserDefaults.standard.set(map, forKey: key)
    }

    static func forget(monitorID: Int) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        map.removeValue(forKey: String(monitorID))
        UserDefaults.standard.set(map, forKey: key)
    }
}

/// Auto-create tickets for high-priority alerts (P1/P2), with dedupe. Runs on
/// fired transitions; the created ticket is announced with a notification
/// that opens it on tap.
@MainActor
enum JiraAutoCreate {
    static func handle(_ transitions: [SnapshotStore.Transition]) {
        guard let config = JiraConfig.load(), config.autoCreatePriority > 0 else { return }
        for transition in transitions where transition.kind == .fired {
            let monitor = transition.monitor
            guard monitor.priority.rawValue <= config.autoCreatePriority,
                  JiraTicketStore.ticket(for: monitor.id) == nil else { continue }
            Task {
                guard let result = try? await JiraClient.createIssue(for: monitor, config: config)
                else { return }
                NotificationManager.shared.notifyTicketCreated(
                    ticketKey: result.key, monitorName: monitor.name, url: result.url)
            }
        }
    }
}

/// Jira Cloud REST client (v3): create issues for firing monitors, find
/// existing ones by label, and test the connection.
enum JiraClient {
    enum JiraError: LocalizedError {
        case noToken
        case notConnected
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noToken:
                return "No Jira API token — add one in Settings → Jira (or the LastPass note)."
            case .notConnected:
                return "Jira isn't connected — run Connect in Settings → Jira."
            case .http(let code, let detail):
                return "Jira returned HTTP \(code)\(detail.isEmpty ? "" : " — \(detail)")"
            }
        }
    }

    /// Every monitor's ticket carries this label, which is what the JQL
    /// dedupe searches for.
    static func monitorLabel(_ monitorID: Int) -> String { "dd-monitor-\(monitorID)" }

    // MARK: Requests (auth-mode aware)

    /// REST base: OAuth goes through the api.atlassian.com gateway; token
    /// mode hits the site host directly.
    private static func restBase(_ config: JiraConfig) throws -> URL {
        switch config.auth {
        case .oauth:
            guard let cloudID = JiraOAuth.cloudID() else { throw JiraError.notConnected }
            return URL(string: "https://api.atlassian.com/ex/jira/\(cloudID)")!
        case .token:
            let host = config.browseHost
            guard !host.isEmpty, let url = URL(string: "https://\(host)") else {
                throw JiraError.http(0, "invalid Jira site “\(host)” — use yourorg.atlassian.net")
            }
            return url
        }
    }

    private static func authedRequest(_ config: JiraConfig, path: String,
                                      query: [URLQueryItem] = []) async throws -> URLRequest {
        var components = URLComponents(
            url: try restBase(config).appendingPathComponent(path),
            resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch config.auth {
        case .oauth:
            let token = try await JiraOAuth.accessToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .token:
            guard let token = config.resolveToken(), !token.isEmpty else {
                throw JiraError.noToken
            }
            let basic = Data("\(config.email):\(token)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw JiraError.http(code, String(data: data.prefix(200), encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: Create / find issues

    private struct CreateResponse: Decodable { let key: String }
    private struct SearchResponse: Decodable {
        struct Issue: Decodable { let key: String }
        let issues: [Issue]?
    }

    /// An already-open ticket for this monitor, found via the dd-monitor-<id>
    /// label — respects tickets created by teammates or a previous install.
    static func findOpenIssue(monitorID: Int, config: JiraConfig) async throws -> String? {
        let jql = "labels = \"\(monitorLabel(monitorID))\" AND statusCategory != Done"
        let request = try await authedRequest(
            config, path: "/rest/api/3/search/jql",
            query: [URLQueryItem(name: "jql", value: jql),
                    URLQueryItem(name: "fields", value: "key"),
                    URLQueryItem(name: "maxResults", value: "1")])
        let data = try await send(request)
        return try JSONDecoder().decode(SearchResponse.self, from: data).issues?.first?.key
    }

    /// Create a ticket for a monitor (or adopt an existing open one), record
    /// the monitor → ticket mapping, and return the key and browse URL.
    static func createIssue(for monitor: Monitor, config: JiraConfig) async throws
        -> (key: String, url: URL) {
        let host = config.browseHost

        // Server-side dedupe first (best-effort — a search failure shouldn't
        // block ticket creation). `try?` flattens the String?? to String?.
        if let existingKey = try? await findOpenIssue(monitorID: monitor.id, config: config) {
            let url = URL(string: "https://\(host)/browse/\(existingKey)")!
            JiraTicketStore.record(ticketKey: existingKey, url: url, for: monitor.id)
            return (existingKey, url)
        }

        var lines = ["State: \(monitor.state.label) (\(monitor.priority.label))"]
        if let duration = monitor.firingDuration { lines.append("Firing for: \(duration)") }
        if !monitor.triggeredHosts.isEmpty {
            lines.append("Groups: \(monitor.triggeredHosts.joined(separator: ", "))")
        }
        if let monitorURL = monitor.url { lines.append(monitorURL.absoluteString) }

        // Labels: configured base + one per monitor tag + the dedupe label.
        var labels = ["datadog-alert", monitorLabel(monitor.id)]
        for tag in monitor.tags {
            let label = jiraLabel("datadog-alert-\(tag)")
            if !labels.contains(label) { labels.append(label) }
        }

        var request = try await authedRequest(config, path: "/rest/api/3/issue")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fields": [
                "project": ["key": config.projectKey],
                "summary": String("[\(monitor.priority.label)] \(monitor.name)".prefix(254)),
                "description": adfDocument(paragraphs: lines),
                "issuetype": ["name": config.issueType],
                "labels": labels,
            ],
        ])
        let data = try await send(request)
        let created = try JSONDecoder().decode(CreateResponse.self, from: data)
        let browseURL = URL(string: "https://\(host)/browse/\(created.key)")!
        JiraTicketStore.record(ticketKey: created.key, url: browseURL, for: monitor.id)
        return (created.key, browseURL)
    }

    /// Atlassian Document Format body — v3 requires it.
    private static func adfDocument(paragraphs: [String]) -> [String: Any] {
        [
            "type": "doc",
            "version": 1,
            "content": paragraphs.map { text in
                ["type": "paragraph",
                 "content": [["type": "text", "text": text]]]
            },
        ]
    }

    /// Jira labels can't contain spaces; mirror the Python sanitizer
    /// (non-alphanumerics → "-").
    private static func jiraLabel(_ raw: String) -> String {
        String(raw.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    // MARK: Connection test

    private struct Myself: Decodable {
        let displayName: String?
        let emailAddress: String?
    }
    private struct ProjectSearch: Decodable {
        struct Project: Decodable { let key: String }
        let total: Int?
        let values: [Project]?
    }

    /// Who am I, how many projects can I see, and is the configured project
    /// among them? Diagnoses the "token works but sees nothing" failure mode.
    static func connectionTest(config: JiraConfig) async -> String {
        do {
            let meData = try await send(
                try await authedRequest(config, path: "/rest/api/3/myself"))
            let me = try JSONDecoder().decode(Myself.self, from: meData)
            let projectData = try await send(try await authedRequest(
                config, path: "/rest/api/3/project/search",
                query: [URLQueryItem(name: "maxResults", value: "50")]))
            let projects = try JSONDecoder().decode(ProjectSearch.self, from: projectData)
            let keys = (projects.values ?? []).map(\.key)
            var report = "Connected as \(me.displayName ?? me.emailAddress ?? "unknown") · "
                + "\(projects.total ?? keys.count) project(s) visible."
            if keys.contains(config.projectKey) {
                report += " Project \(config.projectKey) ✓"
            } else {
                report += " ⚠️ Project \(config.projectKey) not visible"
                    + (keys.isEmpty ? "." : " — visible: \(keys.prefix(10).joined(separator: ", "))")
            }
            return report
        } catch {
            return "Connection test failed: \(error.localizedDescription)"
        }
    }
}
