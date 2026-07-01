import Foundation

struct Snapshot: Equatable, Codable {
    var monitors: [Monitor]
    var incidents: [Incident]
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

    static let empty = Snapshot(
        monitors: [], incidents: [], activity: [],
        lastRefresh: .distantPast, orgName: "—",
        connected: false, sampleData: false
    )
}
