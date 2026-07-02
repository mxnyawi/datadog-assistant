import Foundation
import AppKit
import UserNotifications

/// Actionable alert/recovery notifications. Mute and open happen from the
/// banner itself — no panel round-trip — which is the fastest
/// notification-to-mitigation path macOS offers.
///
/// UNUserNotificationCenter requires a real .app bundle; under bare
/// `swift run` this silently disables itself instead of crashing.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private static let alertCategory = "MONITOR_ALERT"
    private static let recoveryCategory = "MONITOR_RECOVERY"
    private static let muteAction = "MUTE_1H"
    private static let openAction = "OPEN_DD"

    /// Set by AppDelegate; called when the user taps "Mute 1h" on a banner.
    var onMuteRequest: ((Int) -> Void)?

    private(set) var available = false

    func setup() {
        // Bundle.main.bundleIdentifier is nil for a bare SwiftPM executable —
        // UNUserNotificationCenter would throw an ObjC exception.
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundlePath.hasSuffix(".app") else {
            NSLog("NotificationManager: not running from a .app bundle; notifications disabled")
            return
        }
        available = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let mute = UNNotificationAction(
            identifier: Self.muteAction, title: "Mute 1h", options: [])
        let open = UNNotificationAction(
            identifier: Self.openAction, title: "Open in Datadog",
            options: [.foreground])

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.alertCategory,
                actions: [open, mute], intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: Self.recoveryCategory,
                actions: [open], intentIdentifiers: [], options: []),
        ])

        // .criticalAlert is requested but only granted once Apple approves the
        // com.apple.developer.usernotifications.critical-alerts entitlement;
        // until then P1s use .defaultCritical sound at normal interruption level.
        center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert]) { _, _ in }
    }

    /// When each monitor was last notified about, for the re-notify nag.
    private var lastNotified: [Int: Date] = [:]

    func deliver(transitions: [SnapshotStore.Transition]) {
        guard available else { return }
        let settings = NotificationSettings.load()
        guard settings.enabled else { return }
        let center = UNUserNotificationCenter.current()
        for transition in transitions {
            let monitor = transition.monitor
            let content = UNMutableNotificationContent()
            var wantsSound = false
            switch transition.kind {
            case .fired:
                content.title = "\(monitor.priority.label) · \(monitor.name)"
                content.body = monitor.triggeredHosts.isEmpty
                    ? "Alerting"
                    : "Alerting on \(monitor.triggeredHosts.joined(separator: ", "))"
                content.categoryIdentifier = Self.alertCategory
                content.sound = Self.sound(settings, critical: monitor.priority <= .p2)
                if #available(macOS 12.0, *) {
                    content.interruptionLevel = monitor.priority <= .p2 ? .timeSensitive : .active
                }
                wantsSound = true
                lastNotified[monitor.id] = Date()
            case .warned:
                guard settings.notifyOnWarn else { continue }
                content.title = "Warning · \(monitor.name)"
                content.body = monitor.triggeredHosts.isEmpty
                    ? "Entered warning"
                    : "Warning on \(monitor.triggeredHosts.joined(separator: ", "))"
                content.categoryIdentifier = Self.alertCategory
                content.sound = Self.sound(settings, critical: false)
                wantsSound = true
                lastNotified[monitor.id] = Date()
            case .recovered:
                guard settings.notifyOnRecovery else { continue }
                content.title = "Recovered · \(monitor.name)"
                content.body = "Back to OK"
                content.categoryIdentifier = Self.recoveryCategory
                content.sound = nil
                lastNotified.removeValue(forKey: monitor.id)
            }
            content.userInfo = [
                "monitorID": monitor.id,
                "url": monitor.url?.absoluteString ?? "",
            ]
            if wantsSound { Self.playCustomSound(settings) }
            center.add(UNNotificationRequest(
                identifier: "monitor-\(monitor.id)-\(transition.kind)",
                content: content, trigger: nil))
        }
    }

    /// The "still alerting" nag: re-notify for monitors that stay red past
    /// the configured interval. Called on every poll (never while snoozed).
    func nag(alerting: [Monitor]) {
        guard available else { return }
        let settings = NotificationSettings.load()
        guard settings.enabled, settings.renotifyMinutes > 0 else { return }
        let interval = TimeInterval(settings.renotifyMinutes * 60)
        let center = UNUserNotificationCenter.current()
        let now = Date()
        for monitor in alerting {
            let last = lastNotified[monitor.id] ?? monitor.firingSince ?? now
            guard now.timeIntervalSince(last) >= interval else { continue }
            lastNotified[monitor.id] = now
            let content = UNMutableNotificationContent()
            content.title = "Still alerting · \(monitor.name)"
            content.body = monitor.firingDuration.map { "Firing for \($0)" } ?? "Still firing"
            content.categoryIdentifier = Self.alertCategory
            content.sound = Self.sound(settings, critical: monitor.priority <= .p2)
            content.userInfo = [
                "monitorID": monitor.id,
                "url": monitor.url?.absoluteString ?? "",
            ]
            Self.playCustomSound(settings)
            center.add(UNNotificationRequest(
                identifier: "monitor-\(monitor.id)-nag-\(Int(now.timeIntervalSince1970))",
                content: content, trigger: nil))
        }
    }

    /// The notification's own sound. When the user picked a named system
    /// sound we attach silence here and play it via NSSound instead —
    /// UNNotificationSound can't reliably reach /System/Library/Sounds.
    private static func sound(_ settings: NotificationSettings, critical: Bool)
        -> UNNotificationSound? {
        guard settings.soundEnabled else { return nil }
        guard settings.soundName.isEmpty else { return nil }
        return critical ? .defaultCritical : .default
    }

    private static func playCustomSound(_ settings: NotificationSettings) {
        guard settings.soundEnabled, !settings.soundName.isEmpty else { return }
        NSSound(named: settings.soundName)?.play()
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        switch response.actionIdentifier {
        case Self.muteAction:
            if let id = info["monitorID"] as? Int { onMuteRequest?(id) }
        case Self.openAction, UNNotificationDefaultActionIdentifier:
            if let raw = info["url"] as? String, let url = URL(string: raw), !raw.isEmpty {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension SnapshotStore.Transition.Kind: CustomStringConvertible {
    var description: String {
        switch self {
        case .fired: return "fired"
        case .warned: return "warned"
        case .recovered: return "recovered"
        }
    }
}
