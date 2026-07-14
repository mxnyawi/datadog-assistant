import SwiftUI

enum Tab: Hashable {
    case monitors, changes, snooze, tools
    /// Full searchable list; reached via the footer button, not the strip.
    case list

    /// Tabs shown in the strip, in order.
    static let strip: [Tab] = [.monitors, .changes, .snooze, .tools]

    var symbol: String {
        switch self {
        // speedometer: available since SF Symbols 1 — the fancier
        // gauge.with.needle needs macOS 14 and we target 13.
        case .monitors: return "speedometer"
        case .changes:  return "arrow.triangle.branch"
        case .snooze:   return "moon.zzz.fill"
        case .tools:    return "wrench.and.screwdriver.fill"
        case .list:     return "list.bullet"
        }
    }

    var label: String {
        switch self {
        case .monitors: return "Monitors"
        case .changes:  return "Changes"
        case .snooze:   return "Snooze"
        case .tools:    return "Tools"
        case .list:     return "All monitors"
        }
    }
}

/// Segmented tab switcher styled like a native segmented control: one card,
/// the selected segment lifted with a subtle fill, accent color for state.
struct TabStrip: View {
    @Binding var selected: Tab
    /// Badge counts (e.g. suspect changes) keyed by tab.
    var badges: [Tab: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.strip, id: \.self) { tab in
                segment(tab)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.panel)
        )
    }

    private func segment(_ tab: Tab) -> some View {
        Button {
            selected = tab
        } label: {
            HStack(spacing: 4) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(tab.label)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                if let count = badges[tab], count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(Theme.alert)
                }
            }
            .foregroundColor(selected == tab ? Theme.textPrimary : Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected == tab ? Theme.track : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(tab.label)
    }
}
