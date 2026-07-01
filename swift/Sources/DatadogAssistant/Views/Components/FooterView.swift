import SwiftUI
import AppKit

struct FooterView: View {
    var body: some View {
        HStack(spacing: 0) {
            footerButton(icon: "gearshape", label: "Settings", action: openSettings)
            Divider().frame(height: 22).background(Theme.panelStroke)
            footerButton(icon: "list.bullet", label: "List", action: openList)
            Divider().frame(height: 22).background(Theme.panelStroke)
            footerButton(icon: "power", label: "Quit", action: quit)
        }
        .padding(.top, 6)
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    // Full monitor list stays in Datadog until the in-panel list view lands.
    private func openList() {
        NSWorkspace.shared.open(URL(string: "https://app.datadoghq.com/monitors/manage")!)
    }

    private func quit() { NSApp.terminate(nil) }
}
