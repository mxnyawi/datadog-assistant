import Foundation

/// User-tunable notification behavior, persisted in UserDefaults. Mirrors the
/// Python app's `notifications` config block: master switch, per-kind toggles,
/// sound choice from the system sound library, and the re-notify nag for
/// alerts that stay red.
struct NotificationSettings: Equatable {
    var enabled = true
    var notifyOnWarn = true
    var notifyOnRecovery = true
    var soundEnabled = true
    /// A name from /System/Library/Sounds ("Sosumi", "Glass"…); empty = the
    /// system default notification sound.
    var soundName = ""
    /// Re-alert if a monitor is STILL alerting after N minutes; 0 = off.
    var renotifyMinutes = 30

    static let renotifyChoices = [0, 10, 30, 60, 120]

    private static let key = "notificationSettings"

    static func load() -> NotificationSettings {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: key) else { return NotificationSettings() }
        var settings = NotificationSettings()
        settings.enabled = dict["enabled"] as? Bool ?? true
        settings.notifyOnWarn = dict["notifyOnWarn"] as? Bool ?? true
        settings.notifyOnRecovery = dict["notifyOnRecovery"] as? Bool ?? true
        settings.soundEnabled = dict["soundEnabled"] as? Bool ?? true
        settings.soundName = dict["soundName"] as? String ?? ""
        settings.renotifyMinutes = dict["renotifyMinutes"] as? Int ?? 30
        return settings
    }

    func save() {
        UserDefaults.standard.set([
            "enabled": enabled,
            "notifyOnWarn": notifyOnWarn,
            "notifyOnRecovery": notifyOnRecovery,
            "soundEnabled": soundEnabled,
            "soundName": soundName,
            "renotifyMinutes": renotifyMinutes,
        ] as [String: Any], forKey: Self.key)
    }

    /// The system alert sounds available for the picker, e.g. Sosumi, Glass,
    /// Hero, Submarine…
    static func availableSounds() -> [String] {
        let dir = "/System/Library/Sounds"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return names
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(".aiff".count)) }
            .sorted()
    }
}
