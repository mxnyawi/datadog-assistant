import Foundation

/// Anything that can produce a Snapshot. SnapshotStore drives one of these on
/// its adaptive polling loop; views never see this type.
protocol DataSource: AnyObject {
    /// A short label shown in the header pill ("acme-prod", "Sample data").
    var sourceName: String { get }

    /// Fetch the current world state. Called from the store's poll loop; may
    /// take `previous` to reuse expensive per-monitor data (sparklines) when a
    /// monitor hasn't changed state.
    func fetchSnapshot(previous: Snapshot?) async throws -> Snapshot

    /// Mute a monitor until `until` (nil = forever).
    func mute(monitorID: Int, until: Date?) async throws
}
