import AppKit
import SwiftUI
import Combine

/// Owns the NSStatusItem and an NSPopover whose content is RootView. The
/// status-bar title flips between 🐶 (all clear) and "‼️ N" (something firing)
/// the same way the Python app does today.
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let dataSource: MockDataSource
    private var subscriptions = Set<AnyCancellable>()
    private var eventMonitor: Any?

    init(dataSource: MockDataSource) {
        self.dataSource = dataSource
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 620)
        popover.contentViewController = NSHostingController(
            rootView: RootView().environmentObject(dataSource)
        )

        if let button = statusItem.button {
            button.title = "🐶"
            button.action = #selector(toggle(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        dataSource.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snap in self?.refreshTitle(snap) }
            .store(in: &subscriptions)
    }

    private func refreshTitle(_ snap: Snapshot) {
        guard let button = statusItem.button else { return }
        let count = snap.alerting.count
        button.title = count == 0 ? "🐶" : "‼️ \(count)"
    }

    @objc private func toggle(_ sender: AnyObject?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startDismissMonitor()
        }
    }

    private func startDismissMonitor() {
        stopDismissMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func stopDismissMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func popoverDidClose(_ notification: Notification) {
        stopDismissMonitor()
    }
}
