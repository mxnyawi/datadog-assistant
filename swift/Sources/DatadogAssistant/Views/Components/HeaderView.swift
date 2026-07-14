import SwiftUI

/// Compact pinned header, Control-Center style: connection state + org name
/// on the left, refresh on the right. The old 48pt branding block spent the
/// panel's most valuable pixels on a logo; identity now lives in the About
/// and onboarding windows instead.
struct HeaderView: View {
    @EnvironmentObject var store: SnapshotStore
    let snapshot: Snapshot

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(snapshot.connected ? Theme.ok : Theme.muted)
                .frame(width: 8, height: 8)
                .accessibilityLabel(snapshot.connected ? "Connected" : "Reconnecting")

            Text(snapshot.connected ? snapshot.orgName : "Reconnecting…")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)

            if snapshot.sampleData {
                Text("SAMPLE")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.info)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.info.opacity(0.15)))
                    .help("No credentials configured — showing sample data. Connect in Settings.")
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                    .opacity(store.refreshing ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(store.refreshing)
            .help("Refresh now")

            Button {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Settings…")
        }
        .padding(.horizontal, 2)
    }
}
