import SwiftUI

/// Blast-radius grid: one cell per host/group, colored by state — instantly
/// separates "one bad node" from "the whole fleet on fire." Data comes from
/// the monitor's per-group states (group_states=all), which we already fetch.
struct GroupHeatmap: View {
    let states: [MonitorState]

    private static let maxCells = 72
    private let cell: CGFloat = 9
    private let gap: CGFloat = 3

    var body: some View {
        let firing = states.filter { $0 == .alert || $0 == .warn }.count
        // Worst-first so the firing cells cluster at the top-left.
        let shown = states.sorted { rank($0) < rank($1) }.prefix(Self.maxCells)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Text("\(firing) of \(states.count) groups firing")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(Theme.textSecondary)
                if states.count > Self.maxCells {
                    Text("· showing \(Self.maxCells)")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.textMuted)
                }
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: cell, maximum: cell), spacing: gap)],
                alignment: .leading, spacing: gap
            ) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, state in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: state))
                        .frame(width: cell, height: cell)
                }
            }
            // The grid is a visual encoding of the same counts the header line
            // already states — hide the individual cells from VoiceOver.
            .accessibilityHidden(true)
        }
    }

    private func rank(_ s: MonitorState) -> Int {
        switch s {
        case .alert:  return 0
        case .warn:   return 1
        case .noData: return 2
        case .muted:  return 3
        case .ok:     return 4
        }
    }

    /// Healthy groups read as quiet placeholders so the firing ones pop.
    private func color(for s: MonitorState) -> Color {
        s == .ok ? Color.primary.opacity(0.12) : Theme.color(for: s)
    }
}
