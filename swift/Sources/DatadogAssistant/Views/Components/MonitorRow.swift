import SwiftUI
import AppKit

/// One monitor: collapsed shows badge + name + value + sparkline; expanding
/// (the chevron affordance from Vorssaint) reveals firing duration, hosts, and
/// the fast actions — mute / open — inline, no context menus to discover.
struct MonitorRow: View {
    @EnvironmentObject var store: SnapshotStore
    let monitor: Monitor
    @State private var expanded = false

    private var tint: Color { Theme.color(for: monitor.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if !monitor.sparkline.isEmpty {
                Sparkline(points: monitor.sparkline, color: tint)
                    .frame(height: 26)
            }

            if expanded {
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .rotationEffect(.degrees(expanded ? 90 : 0))
            Text(monitor.priority.label)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(tint)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(tint.opacity(0.15))
                )
            Text(monitor.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(rightLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
                .contentTransition(.numericText())
        }
        .contentShape(Rectangle())
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let duration = monitor.firingDuration {
                    detailItem(icon: "timer", text: "firing \(duration)")
                }
                if let threshold = monitor.threshold {
                    detailItem(icon: "ruler", text: "threshold \(compact(threshold))")
                }
            }
            if !monitor.triggeredHosts.isEmpty {
                detailItem(icon: "server.rack",
                           text: monitor.triggeredHosts.prefix(4).joined(separator: ", "))
            }
            HStack(spacing: 8) {
                actionButton("Mute 1h", icon: "speaker.slash.fill") {
                    Task { await store.mute(monitor, for: 3600) }
                }
                actionButton("Open in Datadog", icon: "arrow.up.forward.square") {
                    if let url = monitor.url { NSWorkspace.shared.open(url) }
                }
                .disabled(monitor.url == nil)
            }
            .padding(.top, 2)
        }
        .padding(.leading, 17)
    }

    private func detailItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(Theme.textSecondary)
    }

    private func actionButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                Capsule().fill(Color.white.opacity(0.08))
                    .overlay(Capsule().stroke(Theme.panelStroke, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    private var rightLabel: String {
        if let v = monitor.value { return compact(v) }
        return monitor.state.label
    }

    private func compact(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.1fk", v / 1000) }
        if abs(v) < 10 { return String(format: "%.1f", v) }
        return String(format: "%.0f", v)
    }
}
