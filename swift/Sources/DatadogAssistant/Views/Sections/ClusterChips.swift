import SwiftUI

/// Blast radius row: services with ≥2 firing monitors, so "is payments on
/// fire or is this one bad host?" is answered before reading a single row.
struct ClusterChips: View {
    let clusters: [Snapshot.Cluster]

    var body: some View {
        if !clusters.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(clusters) { cluster in
                        chip(cluster)
                    }
                }
            }
        }
    }

    private func chip(_ cluster: Snapshot.Cluster) -> some View {
        let tint = cluster.alerting > 0 ? Theme.alert : Theme.warn
        return HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(cluster.service)
                .font(.system(size: 11, weight: .semibold))
            Text("\(cluster.count) firing")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .opacity(0.8)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(
            Capsule().fill(tint.opacity(0.14))
                .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
        )
    }
}
