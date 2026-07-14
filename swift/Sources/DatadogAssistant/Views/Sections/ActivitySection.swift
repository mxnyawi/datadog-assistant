import SwiftUI

struct ActivitySection: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader(title: "Activity")
                HStack(spacing: 4) {
                    Circle().fill(pressureColor).frame(width: 7, height: 7)
                    Text(pressureLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(pressureColor)
                }
                Text("\(snapshot.alerting.count + snapshot.warning.count) firing")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
            }

            InsetCard {
                Sparkline(points: snapshot.activity, color: pressureColor, lineWidth: 1.5)
                    .frame(height: 36)
                    .padding(6)
            }
        }
    }

    private var pressureColor: Color {
        if !snapshot.alerting.isEmpty { return Theme.alert }
        if !snapshot.warning.isEmpty { return Theme.warn }
        return Theme.ok
    }

    private var pressureLabel: String {
        if !snapshot.alerting.isEmpty { return "Critical" }
        if !snapshot.warning.isEmpty { return "Elevated" }
        return "Normal"
    }
}
