import SwiftUI
import AppKit

/// Pinned footer: polling freshness on top (the cadence is the latency floor
/// for on-call response, so it's shown, not hidden), then the three utility
/// actions every menu-bar app ends with.
struct FooterView: View {
    @Binding var tab: Tab

    var body: some View {
        VStack(spacing: 4) {
            FreshnessBar()
            HStack(spacing: 0) {
                footerButton(icon: "gearshape", label: "Settings", action: openSettings)
                footerButton(icon: "list.bullet",
                             label: tab == .list ? "Back" : "All monitors",
                             action: toggleList)
                footerButton(icon: "power", label: "Quit", action: quit)
            }
        }
        .padding(.top, 2)
    }

    private func footerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        HoverButton(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(Theme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 26)
        }
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

/// "Checked 4s ago · every 15s" + the global hotkey reminder.
struct FreshnessBar: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Text(freshnessText(now: context.date))
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                Spacer()
                Text("⌥⌘D")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(Theme.textMuted)
        }
        .frame(height: 13)
        .padding(.horizontal, 2)
    }

    private func freshnessText(now: Date) -> String {
        guard store.snapshot.lastRefresh != .distantPast else { return "connecting…" }
        let age = max(0, Int(now.timeIntervalSince(store.snapshot.lastRefresh)))
        let cadence = Int(store.currentInterval)
        if store.refreshing { return "checking now…" }
        return "checked \(age)s ago · every \(cadence)s"
    }
}

/// A plain button that paints the standard window-panel hover highlight
/// behind its label — menus give this for free; window panels must roll
/// their own, or rows don't feel clickable.
struct HoverButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? Theme.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
