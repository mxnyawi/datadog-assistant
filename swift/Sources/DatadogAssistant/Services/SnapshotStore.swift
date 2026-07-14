import Foundation
import Combine

/// Owns the poll loop and the published Snapshot. Views observe this; the
/// DataSource behind it is swappable (mock ↔ real) at runtime.
///
/// Speed decisions live here:
/// - Adaptive cadence: 15s while anything is firing (or recovered <5 min ago),
///   60s when everything is green. Cadence is the latency floor — Datadog has
///   no push channel to desktops — so it's surfaced in the UI, not hidden.
/// - Last snapshot is cached to disk and republished on launch, so the panel
///   renders instantly with known-stale data while the first poll runs.
/// - State diffing between polls emits notification events (new alert /
///   recovery) through `onTransitions`.
@MainActor
final class SnapshotStore: ObservableObject {
    @Published private(set) var snapshot: Snapshot = .empty
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false
    @Published private(set) var snoozedUntil: Date?
    @Published private(set) var stats = ResponseStats()
    @Published private(set) var filters = FilterConfig.load()
    /// No usable credentials and the user hasn't chosen sample mode — the
    /// panel shows a connect prompt instead of sample data. Owned by
    /// AppDelegate, which is the only thing that knows about credentials.
    @Published var needsSetup = false

    var isSnoozed: Bool {
        guard let until = snoozedUntil else { return false }
        return until > Date()
    }

    /// The numbers the response-time story is told with. Session-scoped —
    /// they accumulate from observed transitions, so a fresh launch starts
    /// clean rather than showing stale counts.
    struct ResponseStats: Equatable {
        /// Poll-observed lag between a monitor starting to fire and this app
        /// noticing — the honest "detected in Ns" figure.
        var lastDetectionSeconds: Int?
        var alertsToday: Int = 0
        var recoveryDurations: [TimeInterval] = []

        var medianRecoveryMinutes: Int? {
            guard !recoveryDurations.isEmpty else { return nil }
            let sorted = recoveryDurations.sorted()
            return Int(sorted[sorted.count / 2] / 60)
        }

        var hasData: Bool { lastDetectionSeconds != nil || alertsToday > 0 }
    }

    struct Transition {
        enum Kind { case fired, warned, wentNoData, recovered }
        let kind: Kind
        let monitor: Monitor
    }
    var onTransitions: (([Transition]) -> Void)?
    /// Fires after every successful poll while un-snoozed — drives the
    /// "still alerting after N minutes" re-notify nag.
    var onPoll: ((Snapshot) -> Void)?

    static let fastInterval: TimeInterval = 15
    static let slowInterval: TimeInterval = 60
    private static let recoveryHoldoff: TimeInterval = 300
    private static let activityCapacity = 96

    /// How long before an alert a change counts as a suspect.
    private static let suspectWindow: TimeInterval = 45 * 60
    private static let deployLookback: TimeInterval = 6 * 3600
    private static let maxDeploys = 20

    private var source: DataSource
    private var gitHub: GitHubClient?
    private var pollTask: Task<Void, Never>?
    private var lastRecoveryAt: Date = .distantPast
    private var snoozeHandle: String? {
        get { UserDefaults.standard.string(forKey: "snoozeHandle") }
        set { UserDefaults.standard.set(newValue, forKey: "snoozeHandle") }
    }

    init(source: DataSource) {
        self.source = source
        // GitHubConfig.load() can shell out (gh auth token, lpass) — never on
        // the main thread; the first poll picks the client up when it's ready.
        reloadGitHubClient()
        if let until = UserDefaults.standard.object(forKey: "snoozedUntil") as? Date, until > Date() {
            snoozedUntil = until
        }
        if let cached = Self.readCache() {
            var stale = cached
            stale.connected = false   // until the first live poll lands
            snapshot = stale
        }
    }

    /// (Re)resolve the GitHub client off the main thread. Also retried while
    /// unconfigured (see `performRefresh`), so running `gh auth login` starts
    /// feeding the Changes tab without an app restart.
    private var gitHubRetryAt: Date = .distantPast
    private func reloadGitHubClient() {
        gitHubRetryAt = Date().addingTimeInterval(300)
        Task { [weak self] in
            let client = await Task.detached { GitHubConfig.load().map(GitHubClient.init) }.value
            if let client { self?.gitHub = client }
        }
    }

    var currentInterval: TimeInterval {
        let hot = !snapshot.alerting.isEmpty || !snapshot.warning.isEmpty
            || Date().timeIntervalSince(lastRecoveryAt) < Self.recoveryHoldoff
        return hot ? Self.fastInterval : Self.slowInterval
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(self.currentInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Install the first real source after launch and begin polling. Unlike
    /// `replaceSource`, this keeps the disk-cached snapshot on screen (it's
    /// what makes launch feel instant); the first live poll replaces it.
    func adoptInitialSource(_ newSource: DataSource) {
        sourceGeneration += 1
        source = newSource
        start()
    }

    /// Swap mock ↔ real (e.g. after credentials are saved) and restart.
    func replaceSource(_ newSource: DataSource) {
        sourceGeneration += 1   // in-flight refreshes of the old source discard
        source = newSource
        gitHub = nil
        reloadGitHubClient()   // repos/token may have changed with the source
        filters = FilterConfig.load()   // Settings may have edited them
        snapshot = .empty
        lastError = nil
        hasLivePoll = false
        start()
    }

    /// Refreshes are strictly serialized (FIFO): the poll loop, mute/unmute,
    /// and filter changes can all request one, and two in flight at once
    /// would race the data source's per-poll state and apply results out of
    /// order (a stale fetch overwriting a newer one — mutes "reverting").
    private var refreshChain: Task<Void, Never>?
    /// Bumped when the source is swapped; a refresh started against an old
    /// generation throws its result away instead of overwriting the new
    /// source's data.
    private var sourceGeneration = 0
    /// False until a live fetch lands. The disk-cached snapshot republished at
    /// launch must not be diffed against — it would replay hours-old fired/
    /// recovered transitions as fresh notifications and pollute the stats.
    private var hasLivePoll = false

    func refresh() async {
        let previous = refreshChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performRefresh()
        }
        refreshChain = task
        await task.value
    }

    private func performRefresh() async {
        let generation = sourceGeneration
        refreshing = true
        defer { refreshing = false }
        // GitHub still unconfigured? Retry occasionally so `gh auth login`
        // or newly-added repos take effect without a restart.
        if gitHub == nil, Date() >= gitHubRetryAt { reloadGitHubClient() }
        do {
            var next = try await source.fetchSnapshot(previous: snapshot)
            guard generation == sourceGeneration else { return }   // source swapped mid-fetch

            next.monitors = MonitorAliases.apply(to: next.monitors)
            // Remember every tag we've ever seen so the filter dropdown can
            // offer the full menu even while a narrowing filter is active.
            FilterConfig.recordSeenTags(next.monitors.flatMap(\.tags))
            // Server-side filtering already narrowed the fetch for the real
            // client; re-apply here so mock data and just-changed filters
            // take effect immediately.
            if filters.isActive {
                next.monitors = next.monitors.filter { filters.matches($0) }
            }
            // No-Data monitors carry no signal — drop them everywhere (list,
            // counts, notifications) unless the user opts back in. Safe for
            // transition diffing: a dropped monitor can't false-recover
            // (recovery requires it be present and .ok). Count what was
            // hidden so the filter bar can say so.
            if filters.hideNoData {
                let before = next.monitors.count
                next.monitors = next.monitors.filter { $0.state != .noData }
                next.hiddenNoDataCount = before - next.monitors.count
            }

            if let gitHub {
                let merges = await gitHub.recentMerges(within: Self.deployLookback)
                next.deploys += merges
                next.ciRuns = await gitHub.latestRuns()
            }
            next.deploys = Array(
                next.deploys
                    .sorted { $0.occurredAt > $1.occurredAt }
                    .prefix(Self.maxDeploys)
            )
            Self.markSuspects(in: &next)
            Self.attachDeployMarkers(in: &next)

            // The first live poll is a baseline, not news: diffing it against
            // the republished disk cache would notify about transitions that
            // happened while the app wasn't even running.
            let transitions = hasLivePoll ? Self.diff(old: snapshot, new: next) : []
            hasLivePoll = true
            if transitions.contains(where: { $0.kind == .recovered }) {
                lastRecoveryAt = Date()
            }
            updateStats(with: transitions)
            next.activity = Self.pushActivity(snapshot.activity, next: next)
            snapshot = next
            lastError = nil
            Self.writeCache(next)
            // Snooze silences banners, not the panel — it stays live. Sample
            // data must never page anyone (no notifications, no nags, no
            // auto-created Jira tickets from generated monitors).
            if !next.sampleData {
                if !transitions.isEmpty, !isSnoozed { onTransitions?(transitions) }
                if !isSnoozed { onPoll?(next) }
            }
        } catch {
            guard generation == sourceGeneration else { return }
            lastError = error.localizedDescription
            snapshot.connected = false
        }
    }

    // MARK: - Response stats

    private func updateStats(with transitions: [Transition]) {
        guard !transitions.isEmpty else { return }
        var next = stats
        let now = Date()
        for transition in transitions {
            switch transition.kind {
            case .fired:
                next.alertsToday += 1
                if let since = transition.monitor.firingSince {
                    let lag = now.timeIntervalSince(since)
                    if lag >= 0, lag < 3600 { next.lastDetectionSeconds = Int(lag) }
                }
            case .warned, .wentNoData:
                break   // not counted as alerts
            case .recovered:
                if let since = transition.monitor.firingSince {
                    let duration = now.timeIntervalSince(since)
                    if duration > 0 { next.recoveryDurations.append(duration) }
                }
            }
        }
        stats = next
    }

    // MARK: - Change correlation ("what shipped before this alert?")

    private static func markSuspects(in snapshot: inout Snapshot) {
        let firing = snapshot.monitors.filter { $0.state == .alert && $0.firingSince != nil }
        guard !firing.isEmpty else { return }
        snapshot.deploys = snapshot.deploys.map { deploy in
            var deploy = deploy
            deploy.suspectFor = firing.compactMap { monitor in
                guard let since = monitor.firingSince else { return nil }
                let lead = since.timeIntervalSince(deploy.occurredAt)
                let serviceMatches = deploy.service == nil
                    || monitor.service == nil
                    || deploy.service == monitor.service
                return (0...suspectWindow).contains(lead) && serviceMatches ? monitor.id : nil
            }
            return deploy
        }
    }

    /// The suspect change for one monitor, if any (newest wins).
    func suspectDeploy(for monitor: Monitor) -> DeployEvent? {
        snapshot.deploys.first { $0.suspectFor.contains(monitor.id) }
    }

    /// Deploys that fall inside a monitor's sparkline window become vertical
    /// ticks on that sparkline (0…1 x positions, service-matched).
    private static func attachDeployMarkers(in snapshot: inout Snapshot) {
        let now = snapshot.lastRefresh
        for index in snapshot.monitors.indices {
            guard !snapshot.monitors[index].sparkline.isEmpty else { continue }
            let monitor = snapshot.monitors[index]
            // Position ticks against this monitor's own sparkline span, which
            // stretches with firing duration.
            let window = monitor.sparklineSpan
            snapshot.monitors[index].deployMarkers = snapshot.deploys.compactMap { deploy in
                let age = now.timeIntervalSince(deploy.occurredAt)
                guard age >= 0, age <= window else { return nil }
                let serviceMatches = deploy.service == nil
                    || monitor.service == nil
                    || deploy.service == monitor.service
                return serviceMatches ? 1.0 - age / window : nil
            }
        }
    }

    // MARK: - Filters

    /// Apply a new filter: persist it, narrow the current snapshot instantly
    /// for a snappy UI, then refetch so a *widened* filter (which needs data
    /// we don't have locally) fills in.
    func setFilters(_ newFilters: FilterConfig) {
        guard newFilters != filters else { return }
        filters = newFilters
        newFilters.save()
        if newFilters.isActive {
            snapshot.monitors = snapshot.monitors.filter { newFilters.matches($0) }
        }
        Task { await refresh() }
    }

    // MARK: - Snooze

    func snoozeAll(for duration: TimeInterval) async {
        let until = Date().addingTimeInterval(duration)
        do {
            snoozeHandle = try await source.snoozeAll(until: until)
            snoozedUntil = until
            UserDefaults.standard.set(until, forKey: "snoozedUntil")
        } catch {
            lastError = "Snooze failed: \(error.localizedDescription)"
        }
    }

    func cancelSnooze() async {
        if let handle = snoozeHandle {
            do { try await source.cancelSnooze(handle: handle) }
            catch {
                // Keep the handle: this is an org-wide Datadog downtime, and
                // discarding it on a failed cancel would leave it running
                // with no way to retry from the app.
                lastError = "Unsnooze failed: \(error.localizedDescription)"
                return
            }
        }
        snoozeHandle = nil
        snoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: "snoozedUntil")
    }

    func mute(_ monitor: Monitor, for duration: TimeInterval?) async {
        do {
            try await source.mute(
                monitorID: monitor.id,
                until: duration.map { Date().addingTimeInterval($0) }
            )
            await refresh()
        } catch {
            lastError = "Mute failed: \(error.localizedDescription)"
        }
    }

    func unmute(_ monitor: Monitor) async {
        do {
            try await source.unmute(monitorID: monitor.id)
            await refresh()
        } catch {
            lastError = "Unmute failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Diffing

    private static func diff(old: Snapshot, new: Snapshot) -> [Transition] {
        guard old.lastRefresh != .distantPast else { return [] }  // first poll: no spam
        let oldAlerting = Set(old.alerting.map(\.id))
        let newAlerting = Set(new.alerting.map(\.id))
        let oldWarning = Set(old.warning.map(\.id))
        let fired = new.alerting.filter { !oldAlerting.contains($0.id) }
        // Newly warning (not an alert downgrade — that's a recovery in
        // progress, not news). Whether it notifies is a settings decision
        // made in NotificationManager.
        let warned = new.warning.filter {
            !oldWarning.contains($0.id) && !oldAlerting.contains($0.id)
        }
        // Newly broken-No-Data (triage already filtered the quiet kind out of
        // `noData`) — silence that matters.
        let oldNoData = Set(old.noData.map(\.id))
        let wentNoData = new.noData.filter {
            !oldNoData.contains($0.id) && !oldAlerting.contains($0.id)
        }
        let recovered = old.alerting.filter { monitor in
            !newAlerting.contains(monitor.id)
                && new.monitors.first(where: { $0.id == monitor.id })?.state == .ok
        }
        return fired.map { Transition(kind: .fired, monitor: $0) }
            + warned.map { Transition(kind: .warned, monitor: $0) }
            + wentNoData.map { Transition(kind: .wentNoData, monitor: $0) }
            + recovered.map { Transition(kind: .recovered, monitor: $0) }
    }

    // MARK: - Activity series (alert pressure over time)

    private static func pushActivity(_ series: [Double], next: Snapshot) -> [Double] {
        let total = max(1, next.monitors.count)
        let weight = Double(next.alerting.count) * 1.0 + Double(next.warning.count) * 0.5
        let pressure = min(0.95, max(0.05, weight / Double(total) * 2.5))
        var out = series
        out.append(pressure)
        if out.count > activityCapacity { out.removeFirst(out.count - activityCapacity) }
        return out
    }

    // MARK: - Disk cache (instant render on launch)

    private static var cacheURL: URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let appDir = dir.appendingPathComponent("DatadogAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent("snapshot.json")
    }

    private static func readCache() -> Snapshot? {
        guard let url = cacheURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static func writeCache(_ snapshot: Snapshot) {
        guard let url = cacheURL, !snapshot.sampleData,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
