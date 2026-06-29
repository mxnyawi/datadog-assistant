import Foundation

struct Snapshot: Equatable {
    var monitors: [Monitor]
    var incidents: [Incident]
    var activity: [Double]
    var lastRefresh: Date
    var orgName: String
    var connected: Bool

    var alerting: [Monitor] { monitors.filter { $0.state == .alert } }
    var warning:  [Monitor] { monitors.filter { $0.state == .warn  } }
    var healthy:  [Monitor] { monitors.filter { $0.state == .ok    } }
    var noData:   [Monitor] { monitors.filter { $0.state == .noData } }
    var muted:    [Monitor] { monitors.filter { $0.state == .muted } }
}
