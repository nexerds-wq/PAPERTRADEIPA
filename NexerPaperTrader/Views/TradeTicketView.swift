import SwiftUI

struct TradeTicketView: View {
    @EnvironmentObject var portfolio: PortfolioStore
    @EnvironmentObject var market: MarketDataService
    @Environment(\.dismiss) var dismiss
    let asset: Asset

    @State var side: OrderSide
    @State private var orderType: OrderType = .market
    @State private var dollars = ""
    @State private var limitPriceText = ""
    @State private var error: String?
    @State private var confirmed = false

    init(asset: Asset, initialSide: OrderSide) {
        self.asset = asset
        _side = State(initialValue: initialSide)
    }

    private var price: Double { market.quotes[asset.id]?.price ?? 0 }
    private var amount: Double { Double(dollars) ?? 0 }
    private var limitPrice: Double { Double(limitPriceText) ?? 0 }
    private var referencePrice: Double { orderType == .limit && limitPrice > 0 ? limitPrice : price }
    private var qty: Double { referencePrice > 0 ? amount / referencePrice : 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Side", selection: $side) {
                        Text("Buy").tag(OrderSide.buy)
                        Text("Sell").tag(OrderSide.sell)
                    }
                    .pickerStyle(.segmented)

                    LabeledContent("Current Price", value: formattedPrice(price))

                    if side == .buy {
                        LabeledContent("Buying Power", value: portfolio.cash.formatted(.currency(code: "USD")))
                    } else if let p = portfolio.position(for: asset.id) {
                        LabeledContent("Owned", value: String(format: "%.6f", p.quantity))
                    }
                }

                Section("Order") {
                    Picker("Order Type", selection: $orderType) {
                        Text("Market").tag(OrderType.market)
                        Text("Limit").tag(OrderType.limit)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("$").foregroundStyle(.secondary)
                        TextField("Amount", text: $dollars).keyboardType(.decimalPad)
                    }

                    if orderType == .limit {
                        HStack {
                            Text("Limit Price")
                            Spacer()
                            TextField("0.00", text: $limitPriceText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                    LabeledContent("Estimated Quantity", value: String(format: "%.6f", qty))
                }

                if let error {
                    Text(error).foregroundStyle(.red)
                }

                Section {
                    Button(buttonTitle) { place() }
                        .frame(maxWidth: .infinity)
                        .disabled(amount <= 0 || price <= 0 || (orderType == .limit && limitPrice <= 0))
                }

                Section {
                    Text(orderType == .market
                         ? "Paper money only. Market orders fill using the current paper price."
                         : "Paper money only. Limit orders stay open until the paper market price reaches your limit or you cancel the order.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("\(side == .buy ? "Buy" : "Sell") \(asset.displaySymbol)")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .onAppear {
                if price > 0 { limitPriceText = String(format: "%.4f", price) }
            }
            .alert(orderType == .market ? "Paper Order Filled" : "Limit Order Placed", isPresented: $confirmed) {
                Button("Done") { dismiss() }
            } message: {
                Text(orderType == .market
                     ? "Your fake-money order filled at the current paper price."
                     : "Your fake-money order is now pending. You can cancel it from History before it fills.")
            }
        }
    }

    private var buttonTitle: String {
        if orderType == .limit {
            return side == .buy ? "Place Limit Buy" : "Place Limit Sell"
        }
        return side == .buy ? "Place Paper Buy" : "Place Paper Sell"
    }

    private func formattedPrice(_ value: Double) -> String {
        if asset.type == .forex { return String(format: "%.5f", value) }
        if asset.type == .crypto && value < 1 { return String(format: "$%.6f", value) }
        return value.formatted(.currency(code: "USD"))
    }

    func place() {
        do {
            if orderType == .limit {
                if side == .buy {
                    try portfolio.placeLimitOrder(asset: asset, side: .buy, dollars: amount, quantity: nil, limitPrice: limitPrice)
                } else {
                    try portfolio.placeLimitOrder(asset: asset, side: .sell, dollars: nil, quantity: qty, limitPrice: limitPrice)
                }
            } else {
                if side == .buy {
                    try portfolio.placeMarketOrder(asset: asset, side: .buy, dollars: amount, quantity: nil, price: price)
                } else {
                    try portfolio.placeMarketOrder(asset: asset, side: .sell, dollars: nil, quantity: qty, price: price)
                }
            }
            confirmed = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}
