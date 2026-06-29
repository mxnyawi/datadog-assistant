import SwiftUI

struct MonitorRow: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Text(monitor.priority.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Theme.color(for: monitor.state))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Theme.color(for: monitor.state).opacity(0.15))
                    )
                Text(monitor.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(rightLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.color(for: monitor.state))
            }
            Sparkline(points: monitor.sparkline, color: Theme.color(for: monitor.state))
                .frame(height: 26)
        }
        .padding(.vertical, 4)
    }

    private var rightLabel: String {
        if let v = monitor.value {
            if v >= 1000 { return String(format: "%.1fk", v / 1000) }
            if abs(v) < 10 { return String(format: "%.1f", v) }
            return String(format: "%.0f", v)
        }
        return monitor.state.label
    }
}
