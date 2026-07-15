import SwiftUI

/// ⌘K fuzzy-find over every monitor — type a few letters, press Return, and
/// it opens in Datadog, no mouse. Up/Down move the selection; the top match is
/// pre-selected so Return works immediately even if arrow routing is swallowed
/// by the focused field. Backdrop tap, the ✕, or ⌘K again dismiss it.
struct CommandPalette: View {
    let monitors: [Monitor]
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private static let maxResults = 8

    private var results: [Monitor] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = needle.isEmpty
            ? monitors
            : monitors.filter {
                $0.name.lowercased().contains(needle)
                    || ($0.service?.lowercased().contains(needle) ?? false)
            }
        return Array(base.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
            .prefix(Self.maxResults))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }
            card
                .padding(.horizontal, 20)
                .padding(.top, 52)
        }
        .background(navigationKeys)
    }

    private var card: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if results.isEmpty {
                Text(query.isEmpty ? "No monitors." : "No matches for “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, monitor in
                        resultRow(monitor, selected: index == clampedSelection)
                            .onTapGesture { open(monitor) }
                    }
                }
                .padding(6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.panelStroke, lineWidth: 1))
        )
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.textMuted)
            TextField("Jump to a monitor…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundColor(Theme.textPrimary)
                .focused($focused)
                .onSubmit { openSelected() }
                .onChange(of: query) { _ in selection = 0 }
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .onAppear { focused = true }
    }

    private func resultRow(_ monitor: Monitor, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Theme.symbol(for: monitor.state))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.color(for: monitor.state))
                .frame(width: 16)
            Text(monitor.name)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let service = monitor.service {
                Text(service)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Theme.textMuted)
                    .lineLimit(1)
            }
            Image(systemName: "arrow.up.forward")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .opacity(selected ? 1 : 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.hover : Color.clear)
        )
        .contentShape(Rectangle())
    }

    /// Hidden shortcut sinks: arrow keys move the selection. Kept at zero
    /// opacity (not `.hidden()`) so the keyboard shortcuts stay live.
    private var navigationKeys: some View {
        Group {
            Button("") { move(-1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") { move(1) }
                .keyboardShortcut(.downArrow, modifiers: [])
        }
        .opacity(0)
    }

    /// selection can drift past the result count as the query narrows; read it
    /// through a clamp everywhere.
    private var clampedSelection: Int {
        guard !results.isEmpty else { return 0 }
        return max(0, min(results.count - 1, selection))
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = max(0, min(results.count - 1, clampedSelection + delta))
    }

    private func openSelected() {
        guard !results.isEmpty else { return }
        open(results[clampedSelection])
    }

    private func open(_ monitor: Monitor) {
        let url = monitor.url
            ?? Credentials.currentAppBaseURL().appendingPathComponent("/monitors/manage")
        LinkOpener.open(url)
        isPresented = false
    }
}
