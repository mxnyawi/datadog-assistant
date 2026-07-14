import SwiftUI
import AppKit

/// Semantic design tokens. Everything maps to system colors so the panel
/// adapts to light/dark mode and accessibility settings for free — the HIG
/// way, instead of the original hard-coded dark-glass palette.
enum Theme {
    // Text hierarchy (label → secondary → tertiary, per HIG).
    static let textPrimary   = Color.primary
    static let textSecondary = Color.secondary
    static let textMuted     = Color(nsColor: .tertiaryLabelColor)

    /// Grouped-inset card fill (the System Settings / Control Center idiom:
    /// separation by cards and whitespace, not hairlines).
    static let panel       = Color(nsColor: .quaternaryLabelColor).opacity(0.55)
    static let panelStroke = Color(nsColor: .separatorColor)
    /// Row highlight under the pointer (menus highlight; window panels must
    /// roll their own).
    static let hover       = Color.primary.opacity(0.07)
    /// Track behind gauges/progress fills.
    static let track       = Color.primary.opacity(0.10)

    // Status colors: system palette, auto-adapting to appearance & contrast.
    static let alert = Color(nsColor: .systemRed)
    static let warn  = Color(nsColor: .systemOrange)
    static let ok    = Color(nsColor: .systemGreen)
    static let info  = Color(nsColor: .systemBlue)
    static let muted = Color(nsColor: .systemGray)

    static func color(for state: MonitorState) -> Color {
        switch state {
        case .alert:  return alert
        case .warn:   return warn
        case .ok:     return ok
        case .noData: return info
        case .muted:  return muted
        }
    }

    /// Filled SF Symbol per state — shape *and* color encode status, so rows
    /// stay readable for color-blind users (HIG: never color alone).
    static func symbol(for state: MonitorState) -> String {
        switch state {
        case .alert:  return "exclamationmark.octagon.fill"
        case .warn:   return "exclamationmark.triangle.fill"
        case .ok:     return "checkmark.circle.fill"
        case .noData: return "questionmark.circle.fill"
        case .muted:  return "speaker.slash.circle.fill"
        }
    }
}

/// The one section-header style: 11pt semibold secondary text, optional
/// trailing count — the Battery-menu "Using Significant Energy" grammar.
struct SectionHeader: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        // No trailing Spacer: callers compose badges right after the title
        // (DLQ "N firing", Activity pressure chip), and a greedy header would
        // shove them to the panel edge. Leading alignment comes from the
        // enclosing VStack.
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
            }
        }
        .foregroundColor(Theme.textSecondary)
        .padding(.leading, 10)
    }
}

/// Grouped-inset container: rows sit on one rounded card, separated by
/// whitespace — no hairlines (the System Settings / Control Center idiom).
struct InsetCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.panel)
        )
    }
}
