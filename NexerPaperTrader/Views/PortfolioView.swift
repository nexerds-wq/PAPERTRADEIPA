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
                LabeledContent("Open Positions", value: "\(portfolio.exposureCount)")
            }

            Section("Long Positions") {
                if portfolio.positions.isEmpty {
                    Text("No open long positions").foregroundStyle(.secondary)
                }

                ForEach(portfolio.positions) { p in
                    if let asset = market.asset(forID: p.assetID) {
                        NavigationLink(value: asset) {
                            PositionRow(position: p, asset: asset, price: market.quotes[asset.id]?.price ?? p.averagePrice)
                        }
                    } else {
                        VStack(alignment: .leading) {
                            Text(p.assetID).font(.headline)
                            Text("Long \(p.quantity, specifier: "%.4f") @ \(p.averagePrice, format: .currency(code: "USD"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Short Positions") {
                if portfolio.shortPositions.isEmpty {
                    Text("No open paper shorts").foregroundStyle(.secondary)
                }

                ForEach(portfolio.shortPositions) { p in
                    let mark = market.quotes[p.assetID]?.price ?? p.averagePrice
                    let unrealized = (p.averagePrice - mark) * p.quantity
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(market.asset(forID: p.assetID)?.displaySymbol ?? p.assetID).font(.headline)
                            Spacer()
                            Text("SHORT").font(.caption.bold()).foregroundStyle(.red)
                        }
                        HStack {
                            Text("\(p.quantity, specifier: "%.4f") @ \(p.averagePrice, format: .currency(code: "USD"))")
                            Spacer()
                            Text("\(unrealized >= 0 ? "+" : "")\(unrealized, format: .currency(code: "USD"))")
                                .foregroundStyle(unrealized >= 0 ? .green : .red)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 3)
                }
            }

            Section {
                Button("Reset Paper Account", role: .destructive) { showReset = true }
            }
        }
        .navigationTitle("Portfolio")
        .navigationDestination(for: Asset.self) { AssetDetailView(asset: $0) }
        .alert("Reset to $10,000?", isPresented: $showReset) {
            Button("Reset", role: .destructive) { portfolio.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all paper positions and trade history.")
        }
        .task {
            while !Task.isCancelled {
                await refreshPositions()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @MainActor
    private func refreshPositions() async {
        let ids = Set(portfolio.positions.map(\.assetID) + portfolio.shortPositions.map(\.assetID))
        for id in ids {
            guard let asset = market.asset(forID: id) else { continue }
            _ = await market.quote(for: asset, force: true)
        }
        portfolio.evaluateOpenOrders(quotes: market.quotes)
    }
}
