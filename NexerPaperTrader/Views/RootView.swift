import SwiftUI
import UserNotifications

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { VWAPAutoTraderView() }
                .tabItem { Label("VWAP", systemImage: "waveform.path.ecg") }

            NavigationStack { ATHAutoTraderView() }
                .tabItem { Label("ATH", systemImage: "chart.line.uptrend.xyaxis") }

            NavigationStack { PortfolioView() }
                .tabItem { Label("Portfolio", systemImage: "briefcase.fill") }

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(.green)
        .task {
            await PhoneNotifier.shared.prepare()
        }
    }
}

// MARK: - Shared helpers

private let liquidSymbols = [
    "SPY","QQQ","AAPL","MSFT","NVDA","META",
    "AMZN","GOOGL","AMD","AVGO","TSLA","NFLX"
]

private func liquidAssets() -> [Asset] {
    liquidSymbols.compactMap { symbol in
        Asset.universe.first { $0.id == symbol || $0.symbol == symbol }
    }
}

private func money(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

private func pct(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

private struct StrategyStats {
    var wins: Int = 0
    var losses: Int = 0
    var realizedPL: Double = 0
    var backtestWins: Int = 0
    var backtestTrades: Int = 0

    var liveTrades: Int { wins + losses }
    var liveWinRate: Double? {
        guard liveTrades > 0 else { return nil }
        return Double(wins) / Double(liveTrades)
    }
    var backtestWinRate: Double? {
        guard backtestTrades > 0 else { return nil }
        return Double(backtestWins) / Double(backtestTrades)
    }
}

private final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

private actor PhoneNotifier {
    static let shared = PhoneNotifier()

    func prepare() async {
        let center = UNUserNotificationCenter.current()
        await MainActor.run {
            center.delegate = NotificationPresenter.shared
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func send(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

private func ownerKey(_ assetID: String) -> String {
    "nexer.strategy.owner.\(assetID)"
}

private func stopKey(_ assetID: String) -> String {
    "nexer.strategy.stop.\(assetID)"
}

private func targetKey(_ assetID: String) -> String {
    "nexer.strategy.target.\(assetID)"
}

private func setOwner(_ strategy: String, assetID: String, stop: Double? = nil, target: Double? = nil) {
    let defaults = UserDefaults.standard
    defaults.set(strategy, forKey: ownerKey(assetID))
    if let stop { defaults.set(stop, forKey: stopKey(assetID)) }
    if let target { defaults.set(target, forKey: targetKey(assetID)) }
}

private func clearOwner(_ assetID: String) {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: ownerKey(assetID))
    defaults.removeObject(forKey: stopKey(assetID))
    defaults.removeObject(forKey: targetKey(assetID))
}

private func strategyOwner(_ assetID: String) -> String? {
    UserDefaults.standard.string(forKey: ownerKey(assetID))
}

private func savedStop(_ assetID: String) -> Double {
    UserDefaults.standard.double(forKey: stopKey(assetID))
}

private func savedTarget(_ assetID: String) -> Double {
    UserDefaults.standard.double(forKey: targetKey(assetID))
}

private func realizedPLForLatestClosedTrade(_ portfolio: PortfolioStore, assetID: String) -> Double {
    portfolio.closedTrades.first(where: { $0.assetID == assetID })?.realizedPL ?? 0
}

private func incrementStats(strategy: String, realizedPL: Double) {
    let d = UserDefaults.standard
    let prefix = "nexer.stats.\(strategy)."
    if realizedPL >= 0 {
        d.set(d.integer(forKey: prefix + "wins") + 1, forKey: prefix + "wins")
    } else {
        d.set(d.integer(forKey: prefix + "losses") + 1, forKey: prefix + "losses")
    }
    d.set(d.double(forKey: prefix + "pl") + realizedPL, forKey: prefix + "pl")
}

private func loadStats(strategy: String, backtestWins: Int, backtestTrades: Int) -> StrategyStats {
    let d = UserDefaults.standard
    let prefix = "nexer.stats.\(strategy)."
    return StrategyStats(
        wins: d.integer(forKey: prefix + "wins"),
        losses: d.integer(forKey: prefix + "losses"),
        realizedPL: d.double(forKey: prefix + "pl"),
        backtestWins: backtestWins,
        backtestTrades: backtestTrades
    )
}

private struct StatCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - VWAP

private struct VWAPSignal: Identifiable {
    let asset: Asset
    let price: Double
    let vwap: Double
    let rvol: Double
    let breakout: Double
    let stop: Double
    let target: Double
    let action: String
    var id: String { asset.id }
}

struct VWAPAutoTraderView: View {
    @EnvironmentObject private var market: MarketDataService
    @EnvironmentObject private var portfolio: PortfolioStore

    @AppStorage("vwapAutoEnabled") private var enabled = false
    @AppStorage("vwapLastScan") private var lastScanTime = 0.0

    @State private var scanning = false
    @State private var status = "VWAP robot is stopped."
    @State private var signals: [VWAPSignal] = []
    @State private var log: [String] = []
    @State private var backtestWins = 0
    @State private var backtestTrades = 0

    private let scanEvery: TimeInterval = 60
    private let maxPositions = 5
    private let maxAllocation = 1_000.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(
                    title: "VWAP Momentum",
                    subtitle: "5-minute intraday breakout paper trader",
                    enabled: enabled
                )

                summaryCards

                Text("BUY needs price above VWAP + a 15-bar breakout + at least 1.5× recent volume + positive momentum. It exits on VWAP loss, stop, or 2R target.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(enabled ? "STOP AUTO" : "START AUTO") {
                        enabled.toggle()
                        status = enabled ? "VWAP auto trading is on." : "VWAP auto trading stopped."
                        if enabled { Task { await scanAndTrade(force: true) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(enabled ? .red : .green)

                    Button("SCAN NOW") {
                        Task { await scanAndTrade(force: true) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(scanning)
                }

                if scanning { ProgressView("Scanning VWAP setups…") }
                Text(status).font(.footnote).foregroundStyle(.secondary)

                Text("Current setups").font(.title2.bold())
                if signals.isEmpty {
                    Text("No qualifying setup right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(signals) { signal in
                        strategyRow(signal)
                    }
                }

                Text("Activity").font(.title2.bold())
                ForEach(Array(log.prefix(20).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("VWAP")
        .task {
            while !Task.isCancelled {
                if enabled && Date().timeIntervalSince1970 - lastScanTime >= scanEvery {
                    await scanAndTrade(force: false)
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private var stats: StrategyStats {
        loadStats(strategy: "VWAP", backtestWins: backtestWins, backtestTrades: backtestTrades)
    }

    private var summaryCards: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCard(title: "PAPER CASH", value: money(portfolio.cash))
                StatCard(title: "OPEN POSITIONS", value: "\(portfolio.positions.count)/\(maxPositions)")
            }
            HStack(spacing: 10) {
                StatCard(
                    title: "BACKTEST EST.",
                    value: stats.backtestWinRate.map { "\(pct($0)) • \(stats.backtestTrades) trades" } ?? "collecting"
                )
                StatCard(
                    title: "LIVE PAPER",
                    value: stats.liveWinRate.map { "\(pct($0)) • \(stats.liveTrades) closed" } ?? "0 closed"
                )
            }
            HStack(spacing: 10) {
                StatCard(title: "REALIZED P/L", value: money(stats.realizedPL))
                StatCard(title: "SCAN", value: enabled ? "60 sec" : "OFF")
            }
        }
    }

    @ViewBuilder
    private func header(title: String, subtitle: String, enabled: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).font(.largeTitle.bold())
                Text(subtitle).foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(enabled ? Color.green : Color.gray)
                .frame(width: 14, height: 14)
        }
    }

    private func strategyRow(_ s: VWAPSignal) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.asset.displaySymbol).bold()
                Text("Price \(money(s.price)) • VWAP \(money(s.vwap)) • RVOL \(String(format: "%.2fx", s.rvol))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text(s.action).bold().foregroundStyle(s.action == "BUY" ? .green : .orange)
                Text("Stop \(money(s.stop))")
                    .font(.caption2)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @MainActor
    private func scanAndTrade(force: Bool) async {
        if scanning { return }
        if !force && Date().timeIntervalSince1970 - lastScanTime < scanEvery { return }
        scanning = true
        defer { scanning = false }

        status = "Downloading 5-minute candles…"
        var found: [VWAPSignal] = []
        var btWins = 0
        var btTrades = 0

        // First manage positions owned by this strategy.
        for asset in liquidAssets() {
            guard strategyOwner(asset.id) == "VWAP",
                  let position = portfolio.position(for: asset.id),
                  let quote = await market.quote(for: asset, force: true) else { continue }

            do {
                let bars = try await market.fetchCandles(symbol: asset.symbol, range: "5d", interval: "5m")
                guard let latestVWAP = sessionVWAP(bars)?.last else { continue }
                let stop = savedStop(asset.id)
                let target = savedTarget(asset.id)

                let exitReason: String?
                if quote.price <= stop && stop > 0 {
                    exitReason = "stop hit"
                } else if quote.price >= target && target > 0 {
                    exitReason = "2R target hit"
                } else if quote.price < latestVWAP {
                    exitReason = "lost VWAP"
                } else {
                    exitReason = nil
                }

                if let exitReason {
                    try portfolio.placeMarketOrder(
                        asset: asset,
                        side: .sell,
                        dollars: nil,
                        quantity: position.quantity,
                        price: quote.price
                    )
                    let pl = realizedPLForLatestClosedTrade(portfolio, assetID: asset.id)
                    incrementStats(strategy: "VWAP", realizedPL: pl)
                    clearOwner(asset.id)
                    append("SELL \(asset.displaySymbol) \(money(quote.price)) • \(exitReason) • P/L \(money(pl))")
                    await PhoneNotifier.shared.send(
                        title: "VWAP CLOSED — \(asset.displaySymbol)",
                        body: "Sold \(asset.displaySymbol) at \(money(quote.price)). Paper trade P/L \(money(pl)). Trade closed successfully."
                    )
                }
            } catch {
                append("VWAP manage skip \(asset.displaySymbol)")
            }
        }

        // Then scan entries and calculate a small rolling historical estimate.
        for asset in liquidAssets() {
            do {
                let bars = try await market.fetchCandles(symbol: asset.symbol, range: "1mo", interval: "5m")
                let test = backtestVWAP(bars)
                btWins += test.wins
                btTrades += test.trades

                if let signal = makeVWAPSignal(asset: asset, bars: bars) {
                    found.append(signal)
                }
            } catch {
                append("VWAP data unavailable \(asset.displaySymbol)")
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        backtestWins = btWins
        backtestTrades = btTrades
        signals = found.sorted { $0.rvol > $1.rvol }

        if enabled {
            for s in signals {
                if portfolio.positions.count >= maxPositions { break }
                if portfolio.position(for: s.asset.id) != nil { continue }
                if strategyOwner(s.asset.id) != nil { continue }

                guard let quote = await market.quote(for: s.asset, force: true) else { continue }
                let amount = min(maxAllocation, portfolio.cash * 0.20)
                if amount < 100 { break }

                do {
                    try portfolio.placeMarketOrder(
                        asset: s.asset,
                        side: .buy,
                        dollars: amount,
                        quantity: nil,
                        price: quote.price
                    )
                    let risk = max(quote.price - s.stop, quote.price * 0.005)
                    let target = quote.price + 2 * risk
                    setOwner("VWAP", assetID: s.asset.id, stop: s.stop, target: target)
                    let winText = backtestTrades > 0 ? "\(pct(Double(backtestWins) / Double(backtestTrades))) over \(backtestTrades) test trades" : "backtest still collecting"
                    append("BUY \(s.asset.displaySymbol) \(money(amount)) @ \(money(quote.price)) • \(winText)")
                    await PhoneNotifier.shared.send(
                        title: "VWAP BUY — \(s.asset.displaySymbol)",
                        body: "Paper bought \(money(amount)) of \(s.asset.displaySymbol) at \(money(quote.price)). Estimated historical win rate: \(winText)."
                    )
                } catch {
                    append("BUY failed \(s.asset.displaySymbol)")
                }
            }
        }

        lastScanTime = Date().timeIntervalSince1970
        status = "VWAP scan complete. \(signals.count) setup(s) qualify."
    }

    private func makeVWAPSignal(asset: Asset, bars: [Candle]) -> VWAPSignal? {
        guard bars.count >= 25 else { return nil }
        let recent = Array(bars.suffix(80))
        guard let vwapSeries = sessionVWAP(recent), let vwap = vwapSeries.last else { return nil }
        let last = recent[recent.count - 1]
        let prior = recent.dropLast()
        guard prior.count >= 20 else { return nil }

        let prior15 = Array(prior.suffix(15))
        let breakout = prior15.map(\.high).max() ?? last.high
        let avgVol = Array(prior.suffix(20)).map(\.volume).reduce(0,+) / 20
        let rvol = avgVol > 0 ? last.volume / avgVol : 0
        let momentumUp = last.close > recent[max(0, recent.count - 6)].close

        guard last.close > vwap,
              last.close > breakout,
              rvol >= 1.5,
              momentumUp else { return nil }

        let recentLow = prior15.map(\.low).min() ?? last.close * 0.985
        let stop = max(recentLow, last.close * 0.985)
        let risk = max(last.close - stop, last.close * 0.005)
        let target = last.close + 2 * risk

        return VWAPSignal(
            asset: asset,
            price: last.close,
            vwap: vwap,
            rvol: rvol,
            breakout: breakout,
            stop: stop,
            target: target,
            action: "BUY"
        )
    }

    private func sessionVWAP(_ bars: [Candle]) -> [Double]? {
        guard !bars.isEmpty else { return nil }
        let cal = Calendar(identifier: .gregorian)
        var currentDay: DateComponents?
        var cumulativePV = 0.0
        var cumulativeVolume = 0.0
        var out: [Double] = []

        for bar in bars {
            let day = cal.dateComponents([.year, .month, .day], from: bar.date)
            if day != currentDay {
                currentDay = day
                cumulativePV = 0
                cumulativeVolume = 0
            }
            let typical = (bar.high + bar.low + bar.close) / 3
            cumulativePV += typical * bar.volume
            cumulativeVolume += bar.volume
            out.append(cumulativeVolume > 0 ? cumulativePV / cumulativeVolume : bar.close)
        }
        return out
    }

    private func backtestVWAP(_ bars: [Candle]) -> (wins: Int, trades: Int) {
        guard bars.count >= 50, let vwaps = sessionVWAP(bars) else { return (0,0) }
        var wins = 0
        var trades = 0
        var inTrade = false
        var entry = 0.0
        var stop = 0.0
        var target = 0.0

        for i in 20..<bars.count {
            let b = bars[i]

            if inTrade {
                if b.low <= stop {
                    trades += 1
                    inTrade = false
                    continue
                }
                if b.high >= target {
                    trades += 1
                    wins += 1
                    inTrade = false
                    continue
                }
                if b.close < vwaps[i] {
                    trades += 1
                    if b.close > entry { wins += 1 }
                    inTrade = false
                    continue
                }
            } else {
                let prior15 = Array(bars[(i-15)..<i])
                let breakout = prior15.map(\.high).max() ?? b.high
                let prior20 = Array(bars[(i-20)..<i])
                let avgVol = prior20.map(\.volume).reduce(0,+) / 20
                let rvol = avgVol > 0 ? b.volume / avgVol : 0
                let momentumUp = b.close > bars[max(0, i-5)].close

                if b.close > vwaps[i] && b.close > breakout && rvol >= 1.5 && momentumUp {
                    entry = b.close
                    let recentLow = prior15.map(\.low).min() ?? b.close * 0.985
                    stop = max(recentLow, b.close * 0.985)
                    let risk = max(entry - stop, entry * 0.005)
                    target = entry + 2 * risk
                    inTrade = true
                }
            }
        }
        return (wins, trades)
    }

    private func append(_ text: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(text)", at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }
}

// MARK: - ATH trend

private struct ATHSignal: Identifiable {
    let asset: Asset
    let close: Double
    let priorATH: Double
    let atr42: Double
    let stop: Double
    let action: String
    var id: String { asset.id }
}

struct ATHAutoTraderView: View {
    @EnvironmentObject private var market: MarketDataService
    @EnvironmentObject private var portfolio: PortfolioStore

    @AppStorage("athAutoEnabled") private var enabled = false
    @AppStorage("athLastScan") private var lastScanTime = 0.0

    @State private var scanning = false
    @State private var status = "ATH robot is stopped."
    @State private var signals: [ATHSignal] = []
    @State private var log: [String] = []
    @State private var backtestWins = 0
    @State private var backtestTrades = 0

    private let scanEvery: TimeInterval = 15 * 60
    private let maxPositions = 5
    private let maxAllocation = 1_000.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("ATH Trend").font(.largeTitle.bold())
                        Text("Daily all-time-high trend paper trader").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(enabled ? Color.green : Color.gray).frame(width: 14, height: 14)
                }

                summaryCards

                Text("BUY requires a completed daily close at a new all-time high, price above $10, 42-day average dollar volume above $1M, and a valid ATR42 trailing stop. This mirrors the ATH CMD rules you gave me.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(enabled ? "STOP AUTO" : "START AUTO") {
                        enabled.toggle()
                        status = enabled ? "ATH auto trading is on." : "ATH auto trading stopped."
                        if enabled { Task { await scanAndTrade(force: true) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(enabled ? .red : .green)

                    Button("SCAN NOW") {
                        Task { await scanAndTrade(force: true) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(scanning)
                }

                if scanning { ProgressView("Scanning ATH setups…") }
                Text(status).font(.footnote).foregroundStyle(.secondary)

                Text("Current ATH setups").font(.title2.bold())
                if signals.isEmpty {
                    Text("No new ATH entries right now.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(signals) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.asset.displaySymbol).bold()
                                Text("Close \(money(s.close)) • ATR42 \(money(s.atr42)) • Stop \(money(s.stop))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(s.action).bold().foregroundStyle(.green)
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }

                Text("Activity").font(.title2.bold())
                ForEach(Array(log.prefix(20).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("ATH")
        .task {
            while !Task.isCancelled {
                if enabled && Date().timeIntervalSince1970 - lastScanTime >= scanEvery {
                    await scanAndTrade(force: false)
                }
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private var stats: StrategyStats {
        loadStats(strategy: "ATH", backtestWins: backtestWins, backtestTrades: backtestTrades)
    }

    private var summaryCards: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatCard(title: "PAPER CASH", value: money(portfolio.cash))
                StatCard(title: "OPEN POSITIONS", value: "\(portfolio.positions.count)/\(maxPositions)")
            }
            HStack(spacing: 10) {
                StatCard(
                    title: "BACKTEST EST.",
                    value: stats.backtestWinRate.map { "\(pct($0)) • \(stats.backtestTrades) trades" } ?? "collecting"
                )
                StatCard(
                    title: "LIVE PAPER",
                    value: stats.liveWinRate.map { "\(pct($0)) • \(stats.liveTrades) closed" } ?? "0 closed"
                )
            }
            HStack(spacing: 10) {
                StatCard(title: "REALIZED P/L", value: money(stats.realizedPL))
                StatCard(title: "SCAN", value: enabled ? "15 min" : "OFF")
            }
        }
    }

    @MainActor
    private func scanAndTrade(force: Bool) async {
        if scanning { return }
        if !force && Date().timeIntervalSince1970 - lastScanTime < scanEvery { return }
        scanning = true
        defer { scanning = false }

        status = "Downloading daily market history…"
        var found: [ATHSignal] = []
        var btWins = 0
        var btTrades = 0

        for asset in liquidAssets() {
            do {
                let bars = try await market.fetchCandles(symbol: asset.symbol, range: "10y", interval: "1d")
                let prepared = prepareATH(bars)
                let test = backtestATH(prepared)
                btWins += test.wins
                btTrades += test.trades

                if strategyOwner(asset.id) == "ATH",
                   let position = portfolio.position(for: asset.id),
                   let last = prepared.last,
                   let quote = await market.quote(for: asset, force: true) {

                    let oldStop = savedStop(asset.id)
                    let newStop = max(oldStop, last.rawStop)
                    setOwner("ATH", assetID: asset.id, stop: newStop, target: 0)

                    if quote.price < newStop {
                        try portfolio.placeMarketOrder(
                            asset: asset,
                            side: .sell,
                            dollars: nil,
                            quantity: position.quantity,
                            price: quote.price
                        )
                        let pl = realizedPLForLatestClosedTrade(portfolio, assetID: asset.id)
                        incrementStats(strategy: "ATH", realizedPL: pl)
                        clearOwner(asset.id)
                        append("SELL \(asset.displaySymbol) \(money(quote.price)) • trailing stop • P/L \(money(pl))")
                        await PhoneNotifier.shared.send(
                            title: "ATH CLOSED — \(asset.displaySymbol)",
                            body: "Sold \(asset.displaySymbol) at \(money(quote.price)). Paper trade P/L \(money(pl)). Trade closed successfully."
                        )
                    }
                }

                if let signal = latestATHSignal(asset: asset, prepared: prepared) {
                    found.append(signal)
                }
            } catch {
                append("ATH data unavailable \(asset.displaySymbol)")
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        backtestWins = btWins
        backtestTrades = btTrades
        signals = found

        if enabled {
            for s in signals {
                if portfolio.positions.count >= maxPositions { break }
                if portfolio.position(for: s.asset.id) != nil { continue }
                if strategyOwner(s.asset.id) != nil { continue }

                let lastSignalKey = "nexer.ath.lastSignal.\(s.asset.id)"
                let signalStamp = Int(s.close * 1000) ^ Int(s.priorATH * 1000)
                if UserDefaults.standard.integer(forKey: lastSignalKey) == signalStamp { continue }

                guard let quote = await market.quote(for: s.asset, force: true) else { continue }
                let amount = min(maxAllocation, portfolio.cash * 0.20)
                if amount < 100 { break }

                do {
                    try portfolio.placeMarketOrder(
                        asset: s.asset,
                        side: .buy,
                        dollars: amount,
                        quantity: nil,
                        price: quote.price
                    )
                    setOwner("ATH", assetID: s.asset.id, stop: s.stop, target: 0)
                    UserDefaults.standard.set(signalStamp, forKey: lastSignalKey)
                    let winText = backtestTrades > 0 ? "\(pct(Double(backtestWins) / Double(backtestTrades))) over \(backtestTrades) test trades" : "backtest still collecting"
                    append("BUY \(s.asset.displaySymbol) \(money(amount)) @ \(money(quote.price)) • \(winText)")
                    await PhoneNotifier.shared.send(
                        title: "ATH BUY — \(s.asset.displaySymbol)",
                        body: "Paper bought \(money(amount)) of \(s.asset.displaySymbol) at \(money(quote.price)). Estimated historical win rate: \(winText). Initial stop \(money(s.stop))."
                    )
                } catch {
                    append("ATH BUY failed \(s.asset.displaySymbol)")
                }
            }
        }

        lastScanTime = Date().timeIntervalSince1970
        status = "ATH scan complete. \(signals.count) new-high setup(s) qualify."
    }

    private struct ATHRow {
        let candle: Candle
        let atr42: Double
        let avgDollarVolume42: Double
        let priorATH: Double
        let ath: Double
        let rawStop: Double
        let newATH: Bool
    }

    private func prepareATH(_ bars: [Candle]) -> [ATHRow] {
        guard bars.count >= 43 else { return [] }
        var trs: [Double] = []
        trs.reserveCapacity(bars.count)

        for i in 0..<bars.count {
            let b = bars[i]
            if i == 0 {
                trs.append(b.high - b.low)
            } else {
                let prevClose = bars[i-1].close
                trs.append(max(
                    b.high - b.low,
                    abs(b.high - prevClose),
                    abs(b.low - prevClose)
                ))
            }
        }

        var result: [ATHRow] = []
        var runningATH = bars[0].close

        for i in 0..<bars.count {
            let priorATH = i == 0 ? bars[i].close : runningATH
            runningATH = max(runningATH, bars[i].close)

            guard i >= 41 else { continue }
            let atr42 = Array(trs[(i-41)...i]).reduce(0,+) / 42
            let avgDollarVolume = Array(bars[(i-41)...i]).map { $0.close * $0.volume }.reduce(0,+) / 42
            let ratio = max(0.000001, 1 - atr42 / bars[i].close)
            let rawStop = runningATH * pow(ratio, 10)
            let isNewATH = i > 0 && bars[i].close >= priorATH

            result.append(ATHRow(
                candle: bars[i],
                atr42: atr42,
                avgDollarVolume42: avgDollarVolume,
                priorATH: priorATH,
                ath: runningATH,
                rawStop: rawStop,
                newATH: isNewATH
            ))
        }
        return result
    }

    private func latestATHSignal(asset: Asset, prepared: [ATHRow]) -> ATHSignal? {
        guard let row = prepared.last else { return nil }
        guard row.candle.close > 10,
              row.avgDollarVolume42 > 1_000_000,
              row.newATH,
              row.rawStop > 0 else { return nil }

        return ATHSignal(
            asset: asset,
            close: row.candle.close,
            priorATH: row.priorATH,
            atr42: row.atr42,
            stop: row.rawStop,
            action: "BUY"
        )
    }

    private func backtestATH(_ rows: [ATHRow]) -> (wins: Int, trades: Int) {
        guard !rows.isEmpty else { return (0,0) }
        var inTrade = false
        var entry = 0.0
        var stop = 0.0
        var wins = 0
        var trades = 0

        for row in rows {
            if inTrade {
                stop = max(stop, row.rawStop)
                if row.candle.close < stop {
                    trades += 1
                    if row.candle.close > entry { wins += 1 }
                    inTrade = false
                }
            } else if row.candle.close > 10 &&
                        row.avgDollarVolume42 > 1_000_000 &&
                        row.newATH {
                entry = row.candle.close
                stop = row.rawStop
                inTrade = true
            }
        }
        return (wins, trades)
    }

    private func append(_ text: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(text)", at: 0)
        if log.count > 100 { log.removeLast(log.count - 100) }
    }
}
