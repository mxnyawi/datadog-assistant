import SwiftUI
import AppKit

/// The Tools tab: escape hatches and configuration entry points.
struct ToolsSection: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .padding(.leading, 2)

            toolRow(icon: "gearshape.fill", label: "Settings…",
                    detail: "Credentials, filters, notifications, Jira, GitHub") {
                NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
            }
            toolRow(icon: "arrow.up.forward.square.fill", label: "Open Datadog",
                    detail: "Monitors overview in the browser") {
                NSWorkspace.shared.open(
                    Credentials.currentAppBaseURL().appendingPathComponent("/monitors/manage"))
            }
            toolRow(icon: "arrow.clockwise", label: "Refresh now",
                    detail: store.refreshing ? "Checking…" : "Poll immediately") {
                Task { await store.refresh() }
            }
        }
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.panelStroke, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
