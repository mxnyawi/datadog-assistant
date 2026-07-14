import Foundation

/// Real Datadog API client. Monitors via v1 (with group states), incidents via
/// v2 (best-effort — silently empty if the app key lacks incident_read), and
/// best-effort sparklines for firing monitors via the v1 metrics query API.
final class DatadogClient: DataSource {
    private let credentials: Credentials
    private let session: URLSession

    /// Sparklines are one metrics query per firing monitor — cap the fan-out.
    private static let maxSparklines = 8
    private static let sparklineWindow = Monitor.sparklineWindow

    var sourceName: String { credentials.site }

    init(credentials: Credentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - DataSource

    func fetchSnapshot(previous: Snapshot?) async throws -> Snapshot {
        async let monitorsTask = fetchMonitors()
        async let incidentsTask = fetchIncidents()
        async let deploysTask = fetchDeployEvents()
        async let dashboardsTask = fetchDashboards()

        var monitors = try await monitorsTask
        let incidents = await incidentsTask   // best-effort, never throws
        let deploys = await deploysTask       // best-effort, never throws
        let dashboards = await dashboardsTask // best-effort, hourly-cached

        monitors = await attachSparklines(to: monitors, previous: previous)

        return Snapshot(
            monitors: monitors,
            incidents: incidents,
            dashboards: dashboards,
            deploys: deploys,
            ciRuns: [],                           // store fills from GitHub
            activity: previous?.activity ?? [],   // store owns this series
            lastRefresh: Date(),
            orgName: credentials.site,
            connected: true,
            sampleData: false
        )
    }

    func mute(monitorID: Int, until: Date?) async throws {
        var components = URLComponents(
            url: credentials.apiBaseURL.appendingPathComponent("/api/v1/monitor/\(monitorID)/mute"),
            resolvingAgainstBaseURL: false
        )!
        if let until {
            components.queryItems = [URLQueryItem(name: "end", value: String(Int(until.timeIntervalSince1970)))]
        }
        var request = authedRequest(url: components.url!)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try Self.checkHTTP(response)
    }

    func unmute(monitorID: Int) async throws {
        var request = authedRequest(
            url: credentials.apiBaseURL.appendingPathComponent("/api/v1/monitor/\(monitorID)/unmute"))
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        try Self.checkHTTP(response)
    }

    // MARK: - Monitors

    private struct MonitorDTO: Decodable {
        struct Options: Decodable {
            let silenced: [String: Int?]?
            let notify_no_data: Bool?
            let on_missing_data: String?
        }
        struct StateGroup: Decodable {
            let status: String?
            let last_triggered_ts: Int?
            let last_nodata_ts: Int?
        }
        struct State: Decodable {
            let groups: [String: StateGroup]?
        }
        let id: Int
        let name: String?
        let type: String?
        let query: String?
        let overall_state: String?
        let overall_state_modified: String?
        let priority: Int?
        let tags: [String]?
        let options: Options?
        let state: State?
    }

    private func fetchMonitors() async throws -> [Monitor] {
        // Datadog's monitor_tags param is AND logic; the filter wants OR
        // (same as the Python app), so fetch once per selected tag and dedupe
        // by monitor ID.
        probesThisPoll = 0
        let filter = FilterConfig.load()
        var dtos: [MonitorDTO]
        if filter.tags.count > 1 {
            var byID: [Int: MonitorDTO] = [:]
            for tag in filter.tags {
                for dto in try await fetchMonitorsPage(tag: tag, name: filter.name) {
                    byID[dto.id] = byID[dto.id] ?? dto
                }
            }
            dtos = Array(byID.values)
        } else {
            dtos = try await fetchMonitorsPage(tag: filter.tags.first ?? "", name: filter.name)
        }
        queriesByID = Dictionary(uniqueKeysWithValues: dtos.compactMap { dto in
            QueryParser.parse(dto.query ?? "").map { (dto.id, $0.metricQuery) }
        })
        var monitors: [Monitor] = []
        for dto in dtos {
            var monitor = Self.monitor(from: dto)
            monitor.url = credentials.appBaseURL.appendingPathComponent("/monitors/\(dto.id)")
            monitor.isDLQ = DLQConfig.load().matches(name: monitor.name,
                                                     tags: monitor.tags,
                                                     query: dto.query ?? "")
            if monitor.state == .noData {
                (monitor.noDataQuiet, monitor.noDataReason) = await triageNoData(dto)
            } else {
                probeCache.removeValue(forKey: dto.id)
            }
            monitors.append(monitor)
        }
        return monitors
    }

    // MARK: - No-Data triage (broken vs quiet)

    private static let eventMonitorTypes: Set<String> = [
        "log alert", "event alert", "event-v2 alert", "rum alert",
        "trace-analytics alert", "error-tracking alert",
        "ci-pipelines alert", "ci-tests alert", "audit alert",
    ]
    private static let staleHours = 48.0
    private static let probeLookbackHours = 24.0
    private static let maxProbes = 6

    /// Verdicts cached while a monitor stays in No Data; probes are the
    /// expensive part and silence rarely changes shape.
    private var probeCache: [Int: (quiet: Bool, reason: String)] = [:]
    private var probesThisPoll = 0

    /// Split No Data into "likely broken" (top-level, notifies) and "quiet"
    /// (expected — collapsed, silent). Port of the Python `_triage_no_data`
    /// ladder; defaults to broken when ambiguous.
    private func triageNoData(_ dto: MonitorDTO) async -> (quiet: Bool, reason: String) {
        if let cached = probeCache[dto.id] { return cached }

        func remember(_ verdict: (quiet: Bool, reason: String)) -> (Bool, String) {
            probeCache[dto.id] = verdict
            return verdict
        }

        let onMissing = dto.options?.on_missing_data ?? ""
        if onMissing == "resolve" || onMissing == "show_ok" {
            return remember((true, "resolves when data stops — silence is expected"))
        }
        if dto.options?.notify_no_data == false, !onMissing.hasPrefix("show_and_notify") {
            return remember((true, "monitor doesn't alert on missing data"))
        }
        if let type = dto.type, Self.eventMonitorTypes.contains(type) {
            return remember((true, "\(type) — zero events is normal"))
        }
        if let age = noDataAge(dto), age > Self.staleHours * 3600 {
            return remember((true, "no data for \(Int(age / 86400))d — likely retired"))
        }
        // Live probe: was the metric flowing and then stopped (broken), or has
        // it been silent all along (quiet)? Budgeted per poll.
        if let metricQuery = queriesByID[dto.id], probesThisPoll < Self.maxProbes {
            probesThisPoll += 1
            if let hadData = await probeHadRecentData(metricQuery) {
                return remember(hadData
                    ? (false, "metric was flowing, then stopped")
                    : (true, "metric has been silent for 24h+"))
            }
        }
        if dto.options?.notify_no_data == true {
            return remember((false, "monitor explicitly alerts on missing data"))
        }
        return remember((false, "no data — check the source"))
    }

    private func noDataAge(_ dto: MonitorDTO) -> TimeInterval? {
        let now = Date().timeIntervalSince1970
        if let ts = dto.state?.groups?.values.compactMap(\.last_nodata_ts).min() {
            return now - TimeInterval(ts)
        }
        if let modified = dto.overall_state_modified {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: modified) ?? ISO8601DateFormatter().date(from: modified) {
                return now - date.timeIntervalSince1970
            }
        }
        return nil
    }

    /// True if the metric had any points in the lookback window; nil when the
    /// probe itself failed (no verdict).
    private func probeHadRecentData(_ metricQuery: String) async -> Bool? {
        let now = Int(Date().timeIntervalSince1970)
        let url = credentials.apiBaseURL
            .appendingPathComponent("/api/v1/query")
            .appending(queryItems: [
                URLQueryItem(name: "from", value: String(now - Int(Self.probeLookbackHours * 3600))),
                URLQueryItem(name: "to", value: String(now)),
                URLQueryItem(name: "query", value: metricQuery),
            ])
        guard let (data, response) = try? await session.data(for: authedRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(QuerySeriesDTO.self, from: data)
        else { return nil }
        let points = decoded.series?.flatMap { $0.pointlist ?? [] } ?? []
        return !points.isEmpty
    }

    /// Paginated fetch (200/page) so one giant response can't stall on large
    /// orgs; hard page cap mirrors the Python app's runaway-loop guard.
    private func fetchMonitorsPage(tag: String, name: String) async throws -> [MonitorDTO] {
        var queryItems = [
            URLQueryItem(name: "group_states", value: "all"),
            URLQueryItem(name: "page_size", value: "200"),
        ]
        if !tag.isEmpty { queryItems.append(URLQueryItem(name: "monitor_tags", value: tag)) }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { queryItems.append(URLQueryItem(name: "name", value: trimmedName)) }

        var all: [MonitorDTO] = []
        var page = 0
        while page < 500 {
            let url = credentials.apiBaseURL
                .appendingPathComponent("/api/v1/monitor")
                .appending(queryItems: queryItems + [URLQueryItem(name: "page", value: String(page))])
            let data = try await requestWithRetry(url: url)
            let batch = try JSONDecoder().decode([MonitorDTO].self, from: data)
            all += batch
            if batch.count < 200 { break }
            page += 1
        }
        return all
    }

    /// Transient network errors (timeout, connection reset) get 3 tries with
    /// a short growing backoff; HTTP errors surface immediately.
    private func requestWithRetry(url: URL) async throws -> Data {
        var lastError: Error = APIError.http(0)
        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: authedRequest(url: url))
                try Self.checkHTTP(response)
                return data
            } catch let error as APIError {
                throw error   // real HTTP status — retrying won't help
            } catch {
                lastError = error
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        throw lastError
    }

    private static func monitor(from dto: MonitorDTO) -> Monitor {
        let silencedAll = dto.options?.silenced?.keys.contains("*") ?? false
        let state: MonitorState
        switch (silencedAll, dto.overall_state ?? "") {
        case (true, _):        state = .muted
        case (_, "Alert"):     state = .alert
        case (_, "Warn"):      state = .warn
        case (_, "No Data"):   state = .noData
        default:               state = .ok
        }

        var firingSince: Date?
        var hosts: [String] = []
        if let groups = dto.state?.groups {
            for (name, group) in groups where group.status == "Alert" || group.status == "Warn" {
                hosts.append(name)
                if let ts = group.last_triggered_ts {
                    let date = Date(timeIntervalSince1970: TimeInterval(ts))
                    firingSince = min(firingSince ?? date, date)
                }
            }
        }
        hosts.sort()

        let parsed = QueryParser.parse(dto.query ?? "")
        let service = dto.tags?
            .first { $0.hasPrefix("service:") }
            .map { String($0.dropFirst("service:".count)) }
        return Monitor(
            id: dto.id,
            name: dto.name ?? "monitor \(dto.id)",
            state: state,
            priority: Self.priority(of: dto),
            firingSince: firingSince,
            triggeredHosts: hosts,
            sparkline: [],
            value: nil,
            threshold: parsed?.threshold,
            url: nil,
            service: service,
            tags: dto.tags ?? []
        )
    }

    /// Priority: the monitor's priority field, else a priority:pN / priority:N
    /// tag, else "[PN]" in the name — same detection ladder as the Python app.
    private static func priority(of dto: MonitorDTO) -> Priority {
        if let raw = dto.priority, let priority = Priority(rawValue: raw) { return priority }
        for tag in dto.tags ?? [] where tag.lowercased().hasPrefix("priority:") {
            let value = tag.dropFirst("priority:".count).lowercased()
            let digits = value.hasPrefix("p") ? value.dropFirst() : value[...]
            if let n = Int(digits), let priority = Priority(rawValue: n) { return priority }
        }
        if let name = dto.name?.uppercased() {
            for n in 1...5 where name.contains("[P\(n)]") {
                if let priority = Priority(rawValue: n) { return priority }
            }
        }
        return .p3
    }

    // MARK: - Sparklines

    private struct QuerySeriesDTO: Decodable {
        struct Series: Decodable { let pointlist: [[Double?]]? }
        let series: [Series]?
    }

    /// What one metrics round-trip yields for a monitor. The query is the
    /// clever bit: "m, week_before(m)" fetches the live series AND the same
    /// series time-shifted a week back in a single API call, so the ×N-vs-
    /// last-week delta costs nothing extra.
    private struct SparkData {
        var series: [Double] = []
        var lastValue: Double?
        var delta: Double?
        var thresholdPosition: Double?
    }

    private func attachSparklines(to monitors: [Monitor], previous: Snapshot?) async -> [Monitor] {
        let active = monitors
            .filter { $0.state == .alert || $0.state == .warn }
            .sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
            .prefix(Self.maxSparklines)
        guard !active.isEmpty else { return monitors }

        var byID = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        await withTaskGroup(of: (Int, SparkData).self) { group in
            for monitor in active {
                group.addTask { [self] in
                    (monitor.id, await fetchSparkline(forMonitorID: monitor.id,
                                                      threshold: monitor.threshold))
                }
            }
            for await (id, spark) in group {
                guard !spark.series.isEmpty, var m = byID[id] else { continue }
                m.sparkline = spark.series
                m.value = spark.lastValue
                m.delta = spark.delta
                m.thresholdPosition = spark.thresholdPosition
                byID[id] = m
            }
        }
        return monitors.map { byID[$0.id] ?? $0 }
    }

    /// Parsed metric expressions from the last fetchMonitors call, keyed by
    /// monitor id, so sparkline fetches don't re-hit the monitors endpoint.
    private var queriesByID: [Int: String] = [:]

    private func fetchSparkline(forMonitorID id: Int, threshold: Double?) async -> SparkData {
        guard let metricQuery = queriesByID[id] else { return SparkData() }
        let now = Int(Date().timeIntervalSince1970)
        let url = credentials.apiBaseURL
            .appendingPathComponent("/api/v1/query")
            .appending(queryItems: [
                URLQueryItem(name: "from", value: String(now - Int(Self.sparklineWindow))),
                URLQueryItem(name: "to", value: String(now)),
                URLQueryItem(name: "query", value: "\(metricQuery), week_before(\(metricQuery))"),
            ])
        guard let (data, response) = try? await session.data(for: authedRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(QuerySeriesDTO.self, from: data),
              let series = decoded.series, !series.isEmpty,
              let points = series.first?.pointlist else { return SparkData() }

        let values = points.compactMap { $0.count > 1 ? $0[1] : nil }
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return SparkData() }
        let range = hi - lo
        let normalize = { (v: Double) in range > 0 ? (v - lo) / range * 0.8 + 0.1 : 0.5 }

        var spark = SparkData()
        spark.series = values.map(normalize)
        spark.lastValue = values.last

        // Threshold guide line, mapped into the same normalized space; only
        // meaningful when it falls near the visible range.
        if let threshold, range > 0 {
            let position = normalize(threshold)
            if (-0.1...1.1).contains(position) {
                spark.thresholdPosition = min(1.0, max(0.0, position))
            }
        }

        // series[1] is week_before(m): compare now vs the same moment last week.
        if series.count > 1,
           let shifted = series[1].pointlist?.compactMap({ $0.count > 1 ? $0[1] : nil }),
           let lastWeek = shifted.last, let current = values.last,
           abs(lastWeek) > 1e-9 {
            let ratio = current / lastWeek
            if ratio.isFinite, ratio > 0 { spark.delta = ratio }
        }
        return spark
    }

    // MARK: - Incidents

    private struct IncidentsDTO: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable {
                struct Field: Decodable { let value: String? }
                let title: String?
                let created: String?
                let fields: [String: Field]?
            }
            let id: String
            let attributes: Attributes
        }
        let data: [Item]?
    }

    private func fetchIncidents() async -> [Incident] {
        let url = credentials.apiBaseURL
            .appendingPathComponent("/api/v2/incidents")
            .appending(queryItems: [URLQueryItem(name: "page[size]", value: "50")])
        guard let (data, response) = try? await session.data(for: authedRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(IncidentsDTO.self, from: data),
              let items = decoded.data else { return [] }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()

        return items.compactMap { item in
            let fields = item.attributes.fields ?? [:]
            guard fields["state"]?.value == "active" else { return nil }
            let sevRaw = fields["severity"]?.value ?? "UNKNOWN"
            let created = item.attributes.created.flatMap {
                iso.date(from: $0) ?? isoPlain.date(from: $0)
            } ?? Date()
            return Incident(
                id: item.id,
                title: item.attributes.title ?? "Incident",
                severity: IncidentSeverity(rawValue: sevRaw) ?? .unknown,
                openedAt: created,
                url: credentials.appBaseURL.appendingPathComponent("/incidents")
            )
        }
        .sorted { $0.severity.rawValue < $1.severity.rawValue }
    }

    // MARK: - Dashboards (hourly-cached)

    private struct DashboardsDTO: Decodable {
        struct Item: Decodable {
            let id: String?
            let title: String?
            let url: String?
        }
        let dashboards: [Item]?
    }

    private var cachedDashboards: [DashboardLink] = []
    private var dashboardsFetchedAt: Date = .distantPast

    /// The user's dashboards for quick links; refreshed at most hourly since
    /// dashboards rarely change.
    private func fetchDashboards() async -> [DashboardLink] {
        if Date().timeIntervalSince(dashboardsFetchedAt) < 3600 { return cachedDashboards }
        let url = credentials.apiBaseURL.appendingPathComponent("/api/v1/dashboard")
        guard let (data, response) = try? await session.data(for: authedRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(DashboardsDTO.self, from: data)
        else { return cachedDashboards }
        cachedDashboards = (decoded.dashboards ?? []).compactMap { item in
            guard let id = item.id, let title = item.title else { return nil }
            return DashboardLink(
                id: id,
                title: title,
                url: item.url.flatMap { URL(string: $0, relativeTo: credentials.appBaseURL) })
        }
        dashboardsFetchedAt = Date()
        return cachedDashboards
    }

    // MARK: - Deploy events

    private struct EventsDTO: Decodable {
        struct Event: Decodable {
            let id: Int?
            let title: String?
            let date_happened: Int?
            let url: String?
            let tags: [String]?
        }
        let events: [Event]?
    }

    /// Deployment events from the Datadog events stream. The tag to match is
    /// configurable (defaults "deployment") because orgs tag deploys
    /// differently; best-effort — an org without deploy events just gets an
    /// empty Changes feed.
    private func fetchDeployEvents() async -> [DeployEvent] {
        let tag = UserDefaults.standard.string(forKey: "deployTag") ?? "deployment"
        let now = Int(Date().timeIntervalSince1970)
        let url = credentials.apiBaseURL
            .appendingPathComponent("/api/v1/events")
            .appending(queryItems: [
                URLQueryItem(name: "start", value: String(now - 6 * 3600)),
                URLQueryItem(name: "end", value: String(now)),
                URLQueryItem(name: "tags", value: tag),
            ])
        guard let (data, response) = try? await session.data(for: authedRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(EventsDTO.self, from: data),
              let events = decoded.events else { return [] }

        return events.compactMap { event in
            guard let ts = event.date_happened else { return nil }
            let service = event.tags?
                .first { $0.hasPrefix("service:") }
                .map { String($0.dropFirst("service:".count)) }
            return DeployEvent(
                id: "dd-\(event.id ?? ts)",
                title: event.title ?? "Deployment",
                source: .datadog,
                occurredAt: Date(timeIntervalSince1970: TimeInterval(ts)),
                url: event.url.flatMap {
                    $0.hasPrefix("http") ? URL(string: $0)
                                         : URL(string: $0, relativeTo: credentials.appBaseURL)
                },
                service: service
            )
        }
        .sorted { $0.occurredAt > $1.occurredAt }
    }

    // MARK: - Snooze (org-wide downtime)

    private struct DowntimeDTO: Decodable { let id: Int? }

    func snoozeAll(until: Date) async throws -> String? {
        var request = authedRequest(
            url: credentials.apiBaseURL.appendingPathComponent("/api/v1/downtime"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "scope": ["*"],
            "end": Int(until.timeIntervalSince1970),
            "message": "Snoozed from Datadog Assistant",
        ])
        let (data, response) = try await session.data(for: request)
        try Self.checkHTTP(response)
        return (try? JSONDecoder().decode(DowntimeDTO.self, from: data))?.id.map(String.init)
    }

    func cancelSnooze(handle: String) async throws {
        var request = authedRequest(
            url: credentials.apiBaseURL.appendingPathComponent("/api/v1/downtime/\(handle)"))
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try Self.checkHTTP(response)
    }

    // MARK: - Plumbing

    private func authedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        credentials.authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    enum APIError: LocalizedError {
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .http(let code):
                return code == 403
                    ? "403 from Datadog — check keys, scopes, and site"
                    : "Datadog API returned HTTP \(code)"
            }
        }
    }

    private static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
    }
}

/// Pulls the metric expression and critical threshold out of a classic metric
/// monitor query, e.g. "avg(last_5m):avg:system.cpu.user{env:prod} > 85".
/// Best-effort: composite / log / synthetic queries return nil and the monitor
/// simply renders without a sparkline.
enum QueryParser {
    static func parse(_ query: String) -> (metricQuery: String, threshold: Double)? {
        let pattern = #"^[a-z_]+\([^)]*\):\s*(.+?)\s*(?:>=|<=|>|<|==)\s*([0-9.]+)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: query, range: NSRange(query.startIndex..., in: query)),
              let metricRange = Range(match.range(at: 1), in: query),
              let thresholdRange = Range(match.range(at: 2), in: query),
              let threshold = Double(query[thresholdRange]) else { return nil }
        return (String(query[metricRange]), threshold)
    }
}
