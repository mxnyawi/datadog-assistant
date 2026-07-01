import Foundation

struct Snapshot: Equatable, Codable {
    var monitors: [Monitor]
    var incidents: [Incident]
    /// Recent changes (GitHub merges + Datadog deploy events), newest first.
    var deploys: [DeployEvent]
    /// Rolling 0…1 series of overall alert pressure; maintained by SnapshotStore.
    var activity: [Double]
    var lastRefresh: Date
    var orgName: String
    var connected: Bool
    /// True while rendering MockDataSource output (no credentials configured).
    var sampleData: Bool

    var alerting: [Monitor] { monitors.filter { $0.state == .alert } }
    var warning:  [Monitor] { monitors.filter { $0.state == .warn  } }
    var healthy:  [Monitor] { monitors.filter { $0.state == .ok    } }
    var noData:   [Monitor] { monitors.filter { $0.state == .noData } }
    var muted:    [Monitor] { monitors.filter { $0.state == .muted } }

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
        monitors: [], incidents: [], deploys: [], activity: [],
        lastRefresh: .distantPast, orgName: "—",
        connected: false, sampleData: false
    )
}
