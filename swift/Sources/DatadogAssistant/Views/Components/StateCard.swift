import SwiftUI

/// One summary tile: count in the status color over a small caption, on a
/// grouped-inset card. Acts as a button (drill into the full list).
struct StateCard: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color
    var action: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(tint)
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                }
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .tracking(-0.4)
                    .foregroundColor(tint)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Theme.hover : Theme.panel)
            )
            .contentShape(Rectangle())
            .hoverFade(hovering)
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .help("Show all monitors")
    }
}
