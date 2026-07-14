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
        // Wire up Edit-menu shortcuts (⌘V/⌘X/⌘C/⌘A) — an accessory app has no
        // menu bar, so text fields can't paste without this.
        MainMenu.install()

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Polling Datadog monitors")

        let credentials = Credentials.load()
        let source: DataSource = credentials
            .map { DatadogClient(credentials: $0) } ?? MockDataSource()
        store = SnapshotStore(source: source)
        store.needsSetup = Self.needsSetup(credentials: credentials)

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
            NotificationManager.shared.maybeDigest(snapshot: snapshot)
        }

        store.start()
        menuBar = MenuBarController(store: store)
        hotKey = HotKey { [weak self] in self?.menuBar.togglePanel() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .openSettingsWindow, object: nil)
        // The in-panel connect prompt (and Settings) post this after saving
        // credentials or choosing sample data.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadCredentials),
            name: .reloadCredentials, object: nil)
    }

    /// Show the connect prompt when there's nothing to show real data with and
    /// the user hasn't explicitly chosen sample mode — better than silently
    /// pretending sample data is their org.
    private static func needsSetup(credentials: Credentials?) -> Bool {
        credentials == nil && AuthMode.current != .sample
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController {
                NotificationCenter.default.post(name: .reloadCredentials, object: nil)
            }
        }
        settingsController?.show()
    }

    @objc private func reloadCredentials() {
        let credentials = Credentials.load()
        let source: DataSource = credentials
            .map { DatadogClient(credentials: $0) } ?? MockDataSource()
        store.replaceSource(source)
        store.needsSetup = Self.needsSetup(credentials: credentials)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
