import SwiftUI

struct PortfolioView: View {
    @EnvironmentObject var portfolio: PortfolioStore
    @EnvironmentObject var market: MarketDataService
    @State private var showReset = false
    var body: some View {
        List {
            Section("Account") {
                LabeledContent("Portfolio Value", value: portfolio.portfolioValue(quotes: market.quotes).formatted(.currency(code: "USD")))
                LabeledContent("Buying Power", value: portfolio.cash.formatted(.currency(code: "USD")))
                LabeledContent("Starting Balance", value: "$10,000.00")
            }
            Section("Open Positions") {
                if portfolio.positions.isEmpty { Text("No open positions").foregroundStyle(.secondary) }
                ForEach(portfolio.positions) { p in
                    if let a = Asset.universe.first(where: { $0.id == p.assetID }) {
                        NavigationLink(value: a) { PositionRow(position: p, asset: a, price: market.quotes[a.id]?.price ?? p.averagePrice) }
                    }
                }
            }
            Section { Button("Reset Paper Account", role: .destructive) { showReset = true } }
        }
        .navigationTitle("Portfolio")
        .navigationDestination(for: Asset.self) { AssetDetailView(asset: $0) }
        .alert("Reset to $10,000?", isPresented: $showReset) { Button("Reset", role: .destructive) { portfolio.reset() }; Button("Cancel", role: .cancel) {} } message: { Text("This deletes all paper positions and trade history.") }
    }
}
