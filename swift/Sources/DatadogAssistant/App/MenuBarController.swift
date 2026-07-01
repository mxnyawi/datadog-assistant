import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem and the FloatingPanel. The status item is a template
/// pawprint that adapts to menu bar appearance, with a red monospaced count
/// beside it while anything is alerting — the Vorssaint treatment of the
/// Python app's 🐶/‼️ flip.
@MainActor
final class MenuBarController: NSObject {
    private static let panelSize = NSSize(width: 380, height: 640)

    private let statusItem: NSStatusItem
    private let panel: FloatingPanel
    private let store: SnapshotStore
    private var subscriptions = Set<AnyCancellable>()
    private var dismissMonitor: Any?

    init(store: SnapshotStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let host = NSHostingView(rootView: RootView().environmentObject(store))
        self.panel = FloatingPanel(contentView: host, size: Self.panelSize)
        super.init()

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
    }

    // MARK: - Status item

    private func refreshBadge(_ snapshot: Snapshot) {
        guard let button = statusItem.button else { return }
        let count = snapshot.alerting.count
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
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Datadog Assistant", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // detach so left-click keeps toggling the panel
    }

    @objc private func refreshNow() {
        Task { await store.refresh() }
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
        panel.makeKeyAndOrderFront(nil)
        startDismissMonitor()
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
            self?.hidePanel()
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
}
