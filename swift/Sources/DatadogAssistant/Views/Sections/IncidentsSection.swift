import SwiftUI

struct IncidentsSection: View {
    let snapshot: Snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if !snapshot.incidents.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: "Active Incidents", count: snapshot.incidents.count)
                InsetCard {
                    HStack(spacing: 8) {
                        ForEach(snapshot.incidents.prefix(5), id: \.id) {
                            IncidentPill(incident: $0)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            // Bridge the section's appearance under the dashboard's snapshot
            // spring (RootView.animatedContent) instead of popping in.
            .transition(reduceMotion
                ? .opacity
                : .opacity.combined(with: .move(edge: .top)))
        }
        // No incidents → no section. Absence beats a "None open." line.
    }
}
