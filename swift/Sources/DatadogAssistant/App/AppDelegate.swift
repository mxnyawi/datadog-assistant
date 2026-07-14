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

        // The store starts on the disk-cached snapshot so the panel renders
        // instantly; the real source arrives once credentials resolve.
        // Credentials.load() can shell out (lpass, password-manager commands)
        // for tens of seconds — never on the main thread.
        store = SnapshotStore(source: MockDataSource())
        Task { [weak self] in
            let credentials = await Task.detached { Credentials.load() }.value
            guard let self else { return }
            let source: DataSource = credentials
                .map { DatadogClient(credentials: $0) } ?? MockDataSource()
            self.store.adoptInitialSource(source)
            self.store.needsSetup = Self.needsSetup(credentials: credentials)
        }

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
        // SnapshotStore never fires these for sample data — no notifications,
        // no nags, no auto-created Jira tickets from generated monitors.
        store.onTransitions = { transitions in
            NotificationManager.shared.deliver(transitions: transitions)
            JiraAutoCreate.handle(transitions)
        }
        store.onPoll = { snapshot in
            NotificationManager.shared.nag(alerting: snapshot.alerting)
            NotificationManager.shared.maybeDigest(snapshot: snapshot)
        }

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

    /// Show the connect prompt only in device mode with no stored credential —
    /// the fresh-install case. A LastPass-configured install with a locked
    /// vault keeps the normal panel (it just needs `lpass login`, reachable
    /// from Settings), and sample mode is an explicit choice; neither should be
    /// told to "paste a token."
    private static func needsSetup(credentials: Credentials?) -> Bool {
        credentials == nil && AuthMode.current == .device
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(
                onSave: {
                    NotificationCenter.default.post(name: .reloadCredentials, object: nil)
                },
                monitoredServices: { [weak self] in
                    guard let self else { return [] }
                    return Array(Set(self.store.snapshot.monitors.compactMap { $0.service })).sorted()
                })
        }
        settingsController?.show()
    }

    @objc private func reloadCredentials() {
        Task { [weak self] in
            let credentials = await Task.detached { Credentials.load() }.value
            guard let self else { return }
            let source: DataSource = credentials
                .map { DatadogClient(credentials: $0) } ?? MockDataSource()
            self.store.replaceSource(source)
            self.store.needsSetup = Self.needsSetup(credentials: credentials)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }
}
