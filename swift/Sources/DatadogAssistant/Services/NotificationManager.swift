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

    func deliver(transitions: [SnapshotStore.Transition]) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        for transition in transitions {
            let monitor = transition.monitor
            let content = UNMutableNotificationContent()
            switch transition.kind {
            case .fired:
                content.title = "\(monitor.priority.label) · \(monitor.name)"
                content.body = monitor.triggeredHosts.isEmpty
                    ? "Alerting"
                    : "Alerting on \(monitor.triggeredHosts.joined(separator: ", "))"
                content.categoryIdentifier = Self.alertCategory
                content.sound = monitor.priority <= .p2
                    ? .defaultCritical
                    : .default
                if #available(macOS 12.0, *) {
                    content.interruptionLevel = monitor.priority <= .p2 ? .timeSensitive : .active
                }
            case .recovered:
                content.title = "Recovered · \(monitor.name)"
                content.body = "Back to OK"
                content.categoryIdentifier = Self.recoveryCategory
                content.sound = nil
            }
            content.userInfo = [
                "monitorID": monitor.id,
                "url": monitor.url?.absoluteString ?? "",
            ]
            center.add(UNNotificationRequest(
                identifier: "monitor-\(monitor.id)-\(transition.kind)",
                content: content, trigger: nil))
        }
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
        case .recovered: return "recovered"
        }
    }
}
