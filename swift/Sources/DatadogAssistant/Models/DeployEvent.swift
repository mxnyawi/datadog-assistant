import Foundation

/// A change that shipped — a GitHub PR merge or a Datadog deployment event.
/// The store correlates these against alert start times: a change that landed
/// shortly before a monitor started firing is flagged as a suspect, because
/// "what changed?" is the first question every responder asks.
struct DeployEvent: Identifiable, Hashable, Codable {
    enum Source: String, Codable {
        case github
        case datadog
    }

    let id: String
    let title: String
    let source: Source
    let occurredAt: Date
    let url: URL?
    /// service: tag (Datadog) or repo-derived service (GitHub); nil = org-wide.
    let service: String?
    /// Monitor ids this change is a suspect for (landed shortly before the
    /// alert started firing). Filled by SnapshotStore.markSuspects.
    var suspectFor: [Int] = []

    var relativeTime: String {
        let mins = max(0, Int(-occurredAt.timeIntervalSinceNow / 60))
        if mins < 1 { return "now" }
        if mins < 60 { return "\(mins)m ago" }
        if mins < 60 * 24 { return "\(mins / 60)h ago" }
        return "\(mins / (60 * 24))d ago"
    }
}
