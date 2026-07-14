import SwiftUI

/// The Snooze tab: org-wide quiet via Datadog downtime (real client) or a
/// local banner mute (sample mode). The panel stays live either way — snooze
/// silences notifications, not visibility.
struct SnoozeSection: View {
    @EnvironmentObject var store: SnapshotStore

    private static let options: [(label: String, duration: TimeInterval)] = [
        ("30 min", 30 * 60),
        ("1 hour", 3600),
        ("4 hours", 4 * 3600),
        ("Rest of day", 0),   // resolved to end-of-day below
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Snooze All Alerting")

            if store.isSnoozed, let until = store.snoozedUntil {
                activeState(until: until)
            } else {
                VStack(spacing: 8) {
                    ForEach(Self.options, id: \.label) { option in
                        Button {
                            Task { await store.snoozeAll(for: resolved(option.duration)) }
                        } label: {
                            HStack {
                                Image(systemName: "moon.zzz.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(option.label)
                                    .font(.system(size: 12, weight: .semibold))
                                Spacer()
                            }
                            .foregroundColor(Theme.textPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Theme.panel)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("Creates an org-wide Datadog downtime (scope *). Notifications pause; the panel stays live.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activeState(until: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundColor(Theme.info)
                Text("Snoozed until \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
            }
            Button {
                Task { await store.cancelSnooze() }
            } label: {
                Text("Resume alerting now")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.alert)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(
                        Capsule().fill(Theme.alert.opacity(0.14))
                            .overlay(Capsule().stroke(Theme.alert.opacity(0.4), lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.info.opacity(0.10))
        )
    }

    private func resolved(_ duration: TimeInterval) -> TimeInterval {
        guard duration == 0 else { return duration }
        let endOfDay = Calendar.current.startOfDay(for: Date()).addingTimeInterval(24 * 3600)
        return max(60, endOfDay.timeIntervalSinceNow)
    }
}
