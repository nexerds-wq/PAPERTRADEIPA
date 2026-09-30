import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { StrategyLabView() }
                .tabItem { Label("Auto", systemImage: "bolt.fill") }
            NavigationStack { MarketsView() }
                .tabItem { Label("Markets", systemImage: "chart.line.uptrend.xyaxis") }
            NavigationStack { PortfolioView() }
                .tabItem { Label("Portfolio", systemImage: "briefcase.fill") }
            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(.green)
    }
}

struct StrategyLabView: View {
    @EnvironmentObject var market: MarketDataService
    @EnvironmentObject var portfolio: PortfolioStore
    @State private var loading = false
    @State private var signal = "—"
    @State private var momentum = 0.0
    @State private var strategyReturn = 0.0
    @State private var buyHoldReturn = 0.0
    @State private var maxDrawdown = 0.0
    @State private var years = 0.0
    @State private var status = "Run the test to load real historical SPY prices."
    @State private var paperMessage = ""

    private var spy: Asset? { Asset.universe.first { $0.id == "SPY" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("12-Month Trend").font(.largeTitle.bold())
                Text("Research-style time-series momentum test. If SPY is above its price about 12 months ago, the model is LONG. If not, it moves to CASH. Paper trading only.")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("CURRENT SIGNAL").font(.caption).foregroundStyle(.secondary)
                    Text(signal).font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(signal == "LONG" ? .green : signal == "CASH" ? .orange : .secondary)
                    Text("12-month momentum: \(momentum * 100, specifier: "%.2f")%")
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 20))

                HStack {
                    metric("Strategy", strategyReturn)
                    metric("Buy & Hold", buyHoldReturn)
                }
                HStack {
                    metric("Max DD", maxDrawdown)
                    VStack(alignment: .leading) {
                        Text("TEST WINDOW").font(.caption2).foregroundStyle(.secondary)
                        Text("\(years, specifier: "%.1f") yrs").font(.headline)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button {
                    Task { await runBacktest() }
                } label: {
                    HStack { Spacer(); if loading { ProgressView() } else { Image(systemName: "chart.xyaxis.line") }; Text(loading ? "Testing…" : "Run 20-Year Backtest").bold(); Spacer() }
                }
                .buttonStyle(.borderedProminent).tint(.green).disabled(loading)

                Button {
                    Task { await syncPaperTrade() }
                } label: {
                    HStack { Spacer(); Image(systemName: "bolt.fill"); Text("Follow Signal With Paper Money").bold(); Spacer() }
                }
                .buttonStyle(.bordered).disabled(loading || signal == "—")

                Text(status).font(.footnote).foregroundStyle(.secondary)
                if !paperMessage.isEmpty { Text(paperMessage).font(.footnote).foregroundStyle(.green) }

                Divider()
                Text("Evidence").font(.title2.bold())
                Text("This is based on the time-series momentum idea studied by Moskowitz, Ooi and Pedersen. Their research found persistence in an asset's own past return across equity indexes, currencies, commodities and bonds. Long-run follow-up research has also documented trend-following evidence over much longer historical samples. This app does not claim those papers guarantee future profits.")
                Text("Backtest rules").font(.headline)
                Text("Uses daily SPY closes from the market-data service. Starting after 252 trading days, yesterday's 12-month return decides whether today's return is taken. Positive trend = invested. Negative trend = cash. The signal is lagged one day to avoid look-ahead bias. Results exclude taxes, spreads, slippage and dividends, so treat them as a test, not a promise.")
                    .foregroundStyle(.secondary)
            }.padding()
        }
        .navigationTitle("Auto Strategy")
    }

    @ViewBuilder private func metric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading) {
            Text(title.uppercased()).font(.caption2).foregroundStyle(.secondary)
            Text("\(value * 100, specifier: "%.1f")%").font(.headline)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @MainActor private func runBacktest() async {
        loading = true; paperMessage = ""
        defer { loading = false }
        do {
            let candles = try await market.fetchCandles(symbol: "SPY", range: "20y", interval: "1d")
            guard candles.count > 300 else { status = "Not enough historical data returned."; return }
            let c = candles.map(\.close)
            momentum = c.last! / c[c.count - 253] - 1
            signal = momentum > 0 ? "LONG" : "CASH"

            var equity = 1.0, peak = 1.0, worst = 0.0
            for i in 253..<c.count {
                let priorTrend = c[i - 1] / c[i - 253] - 1
                let daily = c[i] / c[i - 1] - 1
                if priorTrend > 0 { equity *= (1 + daily) }
                peak = max(peak, equity)
                worst = min(worst, equity / peak - 1)
            }
            strategyReturn = equity - 1
            buyHoldReturn = c.last! / c[252] - 1
            maxDrawdown = worst
            years = Double(c.count - 252) / 252.0
            status = "Loaded \(candles.count) real daily candles. Signal and test updated. Past results do not guarantee future returns."
        } catch {
            status = "Backtest failed: \(error.localizedDescription)"
        }
    }

    @MainActor private func syncPaperTrade() async {
        guard let spy else { return }
        guard let q = await market.quote(for: spy, force: true) else { paperMessage = "Could not load a current SPY quote."; return }
        do {
            if signal == "LONG" {
                if portfolio.position(for: spy.id) == nil {
                    let dollars = portfolio.cash * 0.95
                    try portfolio.placeMarketOrder(asset: spy, side: .buy, dollars: dollars, quantity: nil, price: q.price)
                    paperMessage = "Paper BUY filled for SPY using 95% of available fake cash."
                } else { paperMessage = "Already LONG SPY in the paper account." }
            } else if signal == "CASH", let p = portfolio.position(for: spy.id) {
                try portfolio.placeMarketOrder(asset: spy, side: .sell, dollars: nil, quantity: p.quantity, price: q.price)
                paperMessage = "Paper SPY position sold because the signal is CASH."
            } else { paperMessage = "Already in cash for this strategy." }
        } catch { paperMessage = "Paper trade failed: \(error.localizedDescription)" }
    }
}
