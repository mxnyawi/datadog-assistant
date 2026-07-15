import SwiftUI

/// Starred monitors pinned to the top of the Monitors tab, whatever their
/// state — the handful you actually own stay in view instead of scrolling
/// away into their state groups. Hidden entirely when nothing is starred.
struct FavoritesSection: View {
    let snapshot: Snapshot
    @ObservedObject private var prefs = UIPreferences.shared

    var body: some View {
        let favorites = snapshot.monitors
            .filter { prefs.isFavorite($0.id) }
            .sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }
        if !favorites.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.warn)
                    SectionHeader(title: "Favorites", count: favorites.count)
                        .padding(.leading, 0)
                }
                InsetCard {
                    ForEach(favorites, id: \.id) { MonitorRow(monitor: $0) }
                }
            }
        }
    }
}
