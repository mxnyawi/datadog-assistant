import Foundation

/// Jira Cloud configuration for one-tap ticket creation from an alert.
/// Non-secret fields persist in UserDefaults; the API token lives in the
/// Keychain — or, in LastPass mode, comes out of the same shared secure note
/// as the Datadog keys (field `jiraToken` by default), so a team vault
/// provisions Jira too. Env vars (JIRA_BASE_URL / JIRA_EMAIL / JIRA_API_TOKEN)
/// override for the dev loop.
struct JiraConfig: Equatable {
    /// Host only, e.g. "yourorg.atlassian.net".
    var baseURL: String
    var email: String
    var projectKey: String
    var issueType: String = "Task"
    /// LastPass note field holding the API token (LastPass mode only).
    var lastPassTokenField: String = "jiraToken"
    /// Auto-create tickets when a monitor fires: 0 = off, 1 = P1 only,
    /// 2 = P1+P2. Dedupe: a monitor that already has a ticket never gets
    /// another.
    var autoCreatePriority: Int = 0

    static let issueTypes = ["Task", "Bug", "Incident", "Story"]

    private static let baseURLKey = "jiraBaseURL"
    private static let emailKey = "jiraEmail"
    private static let projectKey_ = "jiraProjectKey"
    private static let issueTypeKey = "jiraIssueType"
    private static let lastPassFieldKey = "jiraLastPassTokenField"
    private static let autoCreateKey = "jiraAutoCreatePriority"
    private static let tokenService = "datadog-assistant-jira-token"

    /// Loaded config, or nil until the base URL, email, and project are set.
    static func load() -> JiraConfig? {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let baseURL = env["JIRA_BASE_URL"] ?? defaults.string(forKey: baseURLKey) ?? ""
        let email = env["JIRA_EMAIL"] ?? defaults.string(forKey: emailKey) ?? ""
        let project = defaults.string(forKey: projectKey_) ?? ""
        guard !baseURL.isEmpty, !email.isEmpty, !project.isEmpty else { return nil }
        return JiraConfig(
            baseURL: baseURL,
            email: email,
            projectKey: project,
            issueType: defaults.string(forKey: issueTypeKey) ?? "Task",
            lastPassTokenField: defaults.string(forKey: lastPassFieldKey) ?? "jiraToken",
            autoCreatePriority: defaults.integer(forKey: autoCreateKey))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(baseURL, forKey: Self.baseURLKey)
        defaults.set(email, forKey: Self.emailKey)
        defaults.set(projectKey, forKey: Self.projectKey_)
        defaults.set(issueType, forKey: Self.issueTypeKey)
        defaults.set(lastPassTokenField, forKey: Self.lastPassFieldKey)
        defaults.set(autoCreatePriority, forKey: Self.autoCreateKey)
    }

    static func clear() {
        let defaults = UserDefaults.standard
        for key in [baseURLKey, emailKey, projectKey_, issueTypeKey, lastPassFieldKey,
                    autoCreateKey] {
            defaults.removeObject(forKey: key)
        }
        Keychain.delete(service: tokenService)
    }

    static func saveToken(_ token: String) throws {
        try Keychain.write(service: tokenService, value: token)
    }

    /// Env → LastPass vault → Keychain, same precedence as everything else.
    func resolveToken() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let token = env["JIRA_API_TOKEN"], !token.isEmpty { return token }
        if AuthMode.current == .lastPass, !lastPassTokenField.isEmpty,
           let lastPass = LastPassConfig.load(), LastPass.isLoggedIn(),
           let token = LastPass.get(entry: lastPass.lookupRef, field: lastPassTokenField) {
            return token
        }
        return Keychain.read(service: Self.tokenService)
    }
}

/// Which ticket belongs to which monitor, persisted across launches. This is
/// the dedupe: an alert that already has a ticket shows "Open PROJ-123"
/// instead of minting duplicates every time it fires.
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

/// Auto-create tickets for high-priority alerts, mirroring the Python app's
/// P1/P2 auto-create with dedupe. Runs on fired transitions; the created
/// ticket is announced with a notification that opens it on tap.
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

/// Minimal Jira Cloud REST client: create one issue for a firing monitor.
enum JiraClient {
    enum JiraError: LocalizedError {
        case noToken
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noToken:
                return "No Jira API token — add one in Settings → Jira (or the LastPass note)."
            case .http(let code, let detail):
                return "Jira returned HTTP \(code)\(detail.isEmpty ? "" : " — \(detail)")"
            }
        }
    }

    private struct CreateResponse: Decodable { let key: String }

    /// Create a ticket for a monitor and remember the monitor → ticket
    /// mapping; returns the new issue's key and browse URL.
    static func createIssue(for monitor: Monitor, config: JiraConfig) async throws
        -> (key: String, url: URL) {
        guard let token = config.resolveToken(), !token.isEmpty else { throw JiraError.noToken }
        let host = config.baseURL
            .replacingOccurrences(of: "https://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "https://\(host)/rest/api/2/issue") else {
            throw JiraError.http(0, "invalid base URL")
        }

        var description = "Created by Datadog Assistant.\n\n"
        description += "*State:* \(monitor.state.label) (\(monitor.priority.label))\n"
        if let duration = monitor.firingDuration { description += "*Firing for:* \(duration)\n" }
        if !monitor.triggeredHosts.isEmpty {
            description += "*Groups:* \(monitor.triggeredHosts.joined(separator: ", "))\n"
        }
        if let monitorURL = monitor.url { description += "\n[Open in Datadog|\(monitorURL.absoluteString)]" }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let basic = Data("\(config.email):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fields": [
                "project": ["key": config.projectKey],
                "summary": "[\(monitor.priority.label)] \(monitor.name)",
                "description": description,
                "issuetype": ["name": config.issueType],
                "labels": ["datadog-assistant"],
            ],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw JiraError.http(code, detail)
        }
        let created = try JSONDecoder().decode(CreateResponse.self, from: data)
        let browseURL = URL(string: "https://\(host)/browse/\(created.key)")!
        JiraTicketStore.record(ticketKey: created.key, url: browseURL, for: monitor.id)
        return (created.key, browseURL)
    }
}
