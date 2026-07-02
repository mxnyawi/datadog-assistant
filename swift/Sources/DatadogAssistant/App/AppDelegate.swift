import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController!
    private var store: SnapshotStore!
    private var hotKey: HotKey?
    private var settingsController: SettingsWindowController?
    /// Held for the app's lifetime so App Nap doesn't throttle the poll loop.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Polling Datadog monitors")

        let source: DataSource = Credentials.load()
            .map { DatadogClient(credentials: $0) } ?? MockDataSource()
        store = SnapshotStore(source: source)

        NotificationManager.shared.setup()
        // Arrives on the notification-center delegate queue; hop to the main
        // actor before touching the store.
        NotificationManager.shared.onMuteRequest = { [weak self] monitorID in
            Task { @MainActor in
                guard let self,
                      let monitor = self.store.snapshot.monitors.first(where: { $0.id == monitorID })
                else { return }
                await self.store.mute(monitor, for: 3600)
            }
        }
        store.onTransitions = { transitions in
            NotificationManager.shared.deliver(transitions: transitions)
            JiraAutoCreate.handle(transitions)
        }
        store.onPoll = { snapshot in
            NotificationManager.shared.nag(alerting: snapshot.alerting)
        }

        store.start()
        menuBar = MenuBarController(store: store)
        hotKey = HotKey { [weak self] in self?.menuBar.togglePanel() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettingsWindow, object: nil)
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController { [weak self] in
                self?.reloadCredentials()
            }
        }
        settingsController?.show()
    }

    private func reloadCredentials() {
        let source: DataSource = Credentials.load()
            .map { DatadogClient(credentials: $0) } ?? MockDataSource()
        store.replaceSource(source)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
