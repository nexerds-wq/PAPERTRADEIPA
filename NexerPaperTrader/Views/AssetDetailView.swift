import SwiftUI

struct AssetDetailView: View {
    @EnvironmentObject var market: MarketDataService
    @EnvironmentObject var portfolio: PortfolioStore
    let asset: Asset

    @State private var candles: [Candle] = []
    @State private var signalCandles: [Candle] = []
    @State private var range = "1mo"
    @State private var loading = true
    @State private var showTrade = false
    @State private var side: OrderSide = .buy

    private var q: Quote? { market.quotes[asset.id] }
    private var tech: TechnicalSnapshot { Indicators.snapshot(signalCandles.isEmpty ? candles : signalCandles) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).foregroundStyle(.secondary)
                    Text(formattedPrice(q?.price ?? candles.last?.close))
                        .font(.system(size: 36, weight: .bold, design: .rounded))

                    if let q {
                        Text("\(q.changePercent >= 0 ? "+" : "")\(q.changePercent, specifier: "%.2f")%")
                            .foregroundStyle(q.changePercent >= 0 ? .green : .red)
                    }
                }

                signalCard

                Picker("Range", selection: $range) {
                    Text("1D").tag("1d")
                    Text("5D").tag("5d")
                    Text("1M").tag("1mo")
                    Text("3M").tag("3mo")
                    Text("1Y").tag("1y")
                }
                .pickerStyle(.segmented)
                .onChange(of: range) { _, _ in Task { await loadCandles() } }

                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    CandlestickChartView(candles: candles).frame(height: 280)
                }

                if let pos = portfolio.position(for: asset.id) {
                    let price = q?.price ?? candles.last?.close ?? pos.averagePrice
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Your Position")
                        HStack {
                            StatPill(title: "Market Value", value: (pos.quantity * price).formatted(.currency(code: "USD")))
                            StatPill(title: "Average Cost", value: pos.averagePrice.formatted(.currency(code: "USD")))
                        }
                        HStack {
                            StatPill(title: "Quantity", value: String(format: "%.5f", pos.quantity))
                            StatPill(title: "Return", value: String(format: "%+.2f%%", ((price-pos.averagePrice)/pos.averagePrice)*100))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle("Technical Analysis")
                    HStack {
                        StatPill(title: "Trend", value: tech.trend)
                        StatPill(title: "Strength", value: String(format: "%.0f/100", tech.trendStrength))
                    }
                    HStack {
                        StatPill(title: "RSI 14", value: tech.rsi.map { String(format: "%.1f", $0) } ?? "—")
                        StatPill(title: "MACD Hist", value: tech.histogram.map { String(format: "%+.3f", $0) } ?? "—")
                    }
                    HStack {
                        StatPill(title: "EMA 20", value: tech.ema20.map { formattedNumber($0) } ?? "—")
                        StatPill(title: "EMA 50", value: tech.ema50.map { formattedNumber($0) } ?? "—")
                    }
                    HStack {
                        StatPill(title: "EMA 200", value: tech.ema200.map { formattedNumber($0) } ?? "—")
                        StatPill(title: "20D Momentum", value: tech.momentum20.map { String(format: "%+.1f%%", $0) } ?? "—")
                    }

                    if !tech.patterns.isEmpty {
                        Text("Patterns: \(tech.patterns.joined(separator: ", "))").font(.subheadline)
                    }

                    Text("Signals use daily trend, RSI, MACD, moving averages, momentum and volatility. They can be wrong and do not guarantee profit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        side = .buy
                        showTrade = true
                    } label: {
                        Text("Buy").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        side = .sell
                        showTrade = true
                    } label: {
                        Text("Sell").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(portfolio.position(for: asset.id) == nil)
                }
            }
            .padding()
        }
        .navigationTitle(asset.displaySymbol)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTrade) {
            TradeTicketView(asset: asset, initialSide: side)
        }
        .task {
            _ = await market.quote(for: asset, force: true)
            await loadCandles()
            await loadSignalCandles()
            portfolio.evaluateOpenOrders(quotes: market.quotes)

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                _ = await market.quote(for: asset, force: true)
                portfolio.evaluateOpenOrders(quotes: market.quotes)
            }
        }
        .refreshable {
            _ = await market.quote(for: asset, force: true)
            await loadCandles()
            await loadSignalCandles()
            portfolio.evaluateOpenOrders(quotes: market.quotes)
        }
    }

    private var signalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("QUICK SIGNAL")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(tech.quickSignal.rawValue)
                        .font(.title2.bold())
                        .foregroundStyle(signalColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Confidence")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(tech.confidence)%")
                        .font(.title3.bold())
                }
            }

            HStack {
                Text("Score \(tech.signalScore)")
                Spacer()
                Text(tech.trend)
            }
            .font(.subheadline.bold())

            ForEach(Array(tech.reasons.prefix(4)), id: \.self) { reason in
                HStack(alignment: .top, spacing: 7) {
                    Circle().frame(width: 5, height: 5).padding(.top, 6)
                    Text(reason).font(.subheadline)
                }
            }

            Text("Paper-trading helper only. WAIT means the setup does not have enough agreement to force a trade.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var signalColor: Color {
        switch tech.quickSignal {
        case .strongBuy, .buy: return .green
        case .strongSell, .sell: return .red
        case .wait: return .orange
        }
    }

    func loadCandles() async {
        loading = true
        let interval: String = range == "1d" ? "5m" : range == "5d" ? "15m" : range == "1y" ? "1d" : "1h"
        do {
            candles = try await market.fetchCandles(symbol: asset.symbol, range: range, interval: interval)
        } catch { }
        loading = false
    }

    func loadSignalCandles() async {
        do {
            signalCandles = try await market.fetchCandles(symbol: asset.symbol, range: "1y", interval: "1d")
        } catch { }
    }

    private func formattedPrice(_ price: Double?) -> String {
        guard let price else { return "—" }
        if asset.type == .forex { return String(format: "%.5f", price) }
        if asset.type == .crypto && price < 1 { return String(format: "$%.6f", price) }
        return price.formatted(.currency(code: "USD"))
    }

    private func formattedNumber(_ value: Double) -> String {
        if asset.type == .forex { return String(format: "%.5f", value) }
        if asset.type == .crypto && value < 1 { return String(format: "$%.6f", value) }
        return value.formatted(.currency(code: "USD"))
    }
}