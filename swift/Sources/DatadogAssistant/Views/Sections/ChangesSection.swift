import SwiftUI
import AppKit

/// The Changes tab: GitHub merges + Datadog deploy events, newest first, with
/// suspects (changes that landed just before an alert started) called out.
struct ChangesSection: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent changes")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.leading, 2)

            if snapshot.deploys.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(snapshot.deploys.prefix(8)) { deploy in
                        DeployRow(deploy: deploy, monitors: snapshot.monitors)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No changes in the last 6h.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Text("Feeds: Datadog events tagged \"deployment\" + merged PRs from repos configured in Settings.")
                .font(.system(size: 10))
                .foregroundColor(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

struct DeployRow: View {
    let deploy: DeployEvent
    let monitors: [Monitor]

    private var isSuspect: Bool { !deploy.suspectFor.isEmpty }

    var body: some View {
        Button {
            if let url = deploy.url { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    sourceIcon
                    Text(deploy.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text(deploy.relativeTime)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(Theme.textMuted)
                }
                if isSuspect {
                    suspectBadge
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSuspect ? Theme.alert.opacity(0.10) : Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSuspect ? Theme.alert.opacity(0.40) : Theme.panelStroke,
                                    lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sourceIcon: some View {
        Image(systemName: deploy.source == .github
              ? "arrow.triangle.pull"
              : "shippingbox.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(isSuspect ? Theme.alert : Theme.textSecondary)
    }

    private var suspectBadge: some View {
        let names = deploy.suspectFor
            .compactMap { id in monitors.first { $0.id == id }?.name }
            .prefix(2)
        return HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("landed before: \(names.joined(separator: " · "))")
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(Theme.alert)
    }
}
