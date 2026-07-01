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

    struct Transition {
        enum Kind { case fired, recovered }
        let kind: Kind
        let monitor: Monitor
    }
    var onTransitions: (([Transition]) -> Void)?

    static let fastInterval: TimeInterval = 15
    static let slowInterval: TimeInterval = 60
    private static let recoveryHoldoff: TimeInterval = 300
    private static let activityCapacity = 96

    private var source: DataSource
    private var pollTask: Task<Void, Never>?
    private var lastRecoveryAt: Date = .distantPast

    init(source: DataSource) {
        self.source = source
        if let cached = Self.readCache() {
            var stale = cached
            stale.connected = false   // until the first live poll lands
            snapshot = stale
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

    /// Swap mock ↔ real (e.g. after credentials are saved) and restart.
    func replaceSource(_ newSource: DataSource) {
        source = newSource
        snapshot = .empty
        lastError = nil
        start()
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        do {
            var next = try await source.fetchSnapshot(previous: snapshot)
            let transitions = Self.diff(old: snapshot, new: next)
            if transitions.contains(where: { $0.kind == .recovered }) {
                lastRecoveryAt = Date()
            }
            next.activity = Self.pushActivity(snapshot.activity, next: next)
            snapshot = next
            lastError = nil
            Self.writeCache(next)
            if !transitions.isEmpty { onTransitions?(transitions) }
        } catch {
            lastError = error.localizedDescription
            snapshot.connected = false
        }
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

    // MARK: - Diffing

    private static func diff(old: Snapshot, new: Snapshot) -> [Transition] {
        guard old.lastRefresh != .distantPast else { return [] }  // first poll: no spam
        let oldAlerting = Set(old.alerting.map(\.id))
        let newAlerting = Set(new.alerting.map(\.id))
        let fired = new.alerting.filter { !oldAlerting.contains($0.id) }
        let recovered = old.alerting.filter { monitor in
            !newAlerting.contains(monitor.id)
                && new.monitors.first(where: { $0.id == monitor.id })?.state == .ok
        }
        return fired.map { Transition(kind: .fired, monitor: $0) }
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
