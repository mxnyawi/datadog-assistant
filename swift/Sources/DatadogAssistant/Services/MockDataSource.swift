import Foundation

/// Renders a believable Snapshot without API keys so the panel has something
/// to show before credentials are configured. Advances one tick per fetch;
/// occasionally mutes/unmutes nothing — states are stable so screenshots and
/// design review are reproducible.
final class MockDataSource: DataSource {
    private var seed: UInt64 = 0x5EED
    private var monitors: [Monitor]
    private var incidents: [Incident]

    var sourceName: String { "Sample data" }

    init() {
        var s: UInt64 = 0xC0FFEE
        let now = Date()
        self.monitors = [
            Monitor(id: 1001,
                    name: "payments-api · p99 latency",
                    state: .alert,
                    priority: .p1,
                    firingSince: now.addingTimeInterval(-720),
                    triggeredHosts: ["prod-pay-7", "prod-pay-9"],
                    sparkline: Self.series(starting: 0.62, count: 48, seed: &s, drift: 0.18),
                    value: 842, threshold: 500,
                    url: URL(string: "https://app.datadoghq.com/monitors/1001")),
            Monitor(id: 1002,
                    name: "checkout · 5xx rate",
                    state: .alert,
                    priority: .p2,
                    firingSince: now.addingTimeInterval(-3120),
                    triggeredHosts: ["edge-3"],
                    sparkline: Self.series(starting: 0.55, count: 48, seed: &s, drift: 0.20),
                    value: 4.1, threshold: 1.0,
                    url: URL(string: "https://app.datadoghq.com/monitors/1002")),
            Monitor(id: 1003,
                    name: "kafka · consumer lag",
                    state: .warn,
                    priority: .p3,
                    firingSince: now.addingTimeInterval(-180),
                    triggeredHosts: ["kafka-2"],
                    sparkline: Self.series(starting: 0.45, count: 48, seed: &s, drift: 0.10),
                    value: 12_400, threshold: 20_000,
                    url: URL(string: "https://app.datadoghq.com/monitors/1003")),
            Monitor(id: 1004,
                    name: "auth-svc · CPU",
                    state: .warn,
                    priority: .p3,
                    firingSince: now.addingTimeInterval(-90),
                    triggeredHosts: ["auth-1", "auth-2"],
                    sparkline: Self.series(starting: 0.50, count: 48, seed: &s, drift: 0.08),
                    value: 78, threshold: 85,
                    url: URL(string: "https://app.datadoghq.com/monitors/1004")),
            Monitor(id: 1005,
                    name: "search · index lag",
                    state: .ok,
                    priority: .p4,
                    firingSince: nil, triggeredHosts: [],
                    sparkline: Self.series(starting: 0.32, count: 48, seed: &s, drift: 0.05),
                    value: 1.2, threshold: 5.0,
                    url: URL(string: "https://app.datadoghq.com/monitors/1005")),
            Monitor(id: 1006,
                    name: "billing · job duration",
                    state: .noData,
                    priority: .p3,
                    firingSince: nil, triggeredHosts: [],
                    sparkline: [],
                    value: nil, threshold: nil,
                    url: URL(string: "https://app.datadoghq.com/monitors/1006")),
        ]
        self.incidents = [
            Incident(id: "IR-482", title: "Payments degraded · LATAM",
                     severity: .sev2, openedAt: now.addingTimeInterval(-1860),
                     url: URL(string: "https://app.datadoghq.com/incidents/482")),
            Incident(id: "IR-481", title: "Checkout 5xx spike",
                     severity: .sev3, openedAt: now.addingTimeInterval(-5400),
                     url: URL(string: "https://app.datadoghq.com/incidents/481")),
        ]
    }

    func fetchSnapshot(previous: Snapshot?) async throws -> Snapshot {
        monitors = monitors.map { m in
            Monitor(
                id: m.id, name: m.name, state: m.state, priority: m.priority,
                firingSince: m.firingSince, triggeredHosts: m.triggeredHosts,
                sparkline: Self.roll(m.sparkline, seed: &seed, drift: 0.12),
                value: m.value.map { $0 + Double(Int(nextRand(&seed) % 5)) - 2 },
                threshold: m.threshold, url: m.url
            )
        }
        return Snapshot(
            monitors: monitors,
            incidents: incidents,
            activity: previous?.activity ?? [],
            lastRefresh: Date(),
            orgName: sourceName,
            connected: true,
            sampleData: true
        )
    }

    func mute(monitorID: Int, until: Date?) async throws {
        monitors = monitors.map { m in
            guard m.id == monitorID else { return m }
            return Monitor(
                id: m.id, name: m.name, state: .muted, priority: m.priority,
                firingSince: nil, triggeredHosts: m.triggeredHosts,
                sparkline: m.sparkline, value: m.value, threshold: m.threshold, url: m.url
            )
        }
    }

    // MARK: - Series generation

    private static func series(starting: Double, count: Int, seed: inout UInt64, drift: Double) -> [Double] {
        var out: [Double] = []
        out.reserveCapacity(count)
        var v = starting
        for _ in 0..<count {
            let r = Double(nextRand(&seed) % 1000) / 1000.0 - 0.5
            v = max(0.05, min(0.95, v + r * drift))
            out.append(v)
        }
        return out
    }

    private static func roll(_ s: [Double], seed: inout UInt64, drift: Double) -> [Double] {
        guard let last = s.last else { return s }
        let r = Double(nextRand(&seed) % 1000) / 1000.0 - 0.5
        let next = max(0.05, min(0.95, last + r * drift))
        return Array(s.dropFirst()) + [next]
    }
}

// xorshift; trivial, deterministic, plenty for a mock.
private func nextRand(_ s: inout UInt64) -> UInt64 {
    s ^= s << 13
    s ^= s >> 7
    s ^= s << 17
    return s
}
