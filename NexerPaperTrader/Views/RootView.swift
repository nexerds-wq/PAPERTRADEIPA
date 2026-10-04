import SwiftUI
import Foundation
import UserNotifications

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { SupplyDemandAutoTraderView() }
                .tabItem { Label("Retest", systemImage: "arrow.triangle.2.circlepath") }

            NavigationStack { PortfolioView() }
                .tabItem { Label("Portfolio", systemImage: "briefcase.fill") }

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(.green)
        .task { await PhoneNotifier.shared.prepare() }
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
        await MainActor.run { center.delegate = NotificationPresenter.shared }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func send(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

private enum SDTradeSide: String, Codable {
    case long = "BUY"
    case short = "SHORT"
}

private struct AutoTradeState: Codable {
    let assetID: String
    let side: SDTradeSide
    let entry: Double
    var stop: Double
    let target: Double
    let initialRisk: Double
    let openedAt: Date
}

private func autoStateKey(_ assetID: String) -> String {
    "nexer.sd.trade.\(assetID)"
}

private func loadAutoState(_ assetID: String) -> AutoTradeState? {
    guard let data = UserDefaults.standard.data(forKey: autoStateKey(assetID)) else { return nil }
    return try? JSONDecoder().decode(AutoTradeState.self, from: data)
}

private func saveAutoState(_ state: AutoTradeState) {
    if let data = try? JSONEncoder().encode(state) {
        UserDefaults.standard.set(data, forKey: autoStateKey(state.assetID))
    }
}

private func clearAutoState(_ assetID: String) {
    UserDefaults.standard.removeObject(forKey: autoStateKey(assetID))
}

private func money(_ value: Double) -> String {
    String(format: "$%.2f", value)
}

private func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
}

private struct StrategyStats {
    var wins = 0
    var losses = 0
    var breakEvens = 0
    var grossProfitR = 0.0
    var grossLossR = 0.0

    var trades: Int { wins + losses + breakEvens }
    var winRate: Double { trades > 0 ? Double(wins) / Double(trades) : 0 }
    var profitFactor: Double {
        if grossLossR < 0 { return grossProfitR / abs(grossLossR) }
        return grossProfitR > 0 ? 99 : 0
    }
    var expectancyR: Double {
        trades > 0 ? (grossProfitR + grossLossR) / Double(trades) : 0
    }
}

private struct SDCandidate: Identifiable {
    let asset: Asset
    let side: SDTradeSide
    let entry: Double
    let stop: Double
    let target: Double
    let atr: Double
    let zoneTop: Double
    let zoneBottom: Double
    let barTime: Date
    let stats: StrategyStats
    let averageDollarVolume15m: Double

    var id: String { "\(asset.id)-\(side.rawValue)" }
}

private struct StrategyAnalysis {
    let candidate: SDCandidate?
    let stats: StrategyStats
    let averageDollarVolume15m: Double
}

private struct SummaryCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct SupplyDemandAutoTraderView: View {
    @EnvironmentObject private var market: MarketDataService
    @EnvironmentObject private var portfolio: PortfolioStore

    @AppStorage("sdAutoEnabledV3") private var autoEnabled = false
    @AppStorage("sdAllowShortsV3") private var allowShorts = true
    @AppStorage("sdUniverseCursorV3") private var universeCursor = 0
    @AppStorage("sdLastScanV3") private var lastScanTime = 0.0

    @State private var scanning = false
    @State private var status = "Ready. Load the market and start the retest scanner."
    @State private var candidates: [SDCandidate] = []
    @State private var log: [String] = []
    @State private var progress = 0
    @State private var progressTotal = 0
    @State private var sessionScanned = 0

    private let scanEvery: TimeInterval = 60
    private let rotatingPerScan = 45
    private let maxPositions = 5
    private let riskPerTrade = 0.01
    private let maxNotionalPercent = 0.20
    private let minBacktestTrades = 3
    private let minProfitFactor = 1.20

    private let prioritySymbols = [
        "SPY", "QQQ", "AAPL", "MSFT", "NVDA", "META", "AMZN", "GOOGL",
        "AMD", "AVGO", "TSLA", "NFLX", "PLTR", "COIN", "HOOD", "MU",
        "QCOM", "ORCL", "CRM", "JPM", "XOM", "UBER", "COST", "SMH"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NEXER Supply + Demand").font(.largeTitle.bold())
                        Text("15m retest-only full-market paper trader").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(autoEnabled ? Color.green : Color.gray).frame(width: 14, height: 14)
                }

                summaryCards

                VStack(alignment: .leading, spacing: 8) {
                    Label("RETEST ONLY", systemImage: "checkmark.seal.fill").foregroundStyle(.green).bold()
                    Text("A zone must form from real consolidation, break out, come back into the zone, and reject it before an entry is allowed. EMA 21/55, Supertrend, swing structure, ATR risk limits, 1.75R target, and 1R break-even are all used.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("The app rotates through the U.S. listed symbol directory and uses Yahoo Finance chart data with no API key. Yahoo data can be delayed and iOS can suspend scanning when the app is in the background.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Toggle("Allow paper shorts from supply retests", isOn: $allowShorts)

                HStack {
                    Button(autoEnabled ? "STOP NEW ENTRIES" : "START AUTO") {
                        autoEnabled.toggle()
                        status = autoEnabled ? "Auto entries enabled." : "New entries stopped. Open paper trades will still be managed."
                        if autoEnabled { Task { await scanMarket(force: true) } }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(autoEnabled ? .red : .green)

                    Button("SCAN NOW") { Task { await scanMarket(force: true) } }
                        .buttonStyle(.bordered)
                        .disabled(scanning)
                }

                if scanning {
                    ProgressView(value: Double(progress), total: Double(max(progressTotal, 1))) {
                        Text("Scanning \(progress)/\(progressTotal)")
                    }
                }

                Text(status).font(.footnote).foregroundStyle(.secondary)
                Text(market.universeStatus).font(.caption2).foregroundStyle(.secondary)

                Text("Qualified retests").font(.title2.bold())
                if candidates.isEmpty {
                    Text("No qualified retest on the latest completed 15-minute candle in this scan batch.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(candidates.prefix(20))) { candidate in
                        candidateRow(candidate)
                    }
                }

                Text("Activity").font(.title2.bold())
                if log.isEmpty {
                    Text("No paper trades yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(Array(log.prefix(30).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Retest Auto")
        .task {
            await market.loadUSStockUniverse()

            while !Task.isCancelled {
                await manageOpenTrades()
                if autoEnabled && Date().timeIntervalSince1970 - lastScanTime >= scanEvery {
                    await scanMarket(force: false)
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    private var summaryCards: some View {
        let equity = portfolio.portfolioValue(quotes: market.quotes)
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                SummaryCard(title: "PAPER EQUITY", value: money(equity))
                SummaryCard(title: "BUYING POWER", value: money(portfolio.cash))
            }
            HStack(spacing: 10) {
                SummaryCard(title: "OPEN", value: "\(portfolio.exposureCount)/\(maxPositions)")
                SummaryCard(title: "START", value: "$10,000")
            }
            HStack(spacing: 10) {
                SummaryCard(title: "UNIVERSE", value: "\(market.allUSStocks.count) symbols")
                SummaryCard(title: "SESSION SCANNED", value: "\(sessionScanned)")
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ c: SDCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.asset.displaySymbol).font(.headline)
                    Text(c.asset.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(c.side.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(c.side == .long ? Color.green.opacity(0.18) : Color.red.opacity(0.18))
                    .foregroundStyle(c.side == .long ? .green : .red)
                    .clipShape(Capsule())
            }

            HStack {
                Text("Entry \(money(c.entry))")
                Spacer()
                Text("Stop \(money(c.stop))")
                Spacer()
                Text("TP \(money(c.target))")
            }
            .font(.caption)

            Text("PF \(String(format: "%.2f", c.stats.profitFactor)) • Win \(percent(c.stats.winRate)) • \(c.stats.trades) recent retest trades • Exp \(String(format: "%+.2fR", c.stats.expectancyR))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @MainActor
    private func scanMarket(force: Bool) async {
        if scanning { return }
        if !force && Date().timeIntervalSince1970 - lastScanTime < scanEvery { return }

        scanning = true
        progress = 0
        defer { scanning = false }

        await market.loadUSStockUniverse()
        let universe = market.allUSStocks
        guard !universe.isEmpty else {
            status = "Could not load a stock universe."
            return
        }

        let batch = makeScanBatch(universe)
        progressTotal = batch.count
        status = "Scanning completed 15m candles for real base → breakout → retest setups…"

        var found: [SDCandidate] = []

        for asset in batch {
            defer {
                progress += 1
                sessionScanned += 1
            }

            do {
                let rawBars = try await market.fetchCandles(symbol: asset.symbol, range: "1mo", interval: "15m", includePrePost: false)
                let bars = completed15MinuteBars(rawBars)
                guard bars.count >= 100 else { continue }

                let analysis = SupplyDemandEngine.analyze(asset: asset, bars: bars)
                guard let candidate = analysis.candidate else { continue }

                let qualifies = candidate.stats.trades >= minBacktestTrades
                    && candidate.stats.profitFactor >= minProfitFactor
                    && candidate.stats.expectancyR > 0
                    && candidate.averageDollarVolume15m >= 100_000
                    && candidate.entry >= 3

                guard qualifies else { continue }
                if candidate.side == .short && !allowShorts { continue }
                found.append(candidate)
            } catch {
                // Bad/missing symbols are expected in a huge rotating universe. Skip them.
            }
        }

        found.sort {
            if $0.stats.profitFactor == $1.stats.profitFactor {
                return $0.stats.expectancyR > $1.stats.expectancyR
            }
            return $0.stats.profitFactor > $1.stats.profitFactor
        }
        candidates = found

        if autoEnabled {
            for candidate in found {
                if portfolio.exposureCount >= maxPositions { break }
                await executeCandidate(candidate)
            }
        }

        lastScanTime = Date().timeIntervalSince1970
        status = "Scan complete: \(batch.count) checked, \(found.count) qualified retest(s). Full universe rotates automatically."
    }

    @MainActor
    private func executeCandidate(_ candidate: SDCandidate) async {
        guard !portfolio.hasExposure(candidate.asset.id),
              loadAutoState(candidate.asset.id) == nil else { return }

        let signalAge = Date().timeIntervalSince(candidate.barTime)
        guard signalAge >= 0 && signalAge <= 45 * 60 else { return }

        guard let quote = await market.quote(for: candidate.asset, force: true) else { return }
        let price = quote.price

        switch candidate.side {
        case .long:
            guard price > candidate.zoneTop,
                  price <= candidate.entry + candidate.atr * 0.35 else { return }
        case .short:
            guard allowShorts,
                  price < candidate.zoneBottom,
                  price >= candidate.entry - candidate.atr * 0.35 else { return }
        }

        let stop = candidate.stop
        let risk = candidate.side == .long ? price - stop : stop - price
        guard risk > 0, candidate.atr > 0 else { return }
        let riskATR = risk / candidate.atr
        guard riskATR >= 0.25 && riskATR <= 2.50 else { return }

        let target = candidate.side == .long ? price + risk * 1.75 : price - risk * 1.75
        let equity = max(0, portfolio.portfolioValue(quotes: market.quotes))
        let riskBudget = equity * riskPerTrade
        let notionalCap = min(equity * maxNotionalPercent, max(0, portfolio.cash * 0.95))
        let qtyByRisk = riskBudget / risk
        let qtyByNotional = notionalCap / price
        let qty = min(qtyByRisk, qtyByNotional)
        let notional = qty * price
        guard qty > 0, notional >= 50 else { return }

        do {
            switch candidate.side {
            case .long:
                try portfolio.placeMarketOrder(asset: candidate.asset, side: .buy, dollars: nil, quantity: qty, price: price)
            case .short:
                try portfolio.openShort(asset: candidate.asset, dollars: nil, quantity: qty, price: price)
            }

            let state = AutoTradeState(assetID: candidate.asset.id, side: candidate.side, entry: price, stop: stop, target: target, initialRisk: risk, openedAt: Date())
            saveAutoState(state)

            let statsText = "PF \(String(format: "%.2f", candidate.stats.profitFactor)), win \(percent(candidate.stats.winRate)), \(candidate.stats.trades) recent trades"
            append("\(candidate.side.rawValue) \(candidate.asset.displaySymbol) \(money(notional)) @ \(money(price)) • SL \(money(stop)) • TP \(money(target)) • \(statsText)")
            await PhoneNotifier.shared.send(
                title: "NEXER \(candidate.side.rawValue) — \(candidate.asset.displaySymbol)",
                body: "Retest confirmed. Paper position \(money(notional)) at \(money(price)). Stop \(money(stop)), target \(money(target)). \(statsText)."
            )
        } catch {
            append("ENTRY FAILED \(candidate.asset.displaySymbol): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func manageOpenTrades() async {
        let longIDs = portfolio.positions.map(\.assetID)
        let shortIDs = portfolio.shortPositions.map(\.assetID)
        let allIDs = Set(longIDs + shortIDs)

        for assetID in allIDs {
            guard var state = loadAutoState(assetID) else { continue }
            guard let asset = market.asset(forID: assetID) else { continue }
            guard let quote = await market.quote(for: asset, force: true) else { continue }
            let price = quote.price

            switch state.side {
            case .long:
                guard let position = portfolio.position(for: assetID) else {
                    clearAutoState(assetID)
                    continue
                }

                if price >= state.entry + state.initialRisk {
                    state.stop = max(state.stop, state.entry)
                    saveAutoState(state)
                }

                let reason: String?
                if price <= state.stop { reason = state.stop >= state.entry ? "break-even/stop" : "stop" }
                else if price >= state.target { reason = "1.75R target" }
                else { reason = nil }

                if let reason {
                    do {
                        try portfolio.placeMarketOrder(asset: asset, side: .sell, dollars: nil, quantity: position.quantity, price: price)
                        let pl = portfolio.closedTrades.first(where: { $0.assetID == assetID })?.realizedPL ?? 0
                        clearAutoState(assetID)
                        append("CLOSE LONG \(asset.displaySymbol) @ \(money(price)) • \(reason) • P/L \(money(pl))")
                        await PhoneNotifier.shared.send(title: "NEXER CLOSED — \(asset.displaySymbol)", body: "Long closed at \(money(price)) for \(money(pl)) paper P/L. Reason: \(reason).")
                    } catch {
                        append("CLOSE FAILED \(asset.displaySymbol)")
                    }
                }

            case .short:
                guard let position = portfolio.shortPosition(for: assetID) else {
                    clearAutoState(assetID)
                    continue
                }

                if price <= state.entry - state.initialRisk {
                    state.stop = min(state.stop, state.entry)
                    saveAutoState(state)
                }

                let reason: String?
                if price >= state.stop { reason = state.stop <= state.entry ? "break-even/stop" : "stop" }
                else if price <= state.target { reason = "1.75R target" }
                else { reason = nil }

                if let reason {
                    do {
                        try portfolio.coverShort(asset: asset, quantity: position.quantity, price: price)
                        let pl = portfolio.closedShortTrades.first(where: { $0.assetID == assetID })?.realizedPL ?? 0
                        clearAutoState(assetID)
                        append("COVER \(asset.displaySymbol) @ \(money(price)) • \(reason) • P/L \(money(pl))")
                        await PhoneNotifier.shared.send(title: "NEXER COVERED — \(asset.displaySymbol)", body: "Short covered at \(money(price)) for \(money(pl)) paper P/L. Reason: \(reason).")
                    } catch {
                        append("COVER FAILED \(asset.displaySymbol)")
                    }
                }
            }
        }
    }

    private func makeScanBatch(_ universe: [Asset]) -> [Asset] {
        guard !universe.isEmpty else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: universe.map { ($0.id, $0) })
        var output: [Asset] = []
        var seen = Set<String>()

        for symbol in prioritySymbols {
            if let asset = lookup[symbol], seen.insert(asset.id).inserted {
                output.append(asset)
            }
        }

        let start = abs(universeCursor) % universe.count
        let count = min(rotatingPerScan, universe.count)
        for offset in 0..<count {
            let index = (start + offset) % universe.count
            let asset = universe[index]
            if seen.insert(asset.id).inserted { output.append(asset) }
        }

        universeCursor = (start + count) % universe.count
        return output
    }

    private func completed15MinuteBars(_ bars: [Candle]) -> [Candle] {
        guard var last = bars.last else { return bars }
        var output = bars
        let age = Date().timeIntervalSince(last.date)
        if age >= 0 && age < 15 * 60 {
            output.removeLast()
            if let updated = output.last { last = updated }
        }
        _ = last
        return output
    }

    private func append(_ text: String) {
        log.insert("\(Date().formatted(date: .omitted, time: .shortened))  \(text)", at: 0)
        if log.count > 150 { log.removeLast(log.count - 150) }
    }
}

private enum SupplyDemandEngine {
    private struct ZoneState {
        var top: Double
        var bottom: Double
        var breakoutIndex: Int
        var used: Bool
    }

    private struct SimTrade {
        var side: SDTradeSide
        var entry: Double
        var stop: Double
        var target: Double
        var initialRisk: Double
        var entryIndex: Int
    }

    private struct BaseInfo {
        let high: Double
        let low: Double
        let length: Int
    }

    static func analyze(asset: Asset, bars: [Candle]) -> StrategyAnalysis {
        guard bars.count >= 80 else {
            return StrategyAnalysis(candidate: nil, stats: StrategyStats(), averageDollarVolume15m: 0)
        }

        let atr14 = wilderATR(bars, period: 14)
        let atr10 = wilderATR(bars, period: 10)
        let closes = bars.map(\.close)
        let ema21 = ema(closes, period: 21)
        let ema55 = ema(closes, period: 55)
        let superBull = supertrendBull(bars, atr: atr10, factor: 3.0)

        var previousSwingHigh: Double?
        var latestSwingHigh: Double?
        var previousSwingLow: Double?
        var latestSwingLow: Double?

        var demand: ZoneState?
        var supply: ZoneState?
        var lastDemandIndex: Int?
        var lastSupplyIndex: Int?
        var simTrade: SimTrade?
        var stats = StrategyStats()
        var finalCandidate: SDCandidate?

        for i in 1..<bars.count {
            let bar = bars[i]

            // Confirm 3/3 pivots exactly after the right-side bars exist.
            let pivotIndex = i - 3
            if pivotIndex >= 3 {
                if isPivotHigh(bars, index: pivotIndex, left: 3, right: 3) {
                    previousSwingHigh = latestSwingHigh
                    latestSwingHigh = bars[pivotIndex].high
                }
                if isPivotLow(bars, index: pivotIndex, left: 3, right: 3) {
                    previousSwingLow = latestSwingLow
                    latestSwingLow = bars[pivotIndex].low
                }
            }

            let structureReady = previousSwingHigh != nil && latestSwingHigh != nil && previousSwingLow != nil && latestSwingLow != nil
            let structureUp = structureReady
                && latestSwingHigh! > previousSwingHigh!
                && latestSwingLow! > previousSwingLow!
            let structureDown = structureReady
                && latestSwingHigh! < previousSwingHigh!
                && latestSwingLow! < previousSwingLow!

            // Manage the simulated trade before allowing a new entry on this bar.
            if var trade = simTrade, i > trade.entryIndex {
                var closedR: Double?

                switch trade.side {
                case .long:
                    if bar.low <= trade.stop {
                        closedR = trade.stop >= trade.entry ? 0 : -1
                    } else if bar.high >= trade.target {
                        closedR = 1.75
                    } else if bar.high >= trade.entry + trade.initialRisk {
                        trade.stop = max(trade.stop, trade.entry)
                        simTrade = trade
                    }

                case .short:
                    if bar.high >= trade.stop {
                        closedR = trade.stop <= trade.entry ? 0 : -1
                    } else if bar.low <= trade.target {
                        closedR = 1.75
                    } else if bar.low <= trade.entry - trade.initialRisk {
                        trade.stop = min(trade.stop, trade.entry)
                        simTrade = trade
                    }
                }

                if let r = closedR {
                    if r > 0 {
                        stats.wins += 1
                        stats.grossProfitR += r
                    } else if r < 0 {
                        stats.losses += 1
                        stats.grossLossR += r
                    } else {
                        stats.breakEvens += 1
                    }
                    simTrade = nil
                }
            }

            guard let atr = atr14[i], atr > 0 else { continue }

            if let base = findBase(endingBefore: i, bars: bars, atr: atr14) {
                let bullBody = bar.close - bar.open
                let bearBody = bar.open - bar.close
                let strongBull = bar.close > bar.open && bullBody >= atr * 0.65
                let strongBear = bar.close < bar.open && bearBody >= atr * 0.65
                let breaksUp = bar.close > base.high + atr * 0.05
                let breaksDown = bar.close < base.low - atr * 0.05
                let previousStillInBase = bars[i - 1].close <= base.high && bars[i - 1].close >= base.low

                let rawDemand = previousStillInBase && strongBull && breaksUp && !breaksDown
                let rawSupply = previousStillInBase && strongBear && breaksDown && !breaksUp

                if rawDemand && (lastDemandIndex == nil || i - lastDemandIndex! >= 6) {
                    demand = ZoneState(top: base.high, bottom: base.low, breakoutIndex: i, used: false)
                    lastDemandIndex = i
                }

                if rawSupply && (lastSupplyIndex == nil || i - lastSupplyIndex! >= 6) {
                    supply = ZoneState(top: base.high, bottom: base.low, breakoutIndex: i, used: false)
                    lastSupplyIndex = i
                }
            }

            if let d = demand {
                if bar.close < d.bottom || i - d.breakoutIndex > 60 { demand = nil }
            }
            if let s = supply {
                if bar.close > s.top || i - s.breakoutIndex > 60 { supply = nil }
            }

            var longSetup = false
            var shortSetup = false
            var longZone: ZoneState?
            var shortZone: ZoneState?

            if let d = demand, !d.used {
                let age = i - d.breakoutIndex
                let touched = age >= 1 && age <= 60 && bar.low <= d.top && bar.high >= d.bottom
                let rejected = touched && bar.close > d.top && bar.close > bar.open && (bar.close - bar.open) >= atr * 0.10
                if rejected {
                    longSetup = true
                    longZone = d
                }
            }

            if let s = supply, !s.used {
                let age = i - s.breakoutIndex
                let touched = age >= 1 && age <= 60 && bar.high >= s.bottom && bar.low <= s.top
                let rejected = touched && bar.close < s.bottom && bar.close < bar.open && (bar.open - bar.close) >= atr * 0.10
                if rejected {
                    shortSetup = true
                    shortZone = s
                }
            }

            let emaBull = bar.close > ema21[i] && ema21[i] > ema55[i]
            let emaBear = bar.close < ema21[i] && ema21[i] < ema55[i]
            let stBull = superBull[i] ?? false
            let stBear = !(superBull[i] ?? true)
            let longTrendOK = emaBull && stBull && !structureDown
            let shortTrendOK = emaBear && stBear && !structureUp

            let rawLong = simTrade == nil && longSetup && longTrendOK
            let rawShort = simTrade == nil && shortSetup && shortTrendOK
            let longSignal = rawLong && !rawShort
            let shortSignal = rawShort && !rawLong

            if longSignal, let zone = longZone {
                let stop = zone.bottom - atr * 0.15
                let risk = bar.close - stop
                let riskATR = risk / atr
                if risk > 0 && riskATR >= 0.25 && riskATR <= 2.50 {
                    demand?.used = true
                    let target = bar.close + risk * 1.75
                    simTrade = SimTrade(side: .long, entry: bar.close, stop: stop, target: target, initialRisk: risk, entryIndex: i)

                    if i == bars.count - 1 {
                        finalCandidate = makeCandidate(asset: asset, side: .long, bar: bar, entry: bar.close, stop: stop, target: target, atr: atr, zone: zone, stats: stats, bars: bars)
                    }
                }
            }

            if shortSignal, let zone = shortZone {
                let stop = zone.top + atr * 0.15
                let risk = stop - bar.close
                let riskATR = risk / atr
                if risk > 0 && riskATR >= 0.25 && riskATR <= 2.50 {
                    supply?.used = true
                    let target = bar.close - risk * 1.75
                    simTrade = SimTrade(side: .short, entry: bar.close, stop: stop, target: target, initialRisk: risk, entryIndex: i)

                    if i == bars.count - 1 {
                        finalCandidate = makeCandidate(asset: asset, side: .short, bar: bar, entry: bar.close, stop: stop, target: target, atr: atr, zone: zone, stats: stats, bars: bars)
                    }
                }
            }
        }

        let avgDollarVolume = averageDollarVolume15m(bars)
        if let c = finalCandidate {
            finalCandidate = SDCandidate(asset: c.asset, side: c.side, entry: c.entry, stop: c.stop, target: c.target, atr: c.atr, zoneTop: c.zoneTop, zoneBottom: c.zoneBottom, barTime: c.barTime, stats: stats, averageDollarVolume15m: avgDollarVolume)
        }

        return StrategyAnalysis(candidate: finalCandidate, stats: stats, averageDollarVolume15m: avgDollarVolume)
    }

    private static func makeCandidate(asset: Asset, side: SDTradeSide, bar: Candle, entry: Double, stop: Double, target: Double, atr: Double, zone: ZoneState, stats: StrategyStats, bars: [Candle]) -> SDCandidate {
        SDCandidate(asset: asset, side: side, entry: entry, stop: stop, target: target, atr: atr, zoneTop: zone.top, zoneBottom: zone.bottom, barTime: bar.date, stats: stats, averageDollarVolume15m: averageDollarVolume15m(bars))
    }

    private static func findBase(endingBefore index: Int, bars: [Candle], atr: [Double?]) -> BaseInfo? {
        guard index >= 4, let atrPrev = atr[index - 1], atrPrev > 0 else { return nil }
        var chosen: BaseInfo?

        for length in 4...20 {
            let start = index - length
            let end = index - 1
            if start < 0 { continue }

            var high = bars[start].high
            var low = bars[start].low
            var bodyTotal = 0.0
            var largestRange = 0.0
            var overlapCount = 0

            for j in start...end {
                let candleRange = bars[j].high - bars[j].low
                let body = abs(bars[j].close - bars[j].open)
                high = max(high, bars[j].high)
                low = min(low, bars[j].low)
                bodyTotal += body
                largestRange = max(largestRange, candleRange)

                if j < end {
                    let overlapTop = min(bars[j].high, bars[j + 1].high)
                    let overlapBottom = max(bars[j].low, bars[j + 1].low)
                    if overlapTop > overlapBottom { overlapCount += 1 }
                }
            }

            let totalRange = high - low
            let averageBody = bodyTotal / Double(length)
            let overlapPct = length > 1 ? Double(overlapCount) / Double(length - 1) : 1
            let closeDrift = abs(bars[end].close - bars[start].close)
            let driftPct = totalRange > 0 ? closeDrift / totalRange : 0

            let valid = totalRange <= atrPrev * 2.40
                && largestRange <= atrPrev * 1.00
                && averageBody <= atrPrev * 0.45
                && overlapPct >= 0.55
                && driftPct <= 0.65

            if valid { chosen = BaseInfo(high: high, low: low, length: length) }
        }

        return chosen
    }

    private static func isPivotHigh(_ bars: [Candle], index: Int, left: Int, right: Int) -> Bool {
        guard index - left >= 0, index + right < bars.count else { return false }
        let value = bars[index].high
        for j in (index - left)...(index + right) where j != index {
            if bars[j].high >= value { return false }
        }
        return true
    }

    private static func isPivotLow(_ bars: [Candle], index: Int, left: Int, right: Int) -> Bool {
        guard index - left >= 0, index + right < bars.count else { return false }
        let value = bars[index].low
        for j in (index - left)...(index + right) where j != index {
            if bars[j].low <= value { return false }
        }
        return true
    }

    private static func ema(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let k = 2.0 / (Double(period) + 1)
        var output = [values[0]]
        output.reserveCapacity(values.count)
        for value in values.dropFirst() {
            output.append(value * k + (output.last ?? value) * (1 - k))
        }
        return output
    }

    private static func wilderATR(_ bars: [Candle], period: Int) -> [Double?] {
        guard !bars.isEmpty else { return [] }
        var tr = Array(repeating: 0.0, count: bars.count)
        tr[0] = bars[0].high - bars[0].low
        if bars.count > 1 {
            for i in 1..<bars.count {
                tr[i] = max(bars[i].high - bars[i].low, max(abs(bars[i].high - bars[i - 1].close), abs(bars[i].low - bars[i - 1].close)))
            }
        }

        var output = Array<Double?>(repeating: nil, count: bars.count)
        guard bars.count >= period else { return output }
        let seed = tr[0..<period].reduce(0, +) / Double(period)
        output[period - 1] = seed
        var previous = seed

        if period < bars.count {
            for i in period..<bars.count {
                previous = ((previous * Double(period - 1)) + tr[i]) / Double(period)
                output[i] = previous
            }
        }
        return output
    }

    private static func supertrendBull(_ bars: [Candle], atr: [Double?], factor: Double) -> [Bool?] {
        var output = Array<Bool?>(repeating: nil, count: bars.count)
        var finalUpper: Double?
        var finalLower: Double?
        var previousSuper: Double?

        for i in bars.indices {
            guard let a = atr[i] else { continue }
            let hl2 = (bars[i].high + bars[i].low) / 2
            let basicUpper = hl2 + factor * a
            let basicLower = hl2 - factor * a

            if i == 0 || finalUpper == nil || finalLower == nil {
                finalUpper = basicUpper
                finalLower = basicLower
                previousSuper = basicUpper
                output[i] = false
                continue
            }

            let prevClose = bars[i - 1].close
            let oldUpper = finalUpper!
            let oldLower = finalLower!
            finalUpper = (basicUpper < oldUpper || prevClose > oldUpper) ? basicUpper : oldUpper
            finalLower = (basicLower > oldLower || prevClose < oldLower) ? basicLower : oldLower

            let superValue: Double
            if previousSuper == oldUpper {
                superValue = bars[i].close <= finalUpper! ? finalUpper! : finalLower!
            } else {
                superValue = bars[i].close >= finalLower! ? finalLower! : finalUpper!
            }

            previousSuper = superValue
            output[i] = superValue == finalLower!
        }

        return output
    }

    private static func averageDollarVolume15m(_ bars: [Candle]) -> Double {
        let recent = bars.suffix(26)
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0.0) { $0 + ($1.close * $1.volume) } / Double(recent.count)
    }
}
