import SwiftUI

struct HomeView: View {
    @EnvironmentObject var portfolio: PortfolioStore
    @EnvironmentObject var market: MarketDataService
    @State private var refreshing = false

    private var value: Double { portfolio.portfolioValue(quotes: market.quotes) }
    private var totalPL: Double { value - 10_000 }
    private var movers: [Asset] {
        Asset.universe.filter { market.quotes[$0.id] != nil }
            .sorted { (market.quotes[$0.id]?.changePercent ?? 0) > (market.quotes[$1.id]?.changePercent ?? 0) }
            .prefix(5).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PORTFOLIO BALANCE").font(.caption).foregroundStyle(.secondary)
                    Text(value, format: .currency(code: "USD")).font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("\(totalPL >= 0 ? "+" : "")\(totalPL, format: .currency(code: "USD"))  •  \((totalPL / 10_000) * 100, specifier: "%.2f")% all time")
                        .font(.subheadline).foregroundStyle(totalPL >= 0 ? .green : .red)
                    HStack {
                        StatPill(title: "Buying Power", value: portfolio.cash.formatted(.currency(code: "USD")))
                        StatPill(title: "Invested", value: (value - portfolio.cash).formatted(.currency(code: "USD")))
                    }
                }
                .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 22))

                SectionTitle("Top Movers")
                if movers.isEmpty { ProgressView("Loading market data…") }
                ForEach(movers) { asset in
                    NavigationLink(value: asset) { AssetRow(asset: asset, quote: market.quotes[asset.id]) }
                        .buttonStyle(.plain)
                }

                SectionTitle("Your Investments")
                if portfolio.positions.isEmpty {
                    ContentUnavailableView("No Positions Yet", systemImage: "chart.xyaxis.line", description: Text("Open Markets and place a paper trade with your fake $10,000."))
                } else {
                    ForEach(portfolio.positions) { position in
                        if let asset = Asset.universe.first(where: { $0.id == position.assetID }) {
                            NavigationLink(value: asset) {
                                PositionRow(position: position, asset: asset, price: market.quotes[asset.id]?.price ?? position.averagePrice)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding()
        }
        .navigationTitle("Nexer Trading")
        .navigationDestination(for: Asset.self) { AssetDetailView(asset: $0) }
        .refreshable { await market.refreshUniverse() }
        .task {
            if market.quotes.isEmpty { await market.refreshUniverse() }

            var cycle = 0
            while !Task.isCancelled {
                await refreshPositions()
                cycle += 1

                // Keep the broader market list moving too, without hammering the free endpoint.
                if cycle >= 9 {
                    cycle = 0
                    await market.refreshUniverse()
                }

                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    @MainActor
    private func refreshPositions() async {
        for position in portfolio.positions {
            guard let asset = Asset.universe.first(where: { $0.id == position.assetID }) else { continue }
            _ = await market.quote(for: asset, force: true)
        }
        portfolio.evaluateOpenOrders(quotes: market.quotes)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.title2.bold()) }
}

struct StatPill: View {
    let title: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct AssetRow: View {
    let asset: Asset; let quote: Quote?
    var body: some View {
        HStack {
            VStack(alignment: .leading) { Text(asset.displaySymbol).font(.headline); Text(asset.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            VStack(alignment: .trailing) {
                Text(quote?.price.formatted(.currency(code: "USD")) ?? "—").font(.headline)
                if let q = quote { Text("\(q.changePercent >= 0 ? "+" : "")\(q.changePercent, specifier: "%.2f")%").foregroundStyle(q.changePercent >= 0 ? .green : .red).font(.subheadline) }
            }
        }.padding(.vertical, 7)
    }
}

struct PositionRow: View {
    let position: Position; let asset: Asset; let price: Double
    var body: some View {
        let value = position.quantity * price
        let pl = position.quantity * (price - position.averagePrice)
        return HStack {
            VStack(alignment: .leading) { Text(asset.displaySymbol).font(.headline); Text("\(position.quantity, specifier: "%.4f") units").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            VStack(alignment: .trailing) { Text(value, format: .currency(code: "USD")); Text("\(pl >= 0 ? "+" : "")\(pl, format: .currency(code: "USD"))").foregroundStyle(pl >= 0 ? .green : .red).font(.caption) }
        }.padding(.vertical, 7)
    }
}
