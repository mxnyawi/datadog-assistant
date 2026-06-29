import SwiftUI

struct RootView: View {
    @EnvironmentObject var dataSource: MockDataSource
    @State private var tab: Tab = .monitors

    var body: some View {
        let snapshot = dataSource.snapshot
        VStack(spacing: 16) {
            HeaderView(snapshot: snapshot)
            TabStrip(selected: $tab)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    StateSection(snapshot: snapshot)
                    Divider().background(Theme.panelStroke)
                    ActiveMonitorsSection(snapshot: snapshot)
                    Divider().background(Theme.panelStroke)
                    IncidentsSection(snapshot: snapshot)
                    Divider().background(Theme.panelStroke)
                    ActivitySection(snapshot: snapshot)
                }
                .padding(.vertical, 4)
            }

            FooterView()
        }
        .padding(16)
        .frame(width: 380)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}
