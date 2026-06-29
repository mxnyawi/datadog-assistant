import SwiftUI

struct IncidentsSection: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Text("Active incidents")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.leading, 2)

            if snapshot.incidents.isEmpty {
                Text("None open.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .padding(.vertical, 6)
            } else {
                HStack(spacing: 8) {
                    ForEach(snapshot.incidents.prefix(5), id: \.id) {
                        IncidentPill(incident: $0)
                    }
                }
            }
        }
    }
}
