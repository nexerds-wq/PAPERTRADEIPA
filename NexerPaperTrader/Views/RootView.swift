import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { HomeView() }.tabItem { Label("Home", systemImage: "house.fill") }
            NavigationStack { RobotTraderView() }.tabItem { Label("Robot", systemImage: "cpu.fill") }
            NavigationStack { MarketsView() }.tabItem { Label("Markets", systemImage: "chart.line.uptrend.xyaxis") }
            NavigationStack { PortfolioView() }.tabItem { Label("Portfolio", systemImage: "briefcase.fill") }
            NavigationStack { HistoryView() }.tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }.tint(.green)
    }
}

private struct RobotScore: Identifiable {
    let asset: Asset
    let score: Double
    let trend: Double
    let momentum: Double
    let volatility: Double
    let rsi: Double
    var id: String { asset.id }
    var action: String { score >= 0.62 ? "BUY" : score <= 0.38 ? "SELL" : "HOLD" }
}

struct RobotTraderView: View {
    @EnvironmentObject var market: MarketDataService
    @EnvironmentObject var portfolio: PortfolioStore
    @State private var running = false
    @State private var scanning = false
    @State private var scores: [RobotScore] = []
    @State private var log: [String] = []
    @State private var lastScan: Date?
    @State private var nextScan: Date?
    @State private var status = "Robot is stopped."
    @State private var peakEquity = 10_000.0
    @AppStorage("robotEnabled") private var robotEnabled = false
    @AppStorage("robotLastScan") private var lastScanTime = 0.0

    // Broad but intentionally liquid universe. Indexes are signals only, not traded.
    private var scanUniverse: [Asset] {
        let wanted = ["SPY","QQQ","IWM","DIA","XLK","XLF","XLE","SMH","GLD","SLV","AAPL","MSFT","NVDA","AMZN","META","GOOGL","JPM","XOM","COST","LLY","BTC-USD","ETH-USD","SOL-USD","XRP-USD","EURUSD=X","GBPUSD=X","USDJPY=X","AUDUSD=X","USDCAD=X"]
        return wanted.compactMap { id in Asset.universe.first { $0.id == id } }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Nexer Robot V2").font(.largeTitle.bold())
                        Text("Hourly multi-asset paper trader").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(robotEnabled ? Color.green : Color.gray).frame(width: 14, height: 14)
                }

                HStack(spacing: 10) {
                    stat("MODE", robotEnabled ? "AUTO" : "OFF")
                    stat("ASSETS", "\(scanUniverse.count)")
                    stat("NEXT", nextText)
                }

                Text("Every hour the robot rescans liquid stocks, ETFs, crypto and forex. It ranks trend + momentum + RSI + volatility, then paper-trades only the strongest setups. It does not force a trade every hour.")
                    .font(.footnote).foregroundStyle(.secondary)

                HStack {
                    Button(robotEnabled ? "STOP ROBOT" : "START ROBOT") {
                        robotEnabled.toggle()
                        running = robotEnabled
                        if robotEnabled { Task { await scanAndTrade(force: true) } }
                        else { status = "Robot stopped. Existing paper positions were left alone." }
                    }.buttonStyle(.borderedProminent).tint(robotEnabled ? .red : .green)
                    Button("SCAN NOW") { Task { await scanAndTrade(force: true) } }
                        .buttonStyle(.bordered).disabled(scanning)
                }

                if scanning { ProgressView("Scanning markets…") }
                Text(status).font(.footnote).foregroundStyle(.secondary)

                Text("Robot ranking").font(.title2.bold())
                ForEach(scores.prefix(12)) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(s.asset.displaySymbol).bold()
                            Text("trend \(s.trend * 100, specifier: "%.1f")% • RSI \(s.rsi, specifier: "%.0f") • vol \(s.volatility * 100, specifier: "%.1f")%")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(s.action).bold().foregroundStyle(s.action == "BUY" ? .green : s.action == "SELL" ? .red : .secondary)
                            Text("\(s.score * 100, specifier: "%.0f")/100").font(.caption)
                        }
                    }.padding(12).background(Color.secondary.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Text("Risk engine").font(.title2.bold())
                Text("Max 5 robot holdings • about 18% target allocation each • keeps cash available • exits weak scores • no leverage • no shorting • no averaging down • 15% portfolio drawdown kill switch. Crypto/forex can scan outside stock hours; stock orders use the latest available quote. Paper trading only.")
                    .font(.footnote).foregroundStyle(.secondary)

                Text("Robot log").font(.title2.bold())
                ForEach(Array(log.prefix(20).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding()
        }
        .navigationTitle("Robot")
        .task {
            running = robotEnabled
            if lastScanTime > 0 { lastScan = Date(timeIntervalSince1970: lastScanTime) }
            updateNext()
            while !Task.isCancelled {
                if robotEnabled {
                    let due = Date().timeIntervalSince1970 - lastScanTime >= 3600
                    if due { await scanAndTrade(force: false) }
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                updateNext()
            }
        }
    }

    private var nextText: String {
        guard robotEnabled else { return "—" }
        guard let n = nextScan else { return "NOW" }
        let m = max(0, Int(n.timeIntervalSinceNow / 60))
        return m < 1 ? "<1m" : "\(m)m"
    }

    @ViewBuilder private func stat(_ a: String, _ b: String) -> some View {
        VStack(alignment: .leading) { Text(a).font(.caption2).foregroundStyle(.secondary); Text(b).font(.headline) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.secondary.opacity(0.10)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @MainActor private func scanAndTrade(force: Bool) async {
        if scanning { return }
        if !force && Date().timeIntervalSince1970 - lastScanTime < 3600 { return }
        scanning = true; status = "Downloading hourly market history…"
        defer { scanning = false }

        var found: [RobotScore] = []
        for asset in scanUniverse {
            do {
                let bars = try await market.fetchCandles(symbol: asset.symbol, range: "3mo", interval: "1h")
                if let s = score(asset, bars: bars) { found.append(s) }
            } catch { appendLog("SKIP \(asset.displaySymbol): data unavailable") }
            try? await Task.sleep(nanoseconds: 140_000_000)
        }
        found.sort { $0.score > $1.score }
        scores = found
        lastScan = Date(); lastScanTime = Date().timeIntervalSince1970; updateNext()

        let equity = estimateEquity()
        peakEquity = max(peakEquity, equity)
        if peakEquity > 0 && equity / peakEquity - 1 <= -0.15 {
            robotEnabled = false
            status = "KILL SWITCH: paper portfolio drawdown reached 15%. Robot stopped."
            appendLog("KILL SWITCH — drawdown limit reached")
            return
        }

        let buyList = Array(found.filter { $0.score >= 0.62 }.prefix(5))
        let buyIDs = Set(buyList.map { $0.asset.id })

        // Exit robot-scanned positions when their score is weak or they leave the top group.
        for s in found where !buyIDs.contains(s.asset.id) && s.score <= 0.45 {
            if let p = portfolio.position(for: s.asset.id), let q = await market.quote(for: s.asset, force: true) {
                do {
                    try portfolio.placeMarketOrder(asset: s.asset, side: .sell, dollars: nil, quantity: p.quantity, price: q.price)
                    appendLog("SELL \(s.asset.displaySymbol) @ \(money(q.price)) — score \(Int(s.score*100))")
                } catch { appendLog("SELL failed \(s.asset.displaySymbol)") }
            }
        }

        // Allocate only available fake cash; max 18% of estimated equity to each new holding.
        for s in buyList {
            guard portfolio.position(for: s.asset.id) == nil else { continue }
            guard let q = await market.quote(for: s.asset, force: true) else { continue }
            let target = min(portfolio.cash * 0.90, equity * 0.18)
            if target < 25 { break }
            do {
                try portfolio.placeMarketOrder(asset: s.asset, side: .buy, dollars: target, quantity: nil, price: q.price)
                appendLog("BUY \(s.asset.displaySymbol) $\(Int(target)) @ \(money(q.price)) — score \(Int(s.score*100))")
            } catch { appendLog("BUY failed \(s.asset.displaySymbol)") }
        }
        status = "Scan complete: \(found.count) markets scored. \(buyList.count) currently pass the BUY threshold."
    }

    private func score(_ asset: Asset, bars: [Candle]) -> RobotScore? {
        guard bars.count >= 80 else { return nil }
        let c = bars.map(\.close)
        guard let last = c.last, last > 0 else { return nil }
        let ma20 = c.suffix(20).reduce(0,+)/20
        let ma50 = c.suffix(50).reduce(0,+)/50
        let mom24 = last / c[c.count-25] - 1
        let mom72 = last / c[c.count-73] - 1
        let r = calcRSI(Array(c.suffix(15)))
        let returns = zip(c.suffix(49).dropFirst(), c.suffix(49)).map { $0.0 / $0.1 - 1 }
        let mean = returns.reduce(0,+)/Double(max(1,returns.count))
        let variance = returns.map { pow($0-mean,2) }.reduce(0,+)/Double(max(1,returns.count))
        let vol = sqrt(variance) * sqrt(24*365)

        var points = 0.0
        if last > ma20 { points += 0.18 }
        if ma20 > ma50 { points += 0.18 }
        if mom24 > 0 { points += 0.18 }
        if mom72 > 0 { points += 0.18 }
        if r >= 45 && r <= 68 { points += 0.14 }
        if vol < 1.20 { points += 0.14 }
        // Require meaningful momentum; penalize obvious hourly overextension.
        if mom24 > 0.12 { points -= 0.08 }
        if r > 75 { points -= 0.12 }
        return RobotScore(asset: asset, score: max(0,min(1,points)), trend: last/ma50-1, momentum: mom72, volatility: vol, rsi: r)
    }

    private func calcRSI(_ p: [Double]) -> Double {
        guard p.count >= 15 else { return 50 }
        var gains=0.0, losses=0.0
        for i in 1..<p.count { let d=p[i]-p[i-1]; if d>0 { gains += d } else { losses -= d } }
        if losses == 0 { return 100 }
        let rs=(gains/14)/(losses/14); return 100-(100/(1+rs))
    }

    private func estimateEquity() -> Double {
        // PortfolioStore persists the fake cash; use it plus latest cached marks for a conservative robot guard.
        var v = portfolio.cash
        for a in scanUniverse {
            if let p = portfolio.position(for: a.id) { v += p.quantity * (market.quotes[a.id]?.price ?? p.averagePrice) }
        }
        return v
    }

    private func updateNext() { nextScan = robotEnabled ? Date(timeIntervalSince1970: max(Date().timeIntervalSince1970, lastScanTime + 3600)) : nil }
    private func appendLog(_ s: String) { log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(s)", at: 0); if log.count > 100 { log.removeLast(log.count-100) } }
    private func money(_ n: Double) -> String { String(format: "%.2f", n) }
}
