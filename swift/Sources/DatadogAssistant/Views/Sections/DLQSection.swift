import SwiftUI

/// Dead-letter queues get their own section — a queue backing up is a
/// different class of problem from a latency blip, and burying it in the
/// monitor list hides exactly the thing that pages you at 3am. Urgent DLQ
/// monitors render as full rows; healthy ones collapse to a count.
struct DLQSection: View {
    let snapshot: Snapshot
    @State private var showHealthy = false

    var body: some View {
        let dlq = snapshot.dlq
        if !dlq.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                let urgent = dlq.filter { $0.state != .ok }
                let healthy = dlq.count - urgent.count

                HStack(spacing: 6) {
                    Text("💀 Dead letter queues · \(dlq.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.textSecondary)
                    if !urgent.isEmpty {
                        Text("\(urgent.count) firing")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.alert)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.alert.opacity(0.15)))
                    }
                    Spacer()
                }
                .padding(.leading, 2)

                VStack(spacing: 2) {
                    ForEach(urgent) { MonitorRow(monitor: $0) }
                }

                if healthy > 0 {
                    Button {
                        withAnimation { showHealthy.toggle() }
                    } label: {
                        Text(showHealthy ? "hide healthy" : "🟢 \(healthy) healthy")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                    if showHealthy {
                        VStack(spacing: 2) {
                            ForEach(dlq.filter { $0.state == .ok }) { MonitorRow(monitor: $0) }
                        }
                    }
                }
            }
        }
    }
}
