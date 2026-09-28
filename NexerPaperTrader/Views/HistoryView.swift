import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var portfolio: PortfolioStore
    var body: some View {
        List {
            Section("Orders") {
                if portfolio.orders.isEmpty { Text("No orders yet").foregroundStyle(.secondary) }
                ForEach(portfolio.orders) { o in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("\(o.side.rawValue.capitalized) \(display(o.assetID))").font(.headline); Spacer(); Text(o.fillPrice?.formatted(.currency(code: "USD")) ?? "—") }
                        Text("\(o.quantity, specifier: "%.6f") units • \(o.createdAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Closed Trades") {
                if portfolio.closedTrades.isEmpty { Text("No closed positions yet").foregroundStyle(.secondary) }
                ForEach(portfolio.closedTrades) { t in
                    HStack {
                        VStack(alignment: .leading) { Text(display(t.assetID)).font(.headline); Text(t.closedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text("\(t.realizedPL >= 0 ? "+" : "")\(t.realizedPL, format: .currency(code: "USD"))").foregroundStyle(t.realizedPL >= 0 ? .green : .red)
                    }
                }
            }
        }.navigationTitle("History")
    }
    func display(_ id: String) -> String { Asset.universe.first(where: { $0.id == id })?.displaySymbol ?? id }
}
