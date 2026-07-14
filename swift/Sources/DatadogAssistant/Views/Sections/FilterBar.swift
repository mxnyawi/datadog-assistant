import SwiftUI

/// Persistent monitor filtering, right where the monitors are. A dropdown of
/// every tag the app has seen (grouped by tag key — team, env, service…) with
/// checkmark multi-select, plus removable chips for what's active. Selection
/// is OR ("any of these tags"), same as the Python app's tag_filter, and is
/// applied server-side on the next poll.
struct FilterBar: View {
    @EnvironmentObject var store: SnapshotStore

    var body: some View {
        let filters = store.filters
        HStack(spacing: 6) {
            tagMenu(filters)

            if filters.isActive {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(filters.tags, id: \.self) { tag in
                            chip(tag) { remove(tag: tag) }
                        }
                        if !filters.name.trimmingCharacters(in: .whitespaces).isEmpty {
                            chip("name: \(filters.name)") {
                                var next = store.filters
                                next.name = ""
                                store.setFilters(next)
                            }
                        }
                    }
                }
                Button {
                    // Clear the tag/name chips only — the hide-No-Data
                    // preference isn't a chip, so "Clear" must not flip it.
                    var next = FilterConfig()
                    next.hideNoData = store.filters.hideNoData
                    store.setFilters(next)
                } label: {
                    Text("Clear")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.pressable)
            } else {
                Text("All monitors")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                Spacer()
            }
            if let hidden = store.snapshot.hiddenNoDataCount, hidden > 0 {
                Button {
                    var next = store.filters
                    next.hideNoData = false
                    store.setFilters(next)
                } label: {
                    Text("\(hidden) No Data hidden")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textMuted)
                        .underline()
                }
                .buttonStyle(.pressable)
                .help("No-Data monitors are hidden by default — click to show them")
            }
        }
    }

    private func tagMenu(_ filters: FilterConfig) -> some View {
        Menu {
            let groups = FilterConfig.knownTagsByKey()
            if groups.isEmpty {
                Text("No tags discovered yet")
            }
            ForEach(groups, id: \.key) { group in
                Menu(group.key) {
                    ForEach(group.tags, id: \.self) { tag in
                        Button {
                            toggle(tag: tag)
                        } label: {
                            if filters.tags.contains(tag) {
                                Label(shortLabel(tag), systemImage: "checkmark")
                            } else {
                                Text(shortLabel(tag))
                            }
                        }
                    }
                }
            }
            if !filters.tags.isEmpty {
                Divider()
                Button("Clear tag filter") {
                    var next = store.filters
                    next.tags = []
                    store.setFilters(next)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease.circle"
                      + (filters.tags.isEmpty ? "" : ".fill"))
                    .font(.system(size: 12, weight: .semibold))
                Text(filters.tags.isEmpty ? "Filter" : "\(filters.tags.count)")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(filters.tags.isEmpty ? Theme.textSecondary : Theme.info)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.panel)
                    .overlay(Capsule().stroke(Theme.panelStroke, lineWidth: 1))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Inside the "team" submenu, show "payments" instead of "team:payments".
    private func shortLabel(_ tag: String) -> String {
        guard let colon = tag.firstIndex(of: ":") else { return tag }
        return String(tag[tag.index(after: colon)...])
    }

    private func chip(_ text: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.pressable)
        }
        .foregroundColor(Theme.info)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(Capsule().fill(Theme.info.opacity(0.14)))
    }

    private func toggle(tag: String) {
        var next = store.filters
        if let index = next.tags.firstIndex(of: tag) {
            next.tags.remove(at: index)
        } else {
            next.tags.append(tag)
        }
        store.setFilters(next)
    }

    private func remove(tag: String) {
        var next = store.filters
        next.tags.removeAll { $0 == tag }
        store.setFilters(next)
    }
}
