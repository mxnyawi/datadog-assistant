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
    /// Default (and minimum) span a sparkline covers. A firing monitor's
    /// sparkline stretches to cover how long it's been firing, so you see the
    /// climb since it started instead of a flat plateau — capped at
    /// `maxSparklineWindow` to keep the tiny chart readable and the query cheap.
    /// The 4h floor matters: `firingSince` is only known for group-based
    /// monitors, so ungrouped/just-started alerts would otherwise fall back to
    /// a short flat window; 4h guarantees enough history to show variation.
    static let sparklineWindow: TimeInterval = 4 * 3600
    static let maxSparklineWindow: TimeInterval = 48 * 3600

    let id: Int
    /// Display name — the Datadog name, or a local alias (see MonitorAliases,
    /// with the original kept in `originalName`).
    var name: String
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
    /// The monitor's Datadog tags (e.g. "team:payments"); drives filtering.
    var tags: [String] = []
    /// No-Data triage verdict: true = "quiet" (expected silence — retired
    /// monitor, event-stream type, resolve-on-missing…), false = likely
    /// broken. Only meaningful when state == .noData.
    var noDataQuiet: Bool = false
    /// Human-readable triage reason ("no data for 3d — likely retired").
    var noDataReason: String? = nil
    /// Dead-letter-queue monitor (name/tag pattern match) — grouped into a
    /// dedicated section.
    var isDLQ: Bool = false
    /// The Datadog-side name when a local rename (alias) is applied to `name`.
    var originalName: String? = nil
    /// Current value ÷ same moment last week (week_before() time-shift query).
    /// 3.2 = "×3.2 vs last week". nil when the shifted series wasn't available.
    var delta: Double? = nil
    /// The critical threshold mapped into the sparkline's normalized 0…1 y-space,
    /// so views can draw the guide line without knowing the raw scale.
    var thresholdPosition: Double? = nil
    /// True for `<`/`<=` monitors — ones that alert when the value drops UNDER
    /// the threshold. Flips breach shading, the gauge, and the ETA logic.
    /// Optional so snapshots cached by older builds still decode.
    var thresholdBelow: Bool? = nil
    var isBelowThreshold: Bool { thresholdBelow ?? false }
    /// Deploys that landed inside the sparkline window, as 0…1 x positions —
    /// "the line went vertical right after that tick" is the fastest possible
    /// change correlation. Filled by SnapshotStore.
    var deployMarkers: [Double] = []
    /// The actual time span this monitor's sparkline covers (grows with firing
    /// duration, up to `maxSparklineWindow`). Deploy-marker x-positions are
    /// computed against this, not the fixed default.
    var sparklineSpan: TimeInterval = sparklineWindow
    /// Week-ago series in the same normalized 0…1 space as `sparkline`, for the
    /// ghost overlay ("is this normal for right now?"). Empty when unavailable.
    var ghostSparkline: [Double] = []
    /// Per-group status (one entry per host/group) for the blast-radius
    /// heatmap. Empty for ungrouped monitors.
    var groupStates: [MonitorState] = []

    var firingDuration: String? {
        guard let since = firingSince else { return nil }
        let mins = max(0, Int(-since.timeIntervalSinceNow / 60))
        if mins < 60 { return "\(mins)m" }
        if mins < 60 * 24 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins / (60 * 24))d \(mins / 60 % 24)h"
    }
}

// MARK: - Trend analysis (for the projection tail + trend chip)

extension Monitor {
    /// A short projected continuation of the normalized sparkline: the least-
    /// squares slope of the recent tail, extended forward and clamped to 0…1.
    /// Empty when the series is too short or basically flat.
    func projection(points: Int = 12) -> [Double] {
        guard sparkline.count >= 6 else { return [] }
        let tail = Array(sparkline.suffix(10))
        let n = Double(tail.count)
        let xs = (0..<tail.count).map(Double.init)
        let sx = xs.reduce(0, +), sy = tail.reduce(0, +)
        let sxx = xs.map { $0 * $0 }.reduce(0, +)
        let sxy = zip(xs, tail).map(*).reduce(0, +)
        let denom = n * sxx - sx * sx
        guard abs(denom) > 1e-9 else { return [] }
        let slope = (n * sxy - sx * sy) / denom
        guard abs(slope) > 0.003 else { return [] }   // essentially flat
        let last = sparkline.last ?? tail.last!
        return (1...points).map { min(1, max(0, last + slope * Double($0))) }
    }

    /// One-line trend read for the expanded row: direction, and — when heading
    /// toward an as-yet-uncrossed critical threshold — an ETA to breach.
    /// Breach direction matters: an above-threshold monitor breaches by
    /// climbing, a below-threshold (`<`) monitor by falling, and "easing"
    /// means moving AWAY from its threshold in either case.
    var trendLabel: String? {
        let proj = projection()
        guard let now = sparkline.last, let end = proj.last else { return nil }
        let rising = end > now + 0.01
        let falling = end < now - 0.01
        guard rising || falling else { return nil }
        let below = isBelowThreshold
        if let thr = thresholdPosition {
            let crossIdx = below
                ? (falling && now > thr ? proj.firstIndex(where: { $0 <= thr }) : nil)
                : (rising && now < thr ? proj.firstIndex(where: { $0 >= thr }) : nil)
            if let crossIdx {
                let secPerPoint = sparklineSpan / Double(max(sparkline.count - 1, 1))
                let mins = max(1, Int(Double(crossIdx + 1) * secPerPoint / 60))
                return "\(below ? "falling" : "climbing") · ~critical in \(mins)m"
            }
        }
        if below { return falling ? "falling" : "easing" }
        return rising ? "climbing" : "easing"
    }
}
