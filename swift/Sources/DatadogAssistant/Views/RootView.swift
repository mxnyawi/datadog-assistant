import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: SnapshotStore
    @State private var tab: Tab = .monitors

    var body: some View {
        let snapshot = store.snapshot
        let suspectCount = snapshot.deploys.filter { !$0.suspectFor.isEmpty }.count
            + snapshot.ciRuns.filter { $0.state == .failure }.count
        VStack(spacing: 16) {
            HeaderView(snapshot: snapshot)
            TabStrip(selected: $tab, badges: [.changes: suspectCount])

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    switch tab {
                    case .monitors:
                        let hero = snapshot.alerting
                            .sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
                            .first { $0.priority <= .p2 }
                        ClusterChips(clusters: snapshot.clusters)
                        if let hero {
                            HeroAlertCard(monitor: hero)
                        }
                        StateSection(snapshot: snapshot)
                        ResponseStrip(stats: store.stats)
                        Divider().background(Theme.panelStroke)
                        ActiveMonitorsSection(snapshot: snapshot, excluding: hero?.id)
                        Divider().background(Theme.panelStroke)
                        IncidentsSection(snapshot: snapshot)
                        Divider().background(Theme.panelStroke)
                        ActivitySection(snapshot: snapshot)
                    case .changes:
                        ChangesSection(snapshot: snapshot)
                    case .snooze:
                        SnoozeSection()
                    case .tools:
                        ToolsSection()
                    case .list:
                        MonitorListSection(snapshot: snapshot)
                    }
                }
                .padding(.vertical, 4)
            }

            if let error = store.lastError {
                errorBar(error)
            }
            FreshnessBar()
            FooterView(tab: $tab)
        }
        .padding(16)
        .frame(width: 380)
        .background(Color.clear)   // glass comes from the NSVisualEffectView behind us
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: snapshot)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(2)
        }
        .foregroundColor(Theme.warn)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.warn.opacity(0.12))
        )
    }
}

/// "Checked 4s ago · next in 15s · ⌥⌘D" — the polling cadence is the latency
/// floor for on-call response, so it's shown, not hidden.
struct FreshnessBar: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text(freshnessText(now: context.date))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                Spacer()
                Text("⌥⌘D")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundColor(Theme.textMuted)
            }
            .foregroundColor(Theme.textMuted)
        }
        .frame(height: 14)
    }

    private func freshnessText(now: Date) -> String {
        guard store.snapshot.lastRefresh != .distantPast else { return "connecting…" }
        let age = max(0, Int(now.timeIntervalSince(store.snapshot.lastRefresh)))
        let cadence = Int(store.currentInterval)
        if store.refreshing { return "checking now…" }
        return "checked \(age)s ago · every \(cadence)s"
    }
}
