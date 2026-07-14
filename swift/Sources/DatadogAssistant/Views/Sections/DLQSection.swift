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
            let urgent = dlq.filter { $0.state != .ok }
            let healthy = dlq.count - urgent.count

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SectionHeader(title: "Dead Letter Queues", count: dlq.count)
                    if !urgent.isEmpty {
                        Text("\(urgent.count) firing")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Theme.alert)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.alert.opacity(0.15)))
                    }
                }

                if !urgent.isEmpty {
                    InsetCard {
                        ForEach(urgent) { MonitorRow(monitor: $0) }
                    }
                }

                if healthy > 0 {
                    Button {
                        withAnimation { showHealthy.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showHealthy ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                            Text(showHealthy ? "Hide healthy" : "\(healthy) healthy")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        }
                        .foregroundColor(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 10)
                    if showHealthy {
                        InsetCard {
                            ForEach(dlq.filter { $0.state == .ok }) { MonitorRow(monitor: $0) }
                        }
                    }
                }
            }
        }
    }
}
