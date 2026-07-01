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
    /// Mutable (like the fields below) because they're attached in later fetch
    /// stages rather than known at decode time.
    var sparkline: [Double]
    /// Last raw metric value / the monitor's critical threshold, when parseable.
    var value: Double?
    let threshold: Double?
    /// Deep link into Datadog; nil for sample data.
    var url: URL? = nil
    /// From the monitor's service: tag; groups firing monitors into clusters.
    var service: String? = nil
    /// Current value ÷ same moment last week (week_before() time-shift query).
    /// 3.2 = "×3.2 vs last week". nil when the shifted series wasn't available.
    var delta: Double? = nil
    /// The critical threshold mapped into the sparkline's normalized 0…1 y-space,
    /// so views can draw the guide line without knowing the raw scale.
    var thresholdPosition: Double? = nil

    var firingDuration: String? {
        guard let since = firingSince else { return nil }
        let mins = max(0, Int(-since.timeIntervalSinceNow / 60))
        if mins < 60 { return "\(mins)m" }
        if mins < 60 * 24 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins / (60 * 24))d \(mins / 60 % 24)h"
    }
}
