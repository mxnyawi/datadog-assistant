import SwiftUI

/// Summary strip: alerting / warning / healthy counts as tap-to-drill tiles
/// (the iStat-style stat row). Tapping any tile jumps to the full list.
struct StateSection: View {
    let snapshot: Snapshot
    @Binding var tab: Tab

    var body: some View {
        HStack(spacing: 8) {
            StateCard(icon: "exclamationmark.octagon.fill",
                      title: "Alerting",
                      value: "\(snapshot.alerting.count)",
                      tint: Theme.alert) { tab = .list }
            StateCard(icon: "exclamationmark.triangle.fill",
                      title: "Warning",
                      value: "\(snapshot.warning.count)",
                      tint: Theme.warn) { tab = .list }
            StateCard(icon: "checkmark.circle.fill",
                      title: "Healthy",
                      value: "\(snapshot.healthy.count)",
                      tint: Theme.ok) { tab = .list }
        }
    }
}
