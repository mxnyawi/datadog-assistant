import AppKit
import SwiftUI
import Combine
import QuartzCore

/// Owns the NSStatusItem and the FloatingPanel. The status item is a template
/// pawprint that adapts to menu bar appearance, with a red monospaced count
/// beside it while anything is alerting — the Vorssaint treatment of the
/// Python app's 🐶/‼️ flip.
@MainActor
final class MenuBarController: NSObject {
    private static let panelSize = NSSize(width: 360, height: 600)

    private let statusItem: NSStatusItem
    private let panel: FloatingPanel
    private let store: SnapshotStore
    private let prefs = UIPreferences.shared
    private var subscriptions = Set<AnyCancellable>()
    private var dismissMonitor: Any?
    /// Last count shown in the badge — so a *rising* count can pulse while a
    /// falling one (recoveries) stays calm.
    private var lastBadgeCount = 0
    /// False until the first badge render, so pre-existing cached alerts at
    /// launch don't flash the icon.
    private var hasRenderedBadge = false
    /// Kept so a badge-mode change in Settings can re-render without waiting
    /// for the next poll.
    private var lastSnapshot: Snapshot = .empty

    init(store: SnapshotStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let host = NSHostingView(rootView: RootView().environmentObject(store))
        self.panel = FloatingPanel(contentView: host, size: Self.panelSize)
        super.init()
        panel.onDismiss = { [weak self] in self?.hidePanel() }

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "pawprint.fill",
                accessibilityDescription: "Datadog Assistant")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        store.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in self?.refreshBadge(snap) }
            .store(in: &subscriptions)
        // A badge-mode change (Settings → Appearance) should re-count the
        // current snapshot immediately, not after the next poll.
        prefs.$badgeMode
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // A mode switch re-counts the same snapshot; never a "new alert".
                self.refreshBadge(self.lastSnapshot, allowPulse: false)
            }
            .store(in: &subscriptions)
    }

    // MARK: - Status item

    private func refreshBadge(_ snapshot: Snapshot, allowPulse: Bool = true) {
        lastSnapshot = snapshot
        guard let button = statusItem.button else { return }
        let count = prefs.badgeMode.count(in: snapshot)
        // Pulse only for a genuine new alert — a rising count from fresh data,
        // not the first render after launch (cached alerts) or a mode switch.
        if allowPulse, hasRenderedBadge, count > lastBadgeCount, prefs.pulseOnAlert {
            pulse(button)
        }
        hasRenderedBadge = true
        lastBadgeCount = count
        if count > 0 {
            button.attributedTitle = NSAttributedString(
                string: " \(count)",
                attributes: [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold),
                ])
        } else {
            button.title = ""
        }
    }

    /// A single quick dim-and-restore of the status item — enough to catch the
    /// eye when a new alert lands. Skipped under Reduce Motion.
    private func pulse(_ button: NSStatusBarButton) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        button.alphaValue = 0.25
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.animator().alphaValue = 1
        }
    }

    @objc private func statusItemClicked(_ sender: AnyObject?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePanel()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
            .target = self
        menu.addItem(withTitle: "Open Datadog", action: #selector(openDatadog), keyEquivalent: "")
            .target = self

        // Snooze all — the same API-downtime snooze the panel offers, without
        // opening it. A "Wake" item appears instead while a snooze is live.
        menu.addItem(.separator())
        if store.isSnoozed {
            menu.addItem(withTitle: "Wake (cancel snooze)", action: #selector(wake), keyEquivalent: "")
                .target = self
        } else {
            let snooze = NSMenuItem(title: "Snooze all", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (title, seconds) in [("30 minutes", 1800), ("1 hour", 3600),
                                     ("4 hours", 4 * 3600), ("Rest of the day", restOfDaySeconds())] {
                let item = NSMenuItem(title: title, action: #selector(snoozeFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = seconds
                submenu.addItem(item)
            }
            snooze.submenu = submenu
            menu.addItem(snooze)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Quit Datadog Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // detach so left-click keeps toggling the panel
    }

    /// Seconds from now until midnight — the "rest of the day" snooze.
    private func restOfDaySeconds() -> Int {
        let calendar = Calendar.current
        guard let end = calendar.nextDate(after: Date(),
                                          matching: DateComponents(hour: 0, minute: 0),
                                          matchingPolicy: .nextTime) else { return 4 * 3600 }
        return max(1800, Int(end.timeIntervalSinceNow))
    }

    @objc private func refreshNow() {
        Task { await store.refresh() }
    }

    @objc private func openDatadog() {
        LinkOpener.open(Credentials.currentAppBaseURL().appendingPathComponent("/monitors/manage"))
    }

    @objc private func snoozeFromMenu(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        Task { await store.snoozeAll(for: TimeInterval(seconds)) }
    }

    @objc private func wake() {
        Task { await store.cancelSnooze() }
    }

    @objc private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
    }

    // MARK: - Panel

    func togglePanel() {
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        positionPanel()
        // Materialize with a quick fade instead of popping in — respects
        // Reduce Motion (appears instantly then).
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        startDismissMonitor()
        NotificationCenter.default.post(name: .panelDidShow, object: nil)
        Task { await store.refresh() }   // fresh data behind the instant cached render
    }

    private func hidePanel() {
        panel.orderOut(nil)
        stopDismissMonitor()
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            // Hotkey path with no visible status item (unlikely): center on screen.
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.midX - Self.panelSize.width / 2,
                    y: screen.visibleFrame.midY))
            }
            return
        }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(
            x: buttonFrame.midX - Self.panelSize.width / 2,
            y: buttonFrame.minY - Self.panelSize.height - 8)
        if let screen = buttonWindow.screen {
            origin.x = max(screen.visibleFrame.minX + 8,
                           min(origin.x, screen.visibleFrame.maxX - Self.panelSize.width - 8))
            origin.y = max(screen.visibleFrame.minY + 8, origin.y)
        }
        panel.setFrameOrigin(origin)
    }

    private func startDismissMonitor() {
        stopDismissMonitor()
        dismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            // Pinned: the user asked the panel to stay put (e.g. parked on a
            // second display). Only the menu-bar icon or Esc closes it.
            if self.prefs.pinned { return }
            // While the connect prompt is up, don't dismiss on outside clicks —
            // the user has to switch to a browser/password manager to copy the
            // token, and that click shouldn't hide the panel out from under
            // them. They can still close it with the menu bar icon or Esc.
            if self.store.needsSetup { return }
            self.hidePanel()
        }
    }

    private func stopDismissMonitor() {
        if let monitor = dismissMonitor {
            NSEvent.removeMonitor(monitor)
            dismissMonitor = nil
        }
    }
}

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
    /// Posted after credentials are saved or sample mode is chosen, so the
    /// AppDelegate rebuilds the data source and refreshes the setup state.
    static let reloadCredentials = Notification.Name("reloadCredentials")
    /// Posted when the panel is shown, so the root view can reset transient
    /// state (the command palette) for a fresh open.
    static let panelDidShow = Notification.Name("panelDidShow")
}
