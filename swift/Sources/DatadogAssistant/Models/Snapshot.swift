import Foundation

/// One of the user's Datadog dashboards, for the Tools tab's quick access.
struct DashboardLink: Equatable, Codable, Identifiable {
    let id: String
    let title: String
    var url: URL?
}

struct Snapshot: Equatable, Codable {
    var monitors: [Monitor]
    var incidents: [Incident]
    /// The user's dashboards (refreshed hourly), capped for display.
    var dashboards: [DashboardLink] = []
    /// Recent changes (GitHub merges + Datadog deploy events), newest first.
    var deploys: [DeployEvent]
    /// Latest GitHub Actions run per workflow per watched repo, failures first.
    var ciRuns: [CIRun]
    /// Rolling 0…1 series of overall alert pressure; maintained by SnapshotStore.
    var activity: [Double]
    var lastRefresh: Date
    var orgName: String
    var connected: Bool
    /// True while rendering MockDataSource output (no credentials configured).
    var sampleData: Bool
    /// How many No-Data monitors the hide-No-Data filter removed from this
    /// snapshot — lets the UI say "N hidden" instead of having monitors
    /// silently vanish. Optional so caches from older builds still decode.
    var hiddenNoDataCount: Int? = nil

    var alerting: [Monitor] { monitors.filter { $0.state == .alert } }
    var warning:  [Monitor] { monitors.filter { $0.state == .warn  } }
    var healthy:  [Monitor] { monitors.filter { $0.state == .ok    } }
    /// No Data that's likely broken — the actionable kind. Quiet (expected)
    /// silence lives in `quiet`.
    var noData:   [Monitor] { monitors.filter { $0.state == .noData && !$0.noDataQuiet } }
    /// No Data that triage judged expected (retired, resolve-on-missing,
    /// event-stream monitors…) — shown collapsed, never notified.
    var quiet:    [Monitor] { monitors.filter { $0.state == .noData && $0.noDataQuiet } }
    var muted:    [Monitor] { monitors.filter { $0.state == .muted } }
    /// Dead-letter-queue monitors, worst first (own panel section).
    var dlq: [Monitor] {
        monitors.filter(\.isDLQ).sorted {
            (severityRank($0.state), $0.name) < (severityRank($1.state), $1.name)
        }
    }

    private func severityRank(_ state: MonitorState) -> Int {
        switch state {
        case .alert: return 0
        case .warn: return 1
        case .noData: return 2
        case .muted: return 3
        case .ok: return 4
        }
    }

    /// Blast radius: services with ≥2 firing monitors, worst-first. Answers
    /// "is this one bad host or is payments on fire?" at a glance.
    struct Cluster: Equatable, Identifiable {
        let service: String
        let alerting: Int
        let warning: Int
        var id: String { service }
        var count: Int { alerting + warning }
    }

    var clusters: [Cluster] {
        var byService: [String: (alert: Int, warn: Int)] = [:]
        for m in monitors where m.state == .alert || m.state == .warn {
            guard let service = m.service else { continue }
            var entry = byService[service] ?? (0, 0)
            if m.state == .alert { entry.alert += 1 } else { entry.warn += 1 }
            byService[service] = entry
        }
        return byService
            .filter { $0.value.alert + $0.value.warn >= 2 }
            .map { Cluster(service: $0.key, alerting: $0.value.alert, warning: $0.value.warn) }
            .sorted { ($0.alerting, $0.count) > ($1.alerting, $1.count) }
    }

    static let empty = Snapshot(
        monitors: [], incidents: [], deploys: [], ciRuns: [], activity: [],
        lastRefresh: .distantPast, orgName: "—",
        connected: false, sampleData: false
    )
}
