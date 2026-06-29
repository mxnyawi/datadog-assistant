import SwiftUI

enum Theme {
    static let bg            = Color(red: 0.07, green: 0.09, blue: 0.13)
    static let panel         = Color.white.opacity(0.05)
    static let panelStroke   = Color.white.opacity(0.08)
    static let textPrimary   = Color.white
    static let textSecondary = Color.white.opacity(0.60)
    static let textMuted     = Color.white.opacity(0.40)

    static let alert    = Color(red: 1.00, green: 0.35, blue: 0.40)
    static let warn     = Color(red: 1.00, green: 0.78, blue: 0.30)
    static let ok       = Color(red: 0.30, green: 0.90, blue: 0.50)
    static let info     = Color(red: 0.38, green: 0.72, blue: 1.00)
    static let muted    = Color.white.opacity(0.40)

    static func color(for state: MonitorState) -> Color {
        switch state {
        case .alert: return alert
        case .warn:  return warn
        case .ok:    return ok
        case .noData: return info
        case .muted: return muted
        }
    }
}
