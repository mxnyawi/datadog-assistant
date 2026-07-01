import SwiftUI

enum Tab: CaseIterable, Hashable {
    case monitors, changes, snooze, tools

    var symbol: String {
        switch self {
        case .monitors: return "cpu"
        case .changes:  return "arrow.triangle.branch"
        case .snooze:   return "moon.zzz.fill"
        case .tools:    return "wrench.and.screwdriver.fill"
        }
    }

    var label: String {
        switch self {
        case .monitors: return "Monitors"
        case .changes:  return "Changes"
        case .snooze:   return "Snooze"
        case .tools:    return "Tools"
        }
    }
}

struct TabStrip: View {
    @Binding var selected: Tab
    /// Badge counts (e.g. suspect changes) keyed by tab.
    var badges: [Tab: Int] = [:]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    selected = tab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 12, weight: .semibold))
                        if let count = badges[tab], count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(Theme.alert)
                        }
                    }
                    .foregroundColor(selected == tab ? Theme.info : Theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected == tab ? Theme.info.opacity(0.18) : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selected == tab ? Theme.info.opacity(0.45) : .clear,
                                            lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .help(tab.label)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.panelStroke, lineWidth: 1)
                )
        )
    }
}
