import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: SnapshotStore
    @State private var tab: Tab = .monitors
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if store.needsSetup {
            setupBody
        } else {
            dashboardBody
        }
    }

    /// The connect prompt, shown when there are no usable credentials.
    private var setupBody: some View {
        VStack(spacing: 12) {
            ConnectPromptView()
            Spacer(minLength: 0)
            FooterView(tab: $tab)
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(width: 360)
    }

    private var dashboardBody: some View {
        let snapshot = store.snapshot
        let suspectCount = snapshot.deploys.filter { !$0.suspectFor.isEmpty }.count
            + snapshot.ciRuns.filter { $0.state == .failure }.count
        return VStack(spacing: 10) {
            // Pinned: identity + summary stay put; only the content scrolls.
            HeaderView()
            TabStrip(selected: $tab, badges: [.changes: suspectCount])

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    switch tab {
                    case .monitors:
                        let hero = snapshot.alerting
                            .sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
                            .first { $0.priority <= .p2 }
                        FilterBar()
                        ClusterChips(clusters: snapshot.clusters)
                        if let hero {
                            HeroAlertCard(monitor: hero)
                        }
                        StateSection(snapshot: snapshot, tab: $tab)
                        FavoritesSection(snapshot: snapshot)
                        DLQSection(snapshot: snapshot)
                        ActiveMonitorsSection(snapshot: snapshot, excluding: hero?.id)
                        IncidentsSection(snapshot: snapshot)
                        ResponseStrip(stats: store.stats)
                        ActivitySection(snapshot: snapshot)
                    case .changes:
                        ChangesSection(snapshot: snapshot)
                    case .snooze:
                        SnoozeSection()
                    case .tools:
                        ToolsSection()
                    case .list:
                        FilterBar()
                        MonitorListSection(snapshot: snapshot)
                    }
                }
                .padding(.vertical, 2)
            }

            if let error = store.lastError {
                errorBar(error)
            }
            FooterView(tab: $tab)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 360)
        .background(Color.clear)   // material comes from the NSVisualEffectView behind us
        .animatedContent(snapshot, reduceMotion: reduceMotion)
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 10, weight: .semibold))
            Text(message)
                .font(.system(size: 11, weight: .medium))
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
