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
        Bucket(label: "💀 DLQ", tint: .alert) { $0.isDLQ && $0.state != .ok },
        Bucket(label: "Alerting", tint: .alert) { $0.state == .alert && !$0.isDLQ },
        Bucket(label: "Warning", tint: .warn) { $0.state == .warn && !$0.isDLQ },
        Bucket(label: "No Data (likely broken)", tint: .noData) {
            $0.state == .noData && !$0.noDataQuiet && !$0.isDLQ
        },
        Bucket(label: "🤫 Quiet (no data, expected)", tint: .noData) {
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
                    .padding(.vertical, 8)
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
                .font(.system(size: 12))
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
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.panelStroke, lineWidth: 1)
                )
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.color(for: bucket.tint))
                    .frame(width: 7, height: 7)
                Text("\(bucket.label) · \(monitors.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
            }
            .padding(.leading, 2)

            VStack(spacing: 2) {
                ForEach(monitors.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }) {
                    MonitorRow(monitor: $0)
                }
            }
        }
    }
}
