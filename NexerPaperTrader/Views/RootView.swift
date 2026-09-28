import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { MarketsView() }
                .tabItem { Label("Markets", systemImage: "chart.line.uptrend.xyaxis") }
            NavigationStack { PortfolioView() }
                .tabItem { Label("Portfolio", systemImage: "briefcase.fill") }
            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(.green)
    }
}
