import Foundation

enum MonitorState: String, Codable {
    case alert
    case warn
    case noData
    case ok
    case muted

    var label: String {
        switch self {
        case .alert: return "Alerting"
        case .warn: return "Warning"
        case .noData: return "No Data"
        case .ok: return "Healthy"
        case .muted: return "Muted"
        }
    }
}

enum Priority: Int, Codable, Comparable {
    case p1 = 1, p2, p3, p4, p5

    var label: String { "P\(rawValue)" }

    static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct Monitor: Identifiable, Hashable, Codable {
    let id: Int
    let name: String
    let state: MonitorState
    let priority: Priority
    let firingSince: Date?
    let triggeredHosts: [String]
    /// Normalized 0…1 series for drawing; empty when no metric data available.
    let sparkline: [Double]
    /// Last raw metric value / the monitor's critical threshold, when parseable.
    let value: Double?
    let threshold: Double?
    /// Deep link into Datadog; nil for sample data.
    let url: URL?

    var firingDuration: String? {
        guard let since = firingSince else { return nil }
        let mins = max(0, Int(-since.timeIntervalSinceNow / 60))
        if mins < 60 { return "\(mins)m" }
        if mins < 60 * 24 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins / (60 * 24))d \(mins / 60 % 24)h"
    }
}
