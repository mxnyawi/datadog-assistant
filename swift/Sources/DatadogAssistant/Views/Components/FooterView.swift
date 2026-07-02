import SwiftUI
import AppKit

struct FooterView: View {
    @Binding var tab: Tab

    var body: some View {
        HStack(spacing: 0) {
            footerButton(icon: "gearshape", label: "Settings", action: openSettings)
            Divider().frame(height: 22).background(Theme.panelStroke)
            footerButton(icon: "list.bullet",
                         label: tab == .list ? "Back" : "List",
                         action: toggleList)
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

    private func toggleList() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            tab = tab == .list ? .monitors : .list
        }
    }

    private func quit() { NSApp.terminate(nil) }
}
