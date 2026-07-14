import SwiftUI
import AppKit

/// One monitor, in the native list-row grammar: leading status symbol (shape
/// + color), 13pt name, trailing value in monospaced digits. Hovering
/// highlights the row like a menu item; clicking expands to the sparkline,
/// firing details, and the fast actions — mute / open — inline.
struct MonitorRow: View {
    @EnvironmentObject var store: SnapshotStore
    let monitor: Monitor
    @State private var expanded = false
    @State private var hovering = false
    @State private var creatingTicket = false
    @State private var ticketError: String?
    @State private var renaming = false
    @State private var aliasText = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { Theme.color(for: monitor.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2)
                                           : .spring(response: 0.3, dampingFraction: 0.8)) {
                    expanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.pressable)

            if expanded {
                if !monitor.sparkline.isEmpty {
                    Sparkline(points: monitor.sparkline, color: tint,
                              threshold: monitor.thresholdPosition,
                              breachBelow: monitor.isBelowThreshold,
                              markers: monitor.deployMarkers,
                              ghost: monitor.ghostSparkline,
                              projection: monitor.projection())
                        .frame(height: 30)
                        .padding(.leading, 24)
                }
                details
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering || expanded ? Theme.hover : Color.clear)
        )
        .hoverFade(hovering)
        .onHover { hovering = $0 }
    }

    private var header: some View {
        // Expanded: the name wraps to as many lines as it needs so a long,
        // unwieldy monitor title is fully readable; collapsed, it stays one
        // truncated line. Trailing value/chevron align to the first line.
        HStack(alignment: expanded ? .top : .center, spacing: 8) {
            Image(systemName: Theme.symbol(for: monitor.state))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 16)
            if monitor.priority <= .p2 {
                Text(monitor.priority.label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(tint)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(tint.opacity(0.15))
                    )
            }
            Text(monitor.name)
                .font(.system(size: 13))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let delta = monitor.delta, delta >= 1.5 {
                Text("×\(String(format: delta >= 10 ? "%.0f" : "%.1f", delta))")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
                    .help("vs the same time last week")
            }
            Text(rightLabel)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(tint)
                .contentTransition(.numericText())
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Theme.textMuted)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(hovering || expanded ? 1 : 0)
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
                if let trend = monitor.trendLabel {
                    let critical = trend.contains("critical")
                    HStack(spacing: 4) {
                        Image(systemName: trend.hasPrefix("easing")
                              ? "chart.line.downtrend.xyaxis"
                              : "chart.line.uptrend.xyaxis")
                            .font(.system(size: 9))
                        Text(trend)
                            .font(.system(size: 11, weight: critical ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(critical ? tint : Theme.textSecondary)
                }
            }
            // Blast radius: which hosts/groups are firing vs healthy.
            if monitor.groupStates.count > 1 {
                GroupHeatmap(states: monitor.groupStates)
            }
            if !monitor.triggeredHosts.isEmpty {
                detailItem(icon: "server.rack",
                           text: monitor.triggeredHosts.prefix(4).joined(separator: ", "))
            }
            if let reason = monitor.noDataReason {
                detailItem(icon: "magnifyingglass", text: reason)
            }
            if let suspect = store.suspectDeploy(for: monitor) {
                suspectRow(suspect)
            }
            HStack(spacing: 8) {
                muteMenu
                actionButton("Open in Datadog", icon: "arrow.up.forward.square") {
                    if let url = monitor.url { LinkOpener.open(url) }
                }
                .disabled(monitor.url == nil)
                if let ticket = JiraTicketStore.ticket(for: monitor.id) {
                    actionButton("Open \(ticket.key)", icon: "ticket.fill") {
                        LinkOpener.open(ticket.url)
                    }
                } else if let jira = JiraConfig.load() {
                    actionButton(creatingTicket ? "Creating…" : "Jira ticket",
                                 icon: "ticket.fill") {
                        createTicket(jira)
                    }
                    .disabled(creatingTicket)
                }
            }
            .padding(.top, 2)
            if let ticketError {
                Text(ticketError)
                    .font(.system(size: 10))
                    .foregroundColor(Theme.alert)
                    .lineLimit(2)
            }
            renameRow
        }
        .padding(.leading, 24)
        .padding(.bottom, 2)
    }

    /// Local rename: a display alias for this app only (unwieldy monitor
    /// titles → something readable). Reset restores the Datadog name.
    @ViewBuilder private var renameRow: some View {
        if renaming {
            HStack(spacing: 6) {
                TextField("Local name (blank resets)", text: $aliasText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { applyRename() }
                Button("Save") { applyRename() }
                    .font(.system(size: 11))
                Button("Cancel") { renaming = false }
                    .font(.system(size: 11))
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    aliasText = monitor.name
                    renaming = true
                } label: {
                    Label("Rename (local)", systemImage: "pencil")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                }
                .buttonStyle(.pressable)
                if let original = monitor.originalName {
                    Button {
                        MonitorAliases.reset(monitorID: monitor.id)
                        Task { await store.refresh() }
                    } label: {
                        Label("Reset to “\(original)”", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Theme.textMuted)
                            .lineLimit(1)
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
    }

    private func applyRename() {
        MonitorAliases.set(aliasText == monitor.originalName ? "" : aliasText,
                           for: monitor.id)
        renaming = false
        Task { await store.refresh() }
    }

    /// Mute durations (1 h / 4 h / 24 h / forever) or Unmute, depending on the
    /// monitor's state — same options as the Python app's per-monitor menu.
    private var muteMenu: some View {
        Menu {
            if monitor.state == .muted {
                Button("Unmute") { Task { await store.unmute(monitor) } }
            } else {
                Button("Mute 1 hour") { Task { await store.mute(monitor, for: 3600) } }
                Button("Mute 4 hours") { Task { await store.mute(monitor, for: 4 * 3600) } }
                Button("Mute 24 hours") { Task { await store.mute(monitor, for: 24 * 3600) } }
                Button("Mute forever") { Task { await store.mute(monitor, for: nil) } }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: monitor.state == .muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(monitor.state == .muted ? "Unmute" : "Mute")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Theme.track))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Fire the Jira ticket and jump straight to it — the browser tab is the
    /// success feedback.
    private func createTicket(_ config: JiraConfig) {
        creatingTicket = true
        ticketError = nil
        // @MainActor: mutates @State after the await; a plain Task from a
        // nonisolated View method would do that off the main thread.
        Task { @MainActor in
            do {
                let ticket = try await JiraClient.createIssue(for: monitor, config: config)
                LinkOpener.open(ticket.url)
            } catch {
                ticketError = error.localizedDescription
            }
            creatingTicket = false
        }
    }

    /// "What shipped right before this?" — the change-correlation callout,
    /// clickable straight to the PR/event.
    private func suspectRow(_ deploy: DeployEvent) -> some View {
        Button {
            if let url = deploy.url { LinkOpener.open(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: deploy.source == .github ? "arrow.triangle.pull" : "shippingbox.fill")
                    .font(.system(size: 10, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(deploy.title)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text("landed \(minutesBefore(deploy)) before this alert")
                        .font(.system(size: 9, weight: .medium))
                        .opacity(0.75)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(Theme.alert)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.alert.opacity(0.10))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func minutesBefore(_ deploy: DeployEvent) -> String {
        guard let since = monitor.firingSince else { return "just" }
        let mins = max(1, Int(since.timeIntervalSince(deploy.occurredAt) / 60))
        return "\(mins)m"
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
            .background(Capsule().fill(Theme.track))
        }
        .buttonStyle(.pressable)
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
