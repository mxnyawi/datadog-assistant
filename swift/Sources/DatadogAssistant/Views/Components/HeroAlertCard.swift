import SwiftUI
import AppKit

/// The war-room card: when a P1/P2 is firing, the worst monitor takes over
/// the top of the panel — pulsing live indicator, ticking duration, value vs
/// threshold as a gauge bar, sparkline with deploy markers, the suspect
/// change, and the two actions that matter. The whole incident, one card.
struct HeroAlertCard: View {
    @EnvironmentObject var store: SnapshotStore
    let monitor: Monitor
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            valueRow
            if !monitor.sparkline.isEmpty {
                Sparkline(points: monitor.sparkline, color: Theme.alert,
                          threshold: monitor.thresholdPosition,
                          markers: monitor.deployMarkers,
                          ghost: monitor.ghostSparkline,
                          projection: monitor.projection())
                    .frame(height: 34)
            }
            if monitor.groupStates.count > 1 {
                GroupHeatmap(states: monitor.groupStates)
            }
            if let suspect = store.suspectDeploy(for: monitor) {
                suspectChip(suspect)
            }
            actions
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.alert.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Theme.alert.opacity(0.35), lineWidth: 1)
                )
        )
        .onAppear { pulsing = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.alert)
                .frame(width: 8, height: 8)
                .opacity(pulsing ? 0.35 : 1.0)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                           value: pulsing)
            Text("\(monitor.priority.label) · ALERTING")
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(Theme.alert)
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(firingLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Theme.alert)
            }
        }
    }

    private var firingLabel: String {
        guard let duration = monitor.firingDuration else { return "firing" }
        return "firing \(duration)"
    }

    private var valueRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monitor.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)

            if let value = monitor.value {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(compact(value))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .tracking(-1)
                        .foregroundColor(Theme.alert)
                        .contentTransition(.numericText())
                    if let threshold = monitor.threshold {
                        Text("/ \(compact(threshold)) threshold")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Theme.textSecondary)
                    }
                    if let delta = monitor.delta, delta >= 1.5 {
                        Spacer()
                        Text("×\(String(format: delta >= 10 ? "%.0f" : "%.1f", delta)) vs last week")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.alert)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.alert.opacity(0.15)))
                    }
                }
                if let threshold = monitor.threshold, threshold > 0, value > 0 {
                    gaugeBar(value: value, threshold: threshold)
                }
            }
        }
    }

    /// Value vs threshold: the threshold tick sits at a fixed 62% so overshoot
    /// reads as "into the red zone", capped at ~1.6× threshold.
    private func gaugeBar(value: Double, threshold: Double) -> some View {
        GeometryReader { geo in
            let cap = 1.6
            let fraction = min(value / threshold, cap) / cap
            let thresholdX = geo.size.width * CGFloat(1.0 / cap)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(
                        colors: [Theme.warn, Theme.alert],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * CGFloat(fraction)))
                Rectangle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 1.5)
                    .offset(x: thresholdX)
            }
        }
        .frame(height: 6)
    }

    private func suspectChip(_ deploy: DeployEvent) -> some View {
        Button {
            if let url = deploy.url { LinkOpener.open(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: deploy.source == .github ? "arrow.triangle.pull" : "shippingbox.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(deploy.title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("· \(deploy.relativeTime)")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.75)
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(Theme.warn)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.warn.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Theme.warn.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            heroButton("Mute 1h", icon: "speaker.slash.fill", prominent: false) {
                Task { await store.mute(monitor, for: 3600) }
            }
            heroButton("Open in Datadog", icon: "arrow.up.forward.square", prominent: true) {
                if let url = monitor.url { LinkOpener.open(url) }
            }
        }
    }

    private func heroButton(_ label: String, icon: String, prominent: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(prominent ? Color.white : Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(
                Capsule().fill(prominent ? Theme.alert : Theme.track)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
    }

    private func compact(_ v: Double) -> String {
        if v >= 1000 { return String(format: "%.1fk", v / 1000) }
        if abs(v) < 10 { return String(format: "%.1f", v) }
        return String(format: "%.0f", v)
    }
}
