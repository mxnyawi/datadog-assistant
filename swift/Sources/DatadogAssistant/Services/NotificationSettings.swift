import Foundation

/// User-tunable notification behavior, persisted in UserDefaults. Mirrors the
/// Python app's `notifications` config block: master switch, per-kind toggles,
/// sound choice from the system sound library, and the re-notify nag for
/// alerts that stay red.
struct NotificationSettings: Equatable {
    enum Style: String, CaseIterable {
        case banner, modal, both
        var includesBanner: Bool { self != .modal }
        var includesModal: Bool { self != .banner }
        var label: String {
            switch self {
            case .banner: return "Banner"
            case .modal: return "Modal popup"
            case .both: return "Both"
            }
        }
    }

    /// Per-priority overrides — the Python app's severity.rules. nil fields
    /// inherit the base setting.
    struct SeverityRule: Equatable {
        var style: Style?
        var renotifyMinutes: Int?
    }

    var enabled = true
    var notifyOnWarn = true
    var notifyOnNoData = true
    var notifyOnRecovery = true
    var style = Style.banner
    var soundEnabled = true
    /// A name from /System/Library/Sounds ("Sosumi", "Glass"…); empty = the
    /// system default notification sound.
    var soundName = ""
    /// Re-alert if a monitor is STILL alerting after N minutes; 0 = off.
    var renotifyMinutes = 30
    /// Same defaults as the Python app: P1 unmissable and nagging fast.
    var severityRules: [Int: SeverityRule] = [
        1: SeverityRule(style: .both, renotifyMinutes: 10),
        2: SeverityRule(style: .both, renotifyMinutes: 30),
        3: SeverityRule(style: .banner, renotifyMinutes: 60),
    ]
    /// Post a morning summary at/after this hour; -1 = off.
    var digestHour = -1

    static let renotifyChoices = [0, 10, 30, 60, 120]

    /// Style + renotify for a given priority after severity-rule overrides.
    func effective(for priority: Priority) -> (style: Style, renotifyMinutes: Int) {
        let rule = severityRules[priority.rawValue]
        return (rule?.style ?? style, rule?.renotifyMinutes ?? renotifyMinutes)
    }

    private static let key = "notificationSettings"

    static func load() -> NotificationSettings {
        let defaults = UserDefaults.standard
        guard let dict = defaults.dictionary(forKey: key) else { return NotificationSettings() }
        var settings = NotificationSettings()
        settings.enabled = dict["enabled"] as? Bool ?? true
        settings.notifyOnWarn = dict["notifyOnWarn"] as? Bool ?? true
        settings.notifyOnNoData = dict["notifyOnNoData"] as? Bool ?? true
        settings.notifyOnRecovery = dict["notifyOnRecovery"] as? Bool ?? true
        settings.style = (dict["style"] as? String).flatMap(Style.init) ?? .banner
        settings.soundEnabled = dict["soundEnabled"] as? Bool ?? true
        settings.soundName = dict["soundName"] as? String ?? ""
        settings.renotifyMinutes = dict["renotifyMinutes"] as? Int ?? 30
        settings.digestHour = dict["digestHour"] as? Int ?? -1
        if let rules = dict["severityRules"] as? [String: [String: Any]] {
            settings.severityRules = [:]
            for (rawPriority, rule) in rules {
                guard let priority = Int(rawPriority) else { continue }
                settings.severityRules[priority] = SeverityRule(
                    style: (rule["style"] as? String).flatMap(Style.init),
                    renotifyMinutes: rule["renotifyMinutes"] as? Int)
            }
        }
        return settings
    }

    func save() {
        var rules: [String: [String: Any]] = [:]
        for (priority, rule) in severityRules {
            var encoded: [String: Any] = [:]
            if let style = rule.style { encoded["style"] = style.rawValue }
            if let renotify = rule.renotifyMinutes { encoded["renotifyMinutes"] = renotify }
            rules[String(priority)] = encoded
        }
        UserDefaults.standard.set([
            "enabled": enabled,
            "notifyOnWarn": notifyOnWarn,
            "notifyOnNoData": notifyOnNoData,
            "notifyOnRecovery": notifyOnRecovery,
            "style": style.rawValue,
            "soundEnabled": soundEnabled,
            "soundName": soundName,
            "renotifyMinutes": renotifyMinutes,
            "digestHour": digestHour,
            "severityRules": rules,
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
