import Foundation

enum IncidentSeverity: String, Codable {
    case sev1 = "SEV-1"
    case sev2 = "SEV-2"
    case sev3 = "SEV-3"
    case sev4 = "SEV-4"
    case sev5 = "SEV-5"
    case unknown = "UNKNOWN"
}

struct Incident: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let severity: IncidentSeverity
    let openedAt: Date
    let url: URL?
}
