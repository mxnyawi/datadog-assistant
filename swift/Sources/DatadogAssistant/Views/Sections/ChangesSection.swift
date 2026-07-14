import SwiftUI
import AppKit

/// The Changes tab: GitHub merges + Datadog deploy events, newest first, with
/// suspects (changes that landed just before an alert started) called out.
struct ChangesSection: View {
    let snapshot: Snapshot
    @State private var gitHubStatus: GitHubSetupStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let gitHubStatus, gitHubStatus != .ready {
                gitHubHint(gitHubStatus)
            }
            if !snapshot.ciRuns.isEmpty {
                SectionHeader(title: "CI — Latest Runs", count: snapshot.ciRuns.count)
                VStack(spacing: 4) {
                    ForEach(snapshot.ciRuns.prefix(4)) { CIRunRow(run: $0) }
                }
                .padding(.bottom, 6)
            }

            SectionHeader(title: "Recent Changes",
                          count: snapshot.deploys.isEmpty ? nil : snapshot.deploys.count)

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
        .task {
            // `gh auth token` shells out, so resolve the status off the main
            // thread when the tab appears.
            gitHubStatus = await Task.detached { GitHubConfig.setupStatus() }.value
        }
    }

    /// Guidance when GitHub deploys can't be pulled — most importantly, telling
    /// the user to `gh auth login` so the app can borrow the CLI's token.
    private func hintText(_ status: GitHubSetupStatus) -> String {
        switch status {
        case .needsAuth:
            return "GitHub repos are configured but you're not signed in. "
                + "Run  gh auth login  in Terminal to pull deploys from your repos."
        case .needsRepos:
            return "Signed in to GitHub. Add the repos behind your monitored services "
                + "in Settings → GitHub to see their deploys here."
        default:
            return "Correlate deploys with alerts: run  gh auth login  in Terminal, "
                + "then add your repos in Settings → GitHub."
        }
    }

    @ViewBuilder private func gitHubHint(_ status: GitHubSetupStatus) -> some View {
        let text = hintText(status)
        let showsSettings = status != .needsAuth   // needsAuth is a terminal step, not a Settings one
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.triangle.pull")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.info)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showsSettings {
                    Button("Open GitHub settings") {
                        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
                    }
                    .buttonStyle(.pressable)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.info)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.info.opacity(0.10))
        )
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

struct CIRunRow: View {
    let run: CIRun

    private var tint: Color {
        switch run.state {
        case .success: return Theme.ok
        case .failure: return Theme.alert
        case .running: return Theme.warn
        case .other:   return Theme.muted
        }
    }

    private var symbol: String {
        switch run.state {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .running: return "circle.dotted"
        case .other:   return "minus.circle"
        }
    }

    var body: some View {
        Button {
            if let url = run.url { LinkOpener.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(run.workflow)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(run.repo + (run.branch.map { " · \($0)" } ?? ""))
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Text(run.relativeTime)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(run.state == .failure ? tint : Theme.textMuted)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(run.state == .failure ? Theme.alert.opacity(0.10) : Theme.panel)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }
}

struct DeployRow: View {
    let deploy: DeployEvent
    let monitors: [Monitor]

    private var isSuspect: Bool { !deploy.suspectFor.isEmpty }

    var body: some View {
        Button {
            if let url = deploy.url { LinkOpener.open(url) }
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSuspect ? Theme.alert.opacity(0.10) : Theme.panel)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
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
