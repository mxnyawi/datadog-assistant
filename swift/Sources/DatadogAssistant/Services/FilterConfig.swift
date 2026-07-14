import Foundation

/// Which monitors the app shows. Mirrors the Python app's `tag_filter`
/// (space-separated tags, OR semantics — a monitor matches if it carries any
/// selected tag) and `name_filter` (substring on the monitor name). Applied
/// server-side by DatadogClient (so large orgs don't ship every monitor over
/// the wire) and re-applied client-side so mock data and mid-poll edits filter
/// instantly.
struct FilterConfig: Equatable {
    /// Selected tags, e.g. ["team:payments", "env:prod"]. OR semantics.
    var tags: [String] = []
    /// Case-insensitive substring match on monitor names.
    var name: String = ""
    /// Hide No-Data monitors everywhere (list, counts, notifications). On by
    /// default — a No-Data monitor carries no signal, and the triage probes it
    /// would need are skipped too. Toggle off in Settings → Filters.
    var hideNoData: Bool = true

    var isActive: Bool { !tags.isEmpty || !name.trimmingCharacters(in: .whitespaces).isEmpty }

    private static let tagsKey = "filterTags"
    private static let nameKey = "filterName"
    private static let hideNoDataKey = "filterHideNoData"
    private static let knownTagsKey = "filterKnownTags"

    static func load() -> FilterConfig {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        // env mirrors the Python app's config for headless/dev parity.
        let tags = env["DD_TAG_FILTER"].map { $0.split(separator: " ").map(String.init) }
            ?? defaults.stringArray(forKey: tagsKey) ?? []
        let name = env["DD_NAME_FILTER"] ?? defaults.string(forKey: nameKey) ?? ""
        // Default true when unset (object(forKey:) is nil), overridable by env.
        let hideNoData = env["DD_HIDE_NO_DATA"].map { $0 == "1" || $0.lowercased() == "true" }
            ?? (defaults.object(forKey: hideNoDataKey) as? Bool ?? true)
        return FilterConfig(tags: tags, name: name, hideNoData: hideNoData)
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(tags, forKey: Self.tagsKey)
        defaults.set(name, forKey: Self.nameKey)
        defaults.set(hideNoData, forKey: Self.hideNoDataKey)
    }

    func matches(_ monitor: Monitor) -> Bool {
        if !tags.isEmpty, !tags.contains(where: { monitor.tags.contains($0) }) { return false }
        let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            // Match the local alias OR the Datadog name: the server-side name
            // filter matched the Datadog name, so a renamed monitor must not
            // vanish just because its alias doesn't contain the needle.
            let inAlias = monitor.name.lowercased().contains(needle)
            let inOriginal = monitor.originalName?.lowercased().contains(needle) ?? false
            if !inAlias, !inOriginal { return false }
        }
        return true
    }

    // MARK: Known tags (dropdown options)

    /// Tags ever observed on fetched monitors. Cached as a union across polls
    /// so the filter dropdown still offers everything even while the current
    /// fetch is narrowed by an active filter.
    static func knownTags() -> [String] {
        UserDefaults.standard.stringArray(forKey: knownTagsKey) ?? []
    }

    static func recordSeenTags<S: Sequence>(_ tags: S) where S.Element == String {
        var union = Set(knownTags())
        let before = union.count
        union.formUnion(tags)
        guard union.count != before else { return }
        UserDefaults.standard.set(union.sorted(), forKey: knownTagsKey)
    }

    static func clearKnownTags() {
        UserDefaults.standard.removeObject(forKey: knownTagsKey)
    }

    /// Known tags grouped by key ("team:payments" → key "team") for a tidy
    /// nested dropdown; keyless tags land under "other".
    static func knownTagsByKey() -> [(key: String, tags: [String])] {
        var groups: [String: [String]] = [:]
        for tag in knownTags() {
            let key = tag.contains(":") ? String(tag.prefix(while: { $0 != ":" })) : "other"
            groups[key, default: []].append(tag)
        }
        return groups
            .map { (key: $0.key, tags: $0.value.sorted()) }
            .sorted { $0.key < $1.key }
    }
}
