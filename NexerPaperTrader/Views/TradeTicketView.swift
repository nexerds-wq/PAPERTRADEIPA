import SwiftUI

struct TradeTicketView: View {
    @EnvironmentObject var portfolio: PortfolioStore
    @EnvironmentObject var market: MarketDataService
    @Environment(\.dismiss) var dismiss
    let asset: Asset
    @State var side: OrderSide
    @State private var dollars = ""
    @State private var error: String?
    @State private var confirmed = false

    init(asset: Asset, initialSide: OrderSide) { self.asset = asset; _side = State(initialValue: initialSide) }

    private var price: Double { market.quotes[asset.id]?.price ?? 0 }
    private var amount: Double { Double(dollars) ?? 0 }
    private var qty: Double { price > 0 ? amount / price : 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Side", selection: $side) { Text("Buy").tag(OrderSide.buy); Text("Sell").tag(OrderSide.sell) }.pickerStyle(.segmented)
                    LabeledContent("Current Price", value: price.formatted(.currency(code: "USD")))
                    if side == .buy { LabeledContent("Buying Power", value: portfolio.cash.formatted(.currency(code: "USD"))) }
                    else if let p = portfolio.position(for: asset.id) { LabeledContent("Owned", value: String(format: "%.6f", p.quantity)) }
                }
                Section("Order") {
                    HStack { Text("$").foregroundStyle(.secondary); TextField("Amount", text: $dollars).keyboardType(.decimalPad) }
                    LabeledContent("Estimated Quantity", value: String(format: "%.6f", qty))
                    LabeledContent("Order Type", value: "Market")
                }
                if let error { Text(error).foregroundStyle(.red) }
                Section { Button(side == .buy ? "Place Paper Buy" : "Place Paper Sell") { place() }.frame(maxWidth: .infinity).disabled(amount <= 0 || price <= 0) }
                Section { Text("Paper money only. This order does not connect to a brokerage or use real money.").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("\(side == .buy ? "Buy" : "Sell") \(asset.displaySymbol)")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .alert("Order Filled", isPresented: $confirmed) { Button("Done") { dismiss() } } message: { Text("Your fake-money order was filled at the current paper price.") }
        }
    }

    func place() {
        do {
            if side == .buy { try portfolio.placeMarketOrder(asset: asset, side: .buy, dollars: amount, quantity: nil, price: price) }
            else { try portfolio.placeMarketOrder(asset: asset, side: .sell, dollars: nil, quantity: qty, price: price) }
            confirmed = true
        } catch { self.error = error.localizedDescription }
    }
}
