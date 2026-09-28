import SwiftUI

struct AssetDetailView: View {
    @EnvironmentObject var market: MarketDataService
    @EnvironmentObject var portfolio: PortfolioStore
    let asset: Asset
    @State private var candles: [Candle] = []
    @State private var range = "1mo"
    @State private var loading = true
    @State private var showTrade = false
    @State private var side: OrderSide = .buy

    private var q: Quote? { market.quotes[asset.id] }
    private var tech: TechnicalSnapshot { Indicators.snapshot(candles) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).foregroundStyle(.secondary)
                    Text(q?.price.formatted(.currency(code: "USD")) ?? (candles.last?.close.formatted(.currency(code: "USD")) ?? "—"))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                    if let q { Text("\(q.changePercent >= 0 ? "+" : "")\(q.changePercent, specifier: "%.2f")%").foregroundStyle(q.changePercent >= 0 ? .green : .red) }
                }

                Picker("Range", selection: $range) {
                    Text("1D").tag("1d"); Text("5D").tag("5d"); Text("1M").tag("1mo"); Text("3M").tag("3mo"); Text("1Y").tag("1y")
                }.pickerStyle(.segmented).onChange(of: range) { _, _ in Task { await loadCandles() } }

                if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 260) }
                else { CandlestickChartView(candles: candles).frame(height: 280) }

                if let pos = portfolio.position(for: asset.id) {
                    let price = q?.price ?? candles.last?.close ?? pos.averagePrice
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Your Position")
                        HStack { StatPill(title: "Market Value", value: (pos.quantity * price).formatted(.currency(code: "USD"))); StatPill(title: "Average Cost", value: pos.averagePrice.formatted(.currency(code: "USD"))) }
                        HStack { StatPill(title: "Quantity", value: String(format: "%.5f", pos.quantity)); StatPill(title: "Return", value: String(format: "%+.2f%%", ((price-pos.averagePrice)/pos.averagePrice)*100)) }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Technical Analysis")
                    HStack { StatPill(title: "Trend", value: tech.trend); StatPill(title: "RSI 14", value: tech.rsi.map { String(format: "%.1f", $0) } ?? "—") }
                    HStack { StatPill(title: "MACD", value: tech.macd.map { String(format: "%.3f", $0) } ?? "—"); StatPill(title: "Histogram", value: tech.histogram.map { String(format: "%+.3f", $0) } ?? "—") }
                    HStack { StatPill(title: "EMA 20", value: tech.ema20?.formatted(.currency(code: "USD")) ?? "—"); StatPill(title: "EMA 50", value: tech.ema50?.formatted(.currency(code: "USD")) ?? "—") }
                    if !tech.patterns.isEmpty { Text("Patterns: \(tech.patterns.joined(separator: ", "))").font(.subheadline) }
                    Text("Indicators describe the chart; they do not guarantee future price movement.").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button { side = .buy; showTrade = true } label: { Text("Buy").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(.green)
                    Button { side = .sell; showTrade = true } label: { Text("Sell").frame(maxWidth: .infinity).padding(.vertical, 8) }.buttonStyle(.borderedProminent).tint(.red).disabled(portfolio.position(for: asset.id) == nil)
                }
            }.padding()
        }
        .navigationTitle(asset.displaySymbol).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTrade) { TradeTicketView(asset: asset, initialSide: side) }
        .task { _ = await market.quote(for: asset); await loadCandles() }
    }

    func loadCandles() async {
        loading = true
        let interval: String = range == "1d" ? "5m" : range == "5d" ? "15m" : range == "1y" ? "1d" : "1h"
        do { candles = try await market.fetchCandles(symbol: asset.symbol, range: range, interval: interval) } catch { }
        loading = false
    }
}
