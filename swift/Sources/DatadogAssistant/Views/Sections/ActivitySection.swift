import SwiftUI

struct ActivitySection: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Activity")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)

                HStack(spacing: 4) {
                    Circle().fill(pressureColor).frame(width: 7, height: 7)
                    Text(pressureLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(pressureColor)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    Capsule().fill(pressureColor.opacity(0.15))
                )

                Spacer()
                Text("\(snapshot.alerting.count + snapshot.warning.count) firing")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.leading, 2)

            Sparkline(points: snapshot.activity, color: pressureColor, lineWidth: 1.5)
                .frame(height: 40)
                .padding(.top, 2)
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
