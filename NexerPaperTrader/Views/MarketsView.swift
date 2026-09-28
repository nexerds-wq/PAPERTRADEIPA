import SwiftUI

struct MarketsView: View {
    @EnvironmentObject var market: MarketDataService
    @State private var query = ""
    @State private var type: AssetType? = nil

    private var filtered: [Asset] {
        Asset.universe.filter { asset in
            (type == nil || asset.type == type) && (query.isEmpty || asset.name.localizedCaseInsensitiveContains(query) || asset.displaySymbol.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    FilterChip(name: "All", selected: type == nil) { type = nil }
                    ForEach(AssetType.allCases) { t in FilterChip(name: t.rawValue, selected: type == t) { type = t } }
                }
            }.listRowInsets(EdgeInsets()).padding(.vertical, 6)
            ForEach(filtered) { asset in
                NavigationLink(value: asset) { AssetRow(asset: asset, quote: market.quotes[asset.id]) }
            }
        }
        .navigationTitle("Markets")
        .searchable(text: $query, prompt: "AAPL, Bitcoin, EUR/USD…")
        .navigationDestination(for: Asset.self) { AssetDetailView(asset: $0) }
        .refreshable { await market.refreshUniverse() }
        .task { if market.quotes.isEmpty { await market.refreshUniverse() } }
    }
}

struct FilterChip: View {
    let name: String; let selected: Bool; let action: () -> Void
    var body: some View { Button(name, action: action).buttonStyle(.borderedProminent).tint(selected ? .green : .gray.opacity(0.35)) }
}
