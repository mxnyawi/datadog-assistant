import SwiftUI

/// The MTTR story in one row: how fast this app noticed, how loud today has
/// been, and how quickly things recover. Hidden until there's real data —
/// zeros are a worse look than absence.
struct ResponseStrip: View {
    let stats: SnapshotStore.ResponseStats

    var body: some View {
        if stats.hasData {
            HStack(spacing: 8) {
                if let seconds = stats.lastDetectionSeconds {
                    stat(icon: "bolt.fill", tint: Theme.info,
                         value: "\(seconds)s", label: "to detect")
                }
                stat(icon: "bell.badge.fill", tint: Theme.warn,
                     value: "\(stats.alertsToday)", label: "alerts today")
                if let median = stats.medianRecoveryMinutes {
                    stat(icon: "arrow.uturn.backward.circle.fill", tint: Theme.ok,
                         value: "\(median)m", label: "median recovery")
                }
            }
        }
    }

    private func stat(icon: String, tint: Color, value: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.panelStroke, lineWidth: 1)
                )
        )
    }
}
