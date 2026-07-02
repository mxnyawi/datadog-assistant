import SwiftUI

struct ActiveMonitorsSection: View {
    let snapshot: Snapshot
    /// Monitor already shown as the hero card; kept out of the row list.
    var excluding: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(excluding == nil ? "Active monitors" : "Also firing")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.leading, 2)

            // DLQ monitors live in their own section (exclusive grouping).
            let dlqExclusive = DLQConfig.load().exclusive
            let active = (snapshot.alerting + snapshot.warning)
                .filter { $0.id != excluding && !(dlqExclusive && $0.isDLQ) }
                .prefix(4)
            if active.isEmpty {
                // With a hero card above, an empty remainder needs no state.
                if excluding == nil { emptyState }
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(active), id: \.id) { MonitorRow(monitor: $0) }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(Theme.ok)
            Text("Nothing firing.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
        }
        .padding(.vertical, 8)
    }
}
