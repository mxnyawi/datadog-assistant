import SwiftUI

enum Tab: CaseIterable, Hashable {
    case snooze, filters, monitors, sites, live, tools

    var symbol: String {
        switch self {
        case .snooze:   return "moon.zzz.fill"
        case .filters:  return "slider.horizontal.3"
        case .monitors: return "cpu"
        case .sites:    return "globe"
        case .live:     return "bolt.fill"
        case .tools:    return "wrench.and.screwdriver.fill"
        }
    }
}

struct TabStrip: View {
    @Binding var selected: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    selected = tab
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 13, weight: .semibold))
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
