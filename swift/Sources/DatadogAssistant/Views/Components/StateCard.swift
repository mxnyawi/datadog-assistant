import SwiftUI

struct StateCard: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.textSecondary)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Theme.textSecondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.panelStroke, lineWidth: 1)
                )
        )
    }
}
