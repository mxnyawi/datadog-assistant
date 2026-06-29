import SwiftUI

struct HeaderView: View {
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                Text("🐶")
                    .font(.system(size: 24))
            }
            .frame(width: 48, height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Theme.panelStroke, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text("Datadog Assistant")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.textPrimary)
                HStack(spacing: 5) {
                    Circle()
                        .fill(snapshot.connected ? Theme.ok : Theme.muted)
                        .frame(width: 7, height: 7)
                    Text(snapshot.connected ? snapshot.orgName : "Disconnected")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(snapshot.connected ? Theme.ok : Theme.muted)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(
                    Capsule().fill((snapshot.connected ? Theme.ok : Theme.muted).opacity(0.15))
                )
            }
            Spacer()
        }
    }
}
