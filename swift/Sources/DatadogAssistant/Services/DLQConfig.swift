import Foundation

/// Dead-letter-queue grouping: monitors whose name/tags/query match the
/// patterns get their own panel section (a queue backing up is a different
/// class of problem from a latency blip). Port of the Python app's `dlq`
/// config block.
struct DLQConfig: Equatable {
    var enabled = true
    var patterns = ["dlq", "dead letter", "dead-letter", "dead_letter", "deadletter"]
    /// Exclusive: DLQ monitors appear only in the DLQ section, not the
    /// normal state groups.
    var exclusive = true

    private static let enabledKey = "dlqEnabled"
    private static let patternsKey = "dlqPatterns"
    private static let exclusiveKey = "dlqExclusive"

    static func load() -> DLQConfig {
        let defaults = UserDefaults.standard
        var config = DLQConfig()
        if defaults.object(forKey: enabledKey) != nil {
            config.enabled = defaults.bool(forKey: enabledKey)
        }
        if let patterns = defaults.stringArray(forKey: patternsKey), !patterns.isEmpty {
            config.patterns = patterns
        }
        if defaults.object(forKey: exclusiveKey) != nil {
            config.exclusive = defaults.bool(forKey: exclusiveKey)
        }
        return config
    }

    // Configured via `defaults write` on the three keys above — there's no
    // Settings UI for DLQ yet, so no save() until one exists.

    func matches(name: String, tags: [String], query: String) -> Bool {
        guard enabled else { return false }
        let haystack = "\(name) \(tags.joined(separator: " ")) \(query)".lowercased()
        return patterns.contains { haystack.contains($0.lowercased()) }
    }
}

/// Local monitor renames ("aliases") — display names that only affect this
/// app, for taming unwieldy monitor titles. Applied right after every fetch,
/// so the alias shows up in rows, notifications, and Jira summaries alike.
enum MonitorAliases {
    private static let key = "monitorAliases"

    static func alias(for monitorID: Int) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[String(monitorID)]
    }

    static func set(_ alias: String, for monitorID: Int) {
        var map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            map.removeValue(forKey: String(monitorID))
        } else {
            map[String(monitorID)] = trimmed
        }
        UserDefaults.standard.set(map, forKey: key)
    }

    static func reset(monitorID: Int) {
        set("", for: monitorID)
    }

    /// Swap in aliases, keeping the Datadog name for display/reset.
    static func apply(to monitors: [Monitor]) -> [Monitor] {
        monitors.map { monitor in
            guard let alias = alias(for: monitor.id), alias != monitor.name else { return monitor }
            var renamed = monitor
            renamed.originalName = monitor.name
            renamed.name = alias
            return renamed
        }
    }
}
