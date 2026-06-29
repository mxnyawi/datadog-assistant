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

struct Monitor: Identifiable, Hashable {
    let id: Int
    let name: String
    let state: MonitorState
    let priority: Priority
    let firingSince: Date?
    let triggeredHosts: [String]
    let sparkline: [Double]
    let value: Double?
    let threshold: Double?
}
