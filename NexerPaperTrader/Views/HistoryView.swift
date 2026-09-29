import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var portfolio: PortfolioStore

    var body: some View {
        List {
            Section("Orders") {
                if portfolio.orders.isEmpty {
                    Text("No orders yet").foregroundStyle(.secondary)
                }

                ForEach(portfolio.orders) { o in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("\(o.side.rawValue.capitalized) \(display(o.assetID))")
                                .font(.headline)
                            Spacer()
                            statusBadge(o.status)
                        }

                        HStack {
                            Text("\(o.quantity, specifier: "%.6f") units")
                            Spacer()
                            if let fill = o.fillPrice {
                                Text("Fill \(formatPrice(fill, assetID: o.assetID))")
                            } else if let requested = o.requestedPrice {
                                Text("Limit \(formatPrice(requested, assetID: o.assetID))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Text(o.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        if o.status == .open {
                            Button(role: .destructive) {
                                _ = portfolio.cancelOrder(id: o.id)
                            } label: {
                                Label("Cancel Order", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Closed Trades") {
                if portfolio.closedTrades.isEmpty {
                    Text("No closed positions yet").foregroundStyle(.secondary)
                }

                ForEach(portfolio.closedTrades) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(display(t.assetID)).font(.headline)
                            Text(t.closedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(t.realizedPL >= 0 ? "+" : "")\(t.realizedPL, format: .currency(code: "USD"))")
                            .foregroundStyle(t.realizedPL >= 0 ? .green : .red)
                    }
                }
            }
        }
        .navigationTitle("History")
        .toolbar {
            if portfolio.orders.contains(where: { $0.status == .open }) {
                Button("Cancel All", role: .destructive) {
                    portfolio.cancelAllOpenOrders()
                }
            }
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

        Text(title)
            .font(.caption2.bold())
            .foregroundStyle(color)
    }

    func display(_ id: String) -> String {
        Asset.universe.first(where: { $0.id == id })?.displaySymbol ?? id
    }

    func formatPrice(_ price: Double, assetID: String) -> String {
        guard let asset = Asset.universe.first(where: { $0.id == assetID }) else {
            return String(format: "%.4f", price)
        }
        if asset.type == .forex { return String(format: "%.5f", price) }
        if asset.type == .crypto && price < 1 { return String(format: "$%.6f", price) }
        return price.formatted(.currency(code: "USD"))
    }
}
