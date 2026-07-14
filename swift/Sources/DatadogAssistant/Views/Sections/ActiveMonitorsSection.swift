import SwiftUI

struct ActiveMonitorsSection: View {
    let snapshot: Snapshot
    /// Monitor already shown as the hero card; kept out of the row list.
    var excluding: Int? = nil

    var body: some View {
        // DLQ monitors live in their own section (exclusive grouping).
        let dlqExclusive = DLQConfig.load().exclusive
        let active = (snapshot.alerting + snapshot.warning)
            .filter { $0.id != excluding && !(dlqExclusive && $0.isDLQ) }
        let shown = active.prefix(4)

        VStack(alignment: .leading, spacing: 6) {
            // Count the real total, not the truncated slice — an on-call
            // reading "4" while 12 fire is a lie.
            SectionHeader(title: excluding == nil ? "Active Monitors" : "Also Firing",
                          count: active.isEmpty ? nil : active.count)

            if active.isEmpty {
                // With a hero card above, an empty remainder needs no state.
                if excluding == nil { emptyState }
            } else {
                InsetCard {
                    ForEach(Array(shown), id: \.id) { MonitorRow(monitor: $0) }
                }
                if active.count > shown.count {
                    Text("+\(active.count - shown.count) more in All Monitors")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                        .padding(.leading, 10)
                }
            }
        }
    }

    /// The native empty state: one quiet line, not an illustration.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(Theme.textSecondary)
            Text("All monitors OK")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}
