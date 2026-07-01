import Foundation

/// Real Datadog API client. Monitors via v1 (with group states), incidents via
/// v2 (best-effort — silently empty if the app key lacks incident_read), and
/// best-effort sparklines for firing monitors via the v1 metrics query API.
final class DatadogClient: DataSource {
    private let credentials: Credentials
    private let session: URLSession

    /// Sparklines are one metrics query per firing monitor — cap the fan-out.
    private static let maxSparklines = 8
    private static let sparklineWindow: TimeInterval = 3600

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

        var monitors = try await monitorsTask
        let incidents = await incidentsTask   // best-effort, never throws

        monitors = await attachSparklines(to: monitors, previous: previous)

        return Snapshot(
            monitors: monitors,
            incidents: incidents,
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

    // MARK: - Monitors

    private struct MonitorDTO: Decodable {
        struct Options: Decodable {
            let silenced: [String: Int?]?
        }
        struct StateGroup: Decodable {
            let status: String?
            let last_triggered_ts: Int?
        }
        struct State: Decodable {
            let groups: [String: StateGroup]?
        }
        let id: Int
        let name: String?
        let query: String?
        let overall_state: String?
        let priority: Int?
        let options: Options?
        let state: State?
    }

    private func fetchMonitors() async throws -> [Monitor] {
        let url = credentials.apiBaseURL
            .appendingPathComponent("/api/v1/monitor")
            .appending(queryItems: [URLQueryItem(name: "group_states", value: "alert,warn")])
        let (data, response) = try await session.data(for: authedRequest(url: url))
        try Self.checkHTTP(response)
        let dtos = try JSONDecoder().decode([MonitorDTO].self, from: data)
        queriesByID = Dictionary(uniqueKeysWithValues: dtos.compactMap { dto in
            QueryParser.parse(dto.query ?? "").map { (dto.id, $0.metricQuery) }
        })
        return dtos.map(Self.monitor(from:)).map { m in
            Monitor(
                id: m.id, name: m.name, state: m.state, priority: m.priority,
                firingSince: m.firingSince, triggeredHosts: m.triggeredHosts,
                sparkline: m.sparkline, value: m.value, threshold: m.threshold,
                url: credentials.appBaseURL.appendingPathComponent("/monitors/\(m.id)")
            )
        }
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
        return Monitor(
            id: dto.id,
            name: dto.name ?? "monitor \(dto.id)",
            state: state,
            priority: Priority(rawValue: dto.priority ?? 3) ?? .p3,
            firingSince: firingSince,
            triggeredHosts: hosts,
            sparkline: [],
            value: nil,
            threshold: parsed?.threshold,
            url: nil
        )
    }

    // MARK: - Sparklines

    private struct QuerySeriesDTO: Decodable {
        struct Series: Decodable { let pointlist: [[Double?]]? }
        let series: [Series]?
    }

    private func attachSparklines(to monitors: [Monitor], previous: Snapshot?) async -> [Monitor] {
        let active = monitors
            .filter { $0.state == .alert || $0.state == .warn }
            .sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
            .prefix(Self.maxSparklines)
        guard !active.isEmpty else { return monitors }

        var byID = Dictionary(uniqueKeysWithValues: monitors.map { ($0.id, $0) })
        await withTaskGroup(of: (Int, [Double], Double?).self) { group in
            for monitor in active {
                group.addTask { [self] in
                    let (series, last) = await fetchSparkline(forMonitorID: monitor.id)
                    return (monitor.id, series, last)
                }
            }
            for await (id, series, last) in group {
                guard !series.isEmpty, let m = byID[id] else { continue }
                byID[id] = Monitor(
                    id: m.id, name: m.name, state: m.state, priority: m.priority,
                    firingSince: m.firingSince, triggeredHosts: m.triggeredHosts,
                    sparkline: series, value: last, threshold: m.threshold, url: m.url
                )
            }
        }
        return monitors.map { byID[$0.id] ?? $0 }
    }

    /// Parsed metric expressions from the last fetchMonitors call, keyed by
    /// monitor id, so sparkline fetches don't re-hit the monitors endpoint.
    private var queriesByID: [Int: String] = [:]

    private func fetchSparkline(forMonitorID id: Int) async -> ([Double], Double?) {
        guard let metricQuery = queriesByID[id] else { return ([], nil) }
        let now = Int(Date().timeIntervalSince1970)
        let url = credentials.apiBaseURL
            .appendingPathComponent("/api/v1/query")
            .appending(queryItems: [
                URLQueryItem(name: "from", value: String(now - Int(Self.sparklineWindow))),
                URLQueryItem(name: "to", value: String(now)),
                URLQueryItem(name: "query", value: metricQuery),
            ])
        guard let (data, response) = try? await session.data(for: authedRequest(url: url)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(QuerySeriesDTO.self, from: data),
              let points = decoded.series?.first?.pointlist else { return ([], nil) }

        let values = points.compactMap { $0.count > 1 ? $0[1] : nil }
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return ([], nil) }
        let range = hi - lo
        let normalized = range > 0 ? values.map { ($0 - lo) / range * 0.8 + 0.1 } : values.map { _ in 0.5 }
        return (normalized, values.last)
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

    // MARK: - Plumbing

    private func authedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(credentials.apiKey, forHTTPHeaderField: "DD-API-KEY")
        request.setValue(credentials.appKey, forHTTPHeaderField: "DD-APPLICATION-KEY")
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
