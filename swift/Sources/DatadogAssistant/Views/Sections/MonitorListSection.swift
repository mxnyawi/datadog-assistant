import SwiftUI

/// The full monitor list: search-as-you-type over name and service, grouped
/// by state, worst first. Rows are the same expandable MonitorRow used on the
/// Monitors tab, so mute/open actions work from here too.
struct MonitorListSection: View {
    let snapshot: Snapshot
    @State private var query = ""

    private static let groupOrder: [MonitorState] = [.alert, .warn, .noData, .muted, .ok]

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
                ForEach(Self.groupOrder, id: \.self) { state in
                    let group = filtered.filter { $0.state == state }
                    if !group.isEmpty {
                        stateGroup(state, monitors: group)
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

    private func stateGroup(_ state: MonitorState, monitors: [Monitor]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.color(for: state))
                    .frame(width: 7, height: 7)
                Text("\(state.label) · \(monitors.count)")
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
