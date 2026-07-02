import Foundation

/// Latest GitHub Actions run per workflow per watched repo. A red CI next to
/// a firing monitor and a fresh merge completes the "what changed?" picture.
struct CIRun: Identifiable, Hashable, Codable {
    enum State: String, Codable {
        case success
        case failure
        case running
        case other
    }

    let id: String
    let repo: String          // "owner/name"
    let workflow: String
    let state: State
    let branch: String?
    let startedAt: Date
    let url: URL?

    var relativeTime: String {
        let mins = max(0, Int(-startedAt.timeIntervalSinceNow / 60))
        if mins < 1 { return "now" }
        if mins < 60 { return "\(mins)m ago" }
        if mins < 60 * 24 { return "\(mins / 60)h ago" }
        return "\(mins / (60 * 24))d ago"
    }
}
