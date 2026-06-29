import SwiftUI

struct ActiveMonitorsSection: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active monitors")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.leading, 2)

            let active = (snapshot.alerting + snapshot.warning).prefix(4)
            if active.isEmpty {
                emptyState
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
