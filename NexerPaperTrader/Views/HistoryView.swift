import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var portfolio: PortfolioStore
    @EnvironmentObject var market: MarketDataService

    var body: some View {
        List {
            Section("Orders") {
                if portfolio.orders.isEmpty {
                    Text("No orders yet").foregroundStyle(.secondary)
                }

                ForEach(portfolio.orders) { order in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("\(order.side.rawValue.capitalized) \(display(order.assetID))")
                                .font(.headline)
                            Spacer()
                            statusBadge(order.status)
                        }

                        HStack {
                            Text("\(order.quantity, specifier: "%.6f") units")
                            Spacer()
                            if let fill = order.fillPrice {
                                Text("Fill \(formatPrice(fill, assetID: order.assetID))")
                            } else if let requested = order.requestedPrice {
                                Text("Limit \(formatPrice(requested, assetID: order.assetID))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(order.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if order.status == .open {
                            Button(role: .destructive) {
                                _ = portfolio.cancelOrder(id: order.id)
                            } label: {
                                Label("Cancel Order", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Closed Long Trades") {
                if portfolio.closedTrades.isEmpty {
                    Text("No closed longs yet").foregroundStyle(.secondary)
                }

                ForEach(portfolio.closedTrades) { trade in
                    closedRow(symbol: display(trade.assetID), date: trade.closedAt, pl: trade.realizedPL, label: "LONG")
                }
            }

            Section("Closed Short Trades") {
                if portfolio.closedShortTrades.isEmpty {
                    Text("No closed paper shorts yet").foregroundStyle(.secondary)
                }

                ForEach(portfolio.closedShortTrades) { trade in
                    closedRow(symbol: display(trade.assetID), date: trade.closedAt, pl: trade.realizedPL, label: "SHORT")
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            if portfolio.orders.contains(where: { $0.status == .open }) {
                Button("Cancel All", role: .destructive) { portfolio.cancelAllOpenOrders() }
            }
        }
    }

    private func closedRow(symbol: String, date: Date, pl: Double, label: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                HStack {
                    Text(symbol).font(.headline)
                    Text(label).font(.caption2.bold()).foregroundStyle(label == "SHORT" ? .red : .green)
                }
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(pl >= 0 ? "+" : "")\(pl, format: .currency(code: "USD"))")
                .foregroundStyle(pl >= 0 ? .green : .red)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: OrderStatus) -> some View {
        let title: String = {
            switch status {
            case .filled: return "FILLED"
            case .open: return "OPEN"
            case .cancelled: return "CANCELLED"
            }
        }()

        let color: Color = {
            switch status {
            case .filled: return .green
            case .open: return .orange
            case .cancelled: return .secondary
            }
        }()

        Text(title).font(.caption2.bold()).foregroundStyle(color)
    }

    private func display(_ id: String) -> String {
        market.asset(forID: id)?.displaySymbol ?? id
    }

    private func formatPrice(_ price: Double, assetID: String) -> String {
        guard let asset = market.asset(forID: assetID) else { return String(format: "%.4f", price) }
        if asset.type == .forex { return String(format: "%.5f", price) }
        if asset.type == .crypto && price < 1 { return String(format: "$%.6f", price) }
        return price.formatted(.currency(code: "USD"))
    }
}
