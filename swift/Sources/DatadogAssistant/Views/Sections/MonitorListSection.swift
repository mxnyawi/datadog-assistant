import SwiftUI

/// The full monitor list: search-as-you-type over name and service, grouped
/// by state, worst first. Rows are the same expandable MonitorRow used on the
/// Monitors tab, so mute/open actions work from here too.
struct MonitorListSection: View {
    let snapshot: Snapshot
    @State private var query = ""

    /// Buckets, worst first. No Data splits into broken vs quiet (triage) and
    /// DLQ monitors get their own bucket, mirroring the Python app's groups.
    private struct Bucket {
        let label: String
        let tint: MonitorState
        let matches: (Monitor) -> Bool
    }

    private static let buckets: [Bucket] = [
        // All DLQ monitors, healthy included — every monitor must land in
        // exactly one bucket or it silently vanishes from this list.
        Bucket(label: "Dead Letter Queues", tint: .alert) { $0.isDLQ },
        Bucket(label: "Alerting", tint: .alert) { $0.state == .alert && !$0.isDLQ },
        Bucket(label: "Warning", tint: .warn) { $0.state == .warn && !$0.isDLQ },
        Bucket(label: "No Data — Likely Broken", tint: .noData) {
            $0.state == .noData && !$0.noDataQuiet && !$0.isDLQ
        },
        Bucket(label: "Quiet — No Data, Expected", tint: .noData) {
            $0.state == .noData && $0.noDataQuiet && !$0.isDLQ
        },
        Bucket(label: "Muted", tint: .muted) { $0.state == .muted && !$0.isDLQ },
        Bucket(label: "Healthy", tint: .ok) { $0.state == .ok && !$0.isDLQ },
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            searchField

            let filtered = filteredMonitors
            if filtered.isEmpty {
                Text(query.isEmpty ? "No monitors." : "No matches for “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(Self.buckets.enumerated()), id: \.offset) { _, bucket in
                    let group = filtered.filter(bucket.matches)
                    if !group.isEmpty {
                        monitorGroup(bucket, monitors: group)
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            TextField("Search name or service…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.panel)
        )
    }

    private var filteredMonitors: [Monitor] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return snapshot.monitors }
        return snapshot.monitors.filter { monitor in
            monitor.name.lowercased().contains(needle)
                || (monitor.service?.lowercased().contains(needle) ?? false)
        }
    }

    private func monitorGroup(_ bucket: Bucket, monitors: [Monitor]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: Theme.symbol(for: bucket.tint))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.color(for: bucket.tint))
                Text(bucket.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Text("\(monitors.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            .padding(.leading, 10)
            InsetCard {
                ForEach(monitors.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }) {
                    MonitorRow(monitor: $0)
                }
            }
        }
    }
}
