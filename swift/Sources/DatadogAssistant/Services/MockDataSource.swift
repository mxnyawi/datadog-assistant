import Foundation

/// Renders a believable Snapshot without API keys so the panel has something
/// to show before credentials are configured. Advances one tick per fetch;
/// occasionally mutes/unmutes nothing — states are stable so screenshots and
/// design review are reproducible.
final class MockDataSource: DataSource {
    /// DD_DEMO=1 turns the static sample into a scripted incident arc for
    /// live demos: calm → PR merges (t+40s) → P1 fires (t+60s) → second
    /// monitor follows (t+90s) → recovery (t+210s). Every feature — suspect
    /// correlation, deploy markers, detection latency, recovery stats —
    /// triggers organically from the same transitions real data would cause.
    private let demoMode = ProcessInfo.processInfo.environment["DD_DEMO"] == "1"
    private let launchedAt = Date()

    private var seed: UInt64 = 0x5EED
    private var monitors: [Monitor]
    private var incidents: [Incident]
    private var deploys: [DeployEvent]
    private var ciRuns: [CIRun]

    var sourceName: String { demoMode ? "Demo" : "Sample data" }

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
                    url: URL(string: "https://app.datadoghq.com/monitors/1001"),
                    service: "payments", tags: ["team:payments", "env:prod", "service:payments"], delta: 3.2, thresholdPosition: 0.55),
            Monitor(id: 1002,
                    name: "checkout · 5xx rate",
                    state: .alert,
                    priority: .p2,
                    firingSince: now.addingTimeInterval(-3120),
                    triggeredHosts: ["edge-3"],
                    sparkline: Self.series(starting: 0.55, count: 48, seed: &s, drift: 0.20),
                    value: 4.1, threshold: 1.0,
                    url: URL(string: "https://app.datadoghq.com/monitors/1002"),
                    service: "payments", tags: ["team:payments", "env:prod", "service:checkout"], delta: 4.8, thresholdPosition: 0.30),
            Monitor(id: 1003,
                    name: "kafka · consumer lag",
                    state: .warn,
                    priority: .p3,
                    firingSince: now.addingTimeInterval(-180),
                    triggeredHosts: ["kafka-2"],
                    sparkline: Self.series(starting: 0.45, count: 48, seed: &s, drift: 0.10),
                    value: 12_400, threshold: 20_000,
                    url: URL(string: "https://app.datadoghq.com/monitors/1003"),
                    service: "kafka", tags: ["team:platform", "env:prod", "service:kafka"], delta: 1.4, thresholdPosition: 0.85),
            Monitor(id: 1004,
                    name: "auth-svc · CPU",
                    state: .warn,
                    priority: .p3,
                    firingSince: now.addingTimeInterval(-90),
                    triggeredHosts: ["auth-1", "auth-2"],
                    sparkline: Self.series(starting: 0.50, count: 48, seed: &s, drift: 0.08),
                    value: 78, threshold: 85,
                    url: URL(string: "https://app.datadoghq.com/monitors/1004"),
                    service: "auth", tags: ["team:identity", "env:prod", "service:auth"], delta: 1.1, thresholdPosition: 0.80),
            Monitor(id: 1005,
                    name: "search · index lag",
                    state: .ok,
                    priority: .p4,
                    firingSince: nil, triggeredHosts: [],
                    sparkline: Self.series(starting: 0.32, count: 48, seed: &s, drift: 0.05),
                    value: 1.2, threshold: 5.0,
                    url: URL(string: "https://app.datadoghq.com/monitors/1005"),
                    tags: ["team:search", "env:prod", "service:search"]),
            Monitor(id: 1006,
                    name: "billing · job duration",
                    state: .noData,
                    priority: .p3,
                    firingSince: nil, triggeredHosts: [],
                    sparkline: [],
                    value: nil, threshold: nil,
                    url: URL(string: "https://app.datadoghq.com/monitors/1006"),
                    tags: ["team:billing", "env:prod", "service:billing"]),
        ]
        self.incidents = [
            Incident(id: "IR-482", title: "Payments degraded · LATAM",
                     severity: .sev2, openedAt: now.addingTimeInterval(-1860),
                     url: URL(string: "https://app.datadoghq.com/incidents/482")),
            Incident(id: "IR-481", title: "Checkout 5xx spike",
                     severity: .sev3, openedAt: now.addingTimeInterval(-5400),
                     url: URL(string: "https://app.datadoghq.com/incidents/481")),
        ]
        // PR #482 lands 14 minutes before payments-api starts firing (-720s),
        // so the suspect correlation has something to find in sample mode.
        self.deploys = [
            DeployEvent(id: "gh-acme/payments-api-482",
                        title: "PR #482 · raise cache TTL for quotes",
                        source: .github,
                        occurredAt: now.addingTimeInterval(-720 - 14 * 60),
                        url: URL(string: "https://github.com/acme/payments-api/pull/482"),
                        service: "payments"),
            DeployEvent(id: "dd-90211",
                        title: "Deploy checkout v2025.06.30-2",
                        source: .datadog,
                        occurredAt: now.addingTimeInterval(-3 * 3600),
                        url: URL(string: "https://app.datadoghq.com/event/explorer"),
                        service: "checkout"),
            DeployEvent(id: "gh-acme/platform-479",
                        title: "PR #479 · bump base image to bookworm",
                        source: .github,
                        occurredAt: now.addingTimeInterval(-5 * 3600),
                        url: URL(string: "https://github.com/acme/platform/pull/479"),
                        service: nil),
        ]
        self.ciRuns = [
            CIRun(id: "run-acme/payments-api-1",
                  repo: "acme/payments-api", workflow: "deploy-prod",
                  state: .failure, branch: "main",
                  startedAt: now.addingTimeInterval(-18 * 60),
                  url: URL(string: "https://github.com/acme/payments-api/actions")),
            CIRun(id: "run-acme/payments-api-2",
                  repo: "acme/payments-api", workflow: "tests",
                  state: .success, branch: "main",
                  startedAt: now.addingTimeInterval(-42 * 60),
                  url: URL(string: "https://github.com/acme/payments-api/actions")),
            CIRun(id: "run-acme/platform-3",
                  repo: "acme/platform", workflow: "ci",
                  state: .running, branch: "main",
                  startedAt: now.addingTimeInterval(-4 * 60),
                  url: URL(string: "https://github.com/acme/platform/actions")),
        ]
    }

    func fetchSnapshot(previous: Snapshot?) async throws -> Snapshot {
        if demoMode { applyDemoScript() }
        monitors = monitors.map { m in
            var monitor = m
            monitor.sparkline = Self.roll(m.sparkline, seed: &seed, drift: 0.12)
            monitor.value = m.value.map { $0 + Double(Int(nextRand(&seed) % 5)) - 2 }
            return monitor
        }
        return Snapshot(
            monitors: monitors,
            incidents: incidents,
            deploys: deploys,
            ciRuns: ciRuns,
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
                sparkline: m.sparkline, value: m.value, threshold: m.threshold,
                url: m.url, service: m.service, tags: m.tags, delta: m.delta,
                thresholdPosition: m.thresholdPosition
            )
        }
    }

    // MARK: - Demo script

    private static let demoDeployAt: TimeInterval = 40
    private static let demoFireAt: TimeInterval = 60
    private static let demoSecondFireAt: TimeInterval = 90
    private static let demoRecoverAt: TimeInterval = 210

    /// Rebuilds the payments/checkout monitors from the arc's clock. States
    /// derive from elapsed time, so pausing on a slide doesn't break the story.
    private func applyDemoScript() {
        let elapsed = Date().timeIntervalSince(launchedAt)

        if elapsed >= Self.demoDeployAt, !deploys.contains(where: { $0.id == "demo-pr-482" }) {
            deploys.insert(DeployEvent(
                id: "demo-pr-482",
                title: "PR #482 · raise cache TTL for quotes",
                source: .github,
                occurredAt: launchedAt.addingTimeInterval(Self.demoDeployAt),
                url: URL(string: "https://github.com/acme/payments-api/pull/482"),
                service: "payments"), at: 0)
        }

        let paymentsFiring = elapsed >= Self.demoFireAt && elapsed < Self.demoRecoverAt
        let checkoutFiring = elapsed >= Self.demoSecondFireAt && elapsed < Self.demoRecoverAt

        monitors = monitors.map { m in
            switch m.id {
            case 1001:
                return demoVariant(of: m, firing: paymentsFiring,
                                   since: launchedAt.addingTimeInterval(Self.demoFireAt),
                                   firingValue: min(842, 520 + (elapsed - Self.demoFireAt) * 6),
                                   calmValue: 210,
                                   hosts: ["prod-pay-7", "prod-pay-9"], delta: 3.2)
            case 1002:
                return demoVariant(of: m, firing: checkoutFiring,
                                   since: launchedAt.addingTimeInterval(Self.demoSecondFireAt),
                                   firingValue: 4.1, calmValue: 0.3,
                                   hosts: ["edge-3"], delta: 4.8)
            default:
                return m
            }
        }
    }

    /// Canonical hosts/delta are passed in rather than read from `m` — the
    /// previous pass may have blanked them while calm.
    private func demoVariant(of m: Monitor, firing: Bool, since: Date,
                             firingValue: Double, calmValue: Double,
                             hosts: [String], delta: Double) -> Monitor {
        Monitor(
            id: m.id, name: m.name,
            state: firing ? .alert : .ok,
            priority: m.priority,
            firingSince: firing ? since : nil,
            triggeredHosts: firing ? hosts : [],
            sparkline: m.sparkline,
            value: firing ? firingValue : calmValue,
            threshold: m.threshold,
            url: m.url, service: m.service, tags: m.tags,
            delta: firing ? delta : nil,
            thresholdPosition: m.thresholdPosition
        )
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
