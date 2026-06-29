import SwiftUI

struct StateSection: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alert state")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.leading, 2)

            HStack(spacing: 10) {
                StateCard(icon: "exclamationmark.octagon.fill",
                          title: "Alerting",
                          value: "\(snapshot.alerting.count)",
                          tint: Theme.alert)
                StateCard(icon: "exclamationmark.triangle.fill",
                          title: "Warning",
                          value: "\(snapshot.warning.count)",
                          tint: Theme.warn)
                StateCard(icon: "checkmark.seal.fill",
                          title: "Healthy",
                          value: "\(snapshot.healthy.count)",
                          tint: Theme.ok)
            }
        }
    }
}
