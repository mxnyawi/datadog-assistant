import SwiftUI
import AppKit

/// The Tools tab: escape hatches and configuration entry points.
struct ToolsSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Tools")

            toolRow(icon: "gearshape.fill", label: "Settings…",
                    detail: "Credentials, filters, notifications, Jira, GitHub") {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
            toolRow(icon: "arrow.up.forward.square.fill", label: "Open Datadog",
                    detail: "Monitors overview in the browser") {
                LinkOpener.open(
                    Credentials.currentAppBaseURL().appendingPathComponent("/monitors/manage"))
            }
            toolRow(icon: "arrow.clockwise", label: "Refresh now",
                    detail: store.refreshing ? "Checking…" : "Poll immediately") {
                Task { await store.refresh() }
            }

            SectionHeader(title: "Quick Links")
                .padding(.top, 6)
            quickLinks

            if !store.snapshot.dashboards.isEmpty {
                SectionHeader(title: "My Dashboards")
                    .padding(.top, 6)
                ForEach(store.snapshot.dashboards.prefix(8)) { dashboard in
                    linkRow(icon: "chart.bar.xaxis",
                            label: String(dashboard.title.prefix(45))) {
                        if let url = dashboard.url { LinkOpener.open(url) }
                    }
                }
            }
        }
    }

    /// The Python app's quick-links defaults, resolved against the org's
    /// subdomain-aware base URL.
    private static let quickLinkSpecs: [(icon: String, label: String, path: String)] = [
        ("square.grid.2x2.fill", "Dashboards", "/dashboard/lists"),
        ("bell.fill", "Monitors", "/monitors/manage"),
        ("doc.text.fill", "Logs", "/logs"),
        ("point.topleft.down.curvedto.point.bottomright.up.fill", "APM Traces", "/apm/traces"),
        ("flame.fill", "Incidents", "/incidents"),
        ("server.rack", "Infrastructure", "/infrastructure"),
    ]

    private var quickLinks: some View {
        VStack(spacing: 4) {
            ForEach(Array(Self.quickLinkSpecs.enumerated()), id: \.offset) { _, spec in
                linkRow(icon: spec.icon, label: spec.label) {
                    LinkOpener.open(
                        Credentials.currentAppBaseURL().appendingPathComponent(spec.path))
                }
            }
        }
    }

    private func linkRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.info)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.panel)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolRow(icon: String, label: String, detail: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.info)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.panel)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
