import SwiftUI

@main
struct NexerPaperTraderApp: App {
    @StateObject private var portfolio = PortfolioStore()
    @StateObject private var market = MarketDataService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(portfolio)
                .environmentObject(market)
                .preferredColorScheme(.dark)
        }
    }
}
