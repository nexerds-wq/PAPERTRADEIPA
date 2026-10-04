import SwiftUI
import Foundation

// MARK: - Auto trader UI
struct ProfessionalAutoTraderView: View {
    @EnvironmentObject private var market: MarketDataService
    @EnvironmentObject private var portfolio: PortfolioStore

    @AppStorage("proAutoEnabledV1") private var autoEnabled = false
    @AppStorage("proAllowShortsV1") private var allowShorts = false
    @AppStorage("proUniverseCursorV1") private var universeCursor = 0
    @AppStorage("proLastScanV1") private var lastScanTime = 0.0
    @AppStorage("proAutoCapitalLimitV1") private var autoCapitalLimit = 2_500.0
    @AppStorage("proRiskPerTradePctV1") private var riskPerTradePct = 0.50
    @AppStorage("proDailyLossPctV1") private var dailyLossPct = 2.0
    @AppStorage("proMaxPositionsV1") private var maxAutoPositions = 3
    @AppStorage("proGaugeThresholdV1") private var gaugeThreshold = 55

    @State private var scanning = false
    @State private var status = "Ready. Auto scans every 10 minutes while the app is active."
    @State private var candidates: [ProCandidate] = []
    @State private var log: [String] = []
    @State private var progress = 0
    @State private var progressTotal = 0
    @State private var sessionScanned = 0
    @State private var marketGaugeScore = 0

    private let scanEvery: TimeInterval = 10 * 60
    private let manageEveryNanoseconds: UInt64 = 15_000_000_000
    private let rotatingPerScan = 36
    private let rewardRisk = 2.5
    private let breakEvenAtR = 1.0
    private let trailAtR = 1.75
    private let trailLockR = 0.75

    private let prioritySymbols = [
        "SPY", "QQQ", "AAPL", "MSFT", "NVDA", "META", "AMZN", "GOOGL", "AMD", "AVGO",
        "TSLA", "NFLX", "PLTR", "COIN", "HOOD", "MU", "QCOM", "ORCL", "CRM", "JPM",
        "XOM", "UBER", "COST", "SMH", "BTC-USD", "ETH-USD", "SOL-USD", "EURUSD=X"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                summary
                professionalRules
                controls

                if scanning {
                    ProgressView(value: Double(progress), total: Double(max(1, progressTotal))) {
                        Text("Scanning \(progress)/\(progressTotal)")
                    }
                }

                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !candidates.isEmpty {
                    Text("Qualified setups")
                        .font(.title2.bold())
                    ForEach(candidates.prefix(20)) { c in
                        candidateCard(c)
                    }
                } else {
                    Text("No qualified setup yet. WAIT is a valid result.")
                        .foregroundStyle(.secondary)
                }

                Text("Activity")
                    .font(.title2.bold())
                if log.isEmpty {
                    Text("No professional auto trades this session.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(log.prefix(40).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("NEXER Pro Auto")
        .task {
            await ProNotifier.shared.prepare()
            await market.loadUSStockUniverse()

            while !Task.isCancelled {
                await manageOpenAutoTrades()
                if autoEnabled && Date().timeIntervalSince1970 - lastScanTime >= scanEvery {
                    await scanMarket(force: false)
                }
                try? await Task.sleep(nanoseconds: manageEveryNanoseconds)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXER PRO AUTO")
                    .font(.largeTitle.bold())
                Text("Retest + gauge + higher timeframe + daily validation")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Circle()
                    .fill(autoEnabled ? Color.green : Color.gray)
                    .frame(width: 14, height: 14)
                Text(autoEnabled ? "AUTO ON" : "AUTO OFF")
                    .font(.caption.bold())
                    .foregroundStyle(autoEnabled ? .green : .secondary)
            }
        }
    }

    private var summary: some View {
        let ledger = ProStore.ledger()
        let equity = portfolio.portfolioValue(quotes: market.quotes)
        let deployed = currentAutoNotional()
        let openCount = ProStore.activeTradeIDs().count
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                ProMetricCard(title: "PAPER EQUITY", value: proMoney(equity))
                ProMetricCard(title: "AUTO LIMIT", value: proMoney(autoCapitalLimit))
            }
            HStack(spacing: 10) {
                ProMetricCard(title: "AUTO DEPLOYED", value: proMoney(deployed))
                ProMetricCard(title: "OPEN AUTO", value: "\(openCount)/\(maxAutoPositions)")
            }
            HStack(spacing: 10) {
                ProMetricCard(title: "TODAY AUTO P/L", value: proMoney(ledger.realizedPL))
                ProMetricCard(title: "SPY GAUGE", value: "\(marketGaugeScore >= 0 ? "+" : "")\(marketGaugeScore)")
            }
            HStack(spacing: 10) {
                ProMetricCard(title: "SCANNED", value: "\(sessionScanned)")
                ProMetricCard(title: "CADENCE", value: "10 min")
            }
        }
    }

    private var professionalRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("PROFESSIONAL GATES", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
                .bold()
            Text("A trade needs a real supply/demand base → breakout → retest → rejection, gauge agreement, 1-hour confirmation, trend strength, volatility and liquidity checks, and a same-day multi-horizon backtest before AUTO can enter.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Backtest gate: recent 15m + 6-month 1h + 1-year daily, out-of-sample check, doubled-cost stress test, minimum sample size, profit factor, expectancy and drawdown limits. Target = 2.5R. Stop = zone invalidation + ATR buffer. Break-even at +1R and profit-lock trail after +1.75R.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Auto scanning is every 10 minutes while iOS keeps the app active. iOS does not guarantee continuous background network execution.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(autoEnabled ? "STOP NEW AUTO ENTRIES" : "START AUTO") {
                    autoEnabled.toggle()
                    status = autoEnabled ? "Auto enabled. Running risk checks and scanning now…" : "Auto entries stopped. Existing auto positions will still be managed."
                    if autoEnabled { Task { await scanMarket(force: true) } }
                }
                .buttonStyle(.borderedProminent)
                .tint(autoEnabled ? .red : .green)

                Button("SCAN NOW") {
                    Task { await scanMarket(force: true) }
                }
                .buttonStyle(.bordered)
                .disabled(scanning)
            }

            NavigationLink {
                MarketsView()
            } label: {
                Label("MANUAL / SOLO TRADING", systemImage: "hand.tap.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Group {
                HStack {
                    Text("Auto capital limit")
                    Spacer()
                    Text(proMoney(autoCapitalLimit)).monospacedDigit()
                }
                Slider(value: $autoCapitalLimit, in: 500...10_000, step: 250)

                HStack {
                    Text("Risk per auto trade")
                    Spacer()
                    Text(String(format: "%.2f%%", riskPerTradePct)).monospacedDigit()
                }
                Slider(value: $riskPerTradePct, in: 0.25...1.50, step: 0.25)

                HStack {
                    Text("Daily auto loss circuit breaker")
                    Spacer()
                    Text(String(format: "%.1f%%", dailyLossPct)).monospacedDigit()
                }
                Slider(value: $dailyLossPct, in: 0.5...5.0, step: 0.5)

                Stepper("Max auto positions: \(maxAutoPositions)", value: $maxAutoPositions, in: 1...5)
                Stepper("Gauge minimum: \(gaugeThreshold)", value: $gaugeThreshold, in: 45...75, step: 5)
                Toggle("Allow paper shorts", isOn: $allowShorts)
            }
            .font(.subheadline)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func candidateCard(_ c: ProCandidate) -> some View {
        let s = c.setup
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.asset.displaySymbol).font(.headline)
                    Text(c.asset.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(s.side.rawValue)
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(s.side == .long ? Color.green.opacity(0.18) : Color.red.opacity(0.18))
                    .foregroundStyle(s.side == .long ? .green : .red)
                    .clipShape(Capsule())
            }

            HStack {
                ProMiniStat(title: "Gauge", value: "\(s.gauge.score)")
                ProMiniStat(title: "1H", value: "\(c.higherTimeframeScore)")
                ProMiniStat(title: "Quality", value: "\(s.quality)/100")
            }

            HStack {
                Text("Entry \(proPrice(s.entry))")
                Spacer()
                Text("SL \(proPrice(s.stop))")
                Spacer()
                Text("TP \(proPrice(s.target))")
            }
            .font(.caption)

            Text("Daily validation: PF \(String(format: "%.2f", c.validation.combined.profitFactor)) • OOS \(String(format: "%.2f", c.validation.outOfSample.profitFactor)) • Stress \(String(format: "%.2f", c.validation.stress.profitFactor)) • \(c.validation.combined.trades) trades • Exp \(String(format: "%+.2fR", c.validation.combined.expectancyR)) • DD \(String(format: "%.1fR", c.validation.combined.maxDrawdownR))")
                .font(.caption2)
                .foregroundStyle(.secondary)
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

        let ledger = ProStore.ledger()
        let dailyLossLimit = autoCapitalLimit * dailyLossPct / 100
        if ledger.realizedPL <= -dailyLossLimit {
            status = "Daily circuit breaker active: auto P/L reached the configured loss limit."
            if autoEnabled {
                await ProNotifier.shared.send("NEXER AUTO PAUSED", "Daily loss circuit breaker hit. No new auto entries today.")
            }
            return
        }
        if ledger.consecutiveLosses >= 3 {
            status = "Risk pause: 3 consecutive auto losses today. New entries are blocked until tomorrow."
            return
        }

        await market.loadUSStockUniverse()
        await updateMarketRegime()

        let universe = combinedUniverse()
        let batch = makeScanBatch(universe)
        progressTotal = batch.count
        status = "Scanning 15m retests + gauge + 1H confirmation…"

        var found: [ProCandidate] = []

        for asset in batch {
            defer {
                progress += 1
                sessionScanned += 1
            }

            do {
                let raw15 = try await market.fetchCandles(symbol: asset.symbol, range: "1mo", interval: "15m", includePrePost: false)
                let bars15 = completedBars(raw15, secondsPerBar: 15 * 60)
                guard bars15.count >= 120 else { continue }

                guard let preliminary = ProStrategy.latestSetup(asset: asset, bars: bars15, minimumGauge: gaugeThreshold) else { continue }
                if preliminary.side == .short && !allowShorts { continue }

                if asset.type == .stock || asset.type == .etf {
                    if preliminary.side == .long && marketGaugeScore <= -35 { continue }
                    if preliminary.side == .short && marketGaugeScore >= 35 { continue }
                }

                let bars1h = try await market.fetchCandles(symbol: asset.symbol, range: "3mo", interval: "60m", includePrePost: false)
                guard bars1h.count >= 80 else { continue }
                let htf = ProGaugeMath.analyze(bars1h)
                let htfOK = preliminary.side == .long ? htf.score >= 25 : htf.score <= -25
                guard htfOK else { continue }

                guard liquidityOK(asset: asset, bars: bars15, setup: preliminary) else { continue }
                guard let validation = await dailyValidation(asset: asset), validation.approved else { continue }

                let candidate = ProCandidate(asset: asset, setup: preliminary, higherTimeframeScore: htf.score, marketScore: marketGaugeScore, validation: validation)
                found.append(candidate)
            } catch {
                // Missing/unsupported symbols are skipped safely.
            }
        }

        found.sort {
            if $0.setup.quality == $1.setup.quality {
                return $0.validation.outOfSample.profitFactor > $1.validation.outOfSample.profitFactor
            }
            return $0.setup.quality > $1.setup.quality
        }
        candidates = found

        if autoEnabled {
            for c in found {
                if ProStore.activeTradeIDs().count >= maxAutoPositions { break }
                await execute(c)
            }
        }

        lastScanTime = Date().timeIntervalSince1970
        status = "Scan complete: \(batch.count) checked, \(found.count) passed every gate. Next automatic scan in 10 minutes."
    }

    @MainActor
    private func execute(_ candidate: ProCandidate) async {
        let asset = candidate.asset
        let setup = candidate.setup

        guard ProStore.loadTrade(asset.id) == nil,
              !ProStore.isCoolingDown(asset.id),
              !portfolio.hasExposure(asset.id),
              ProStore.activeTradeIDs().count < maxAutoPositions else { return }

        if asset.type == .stock || asset.type == .etf {
            guard stockEntryWindowIsOpen() else { return }
        }

        let age = Date().timeIntervalSince(setup.barTime)
        guard age >= 0 && age <= 30 * 60 else { return }

        let ledger = ProStore.ledger()
        let dailyLossLimit = autoCapitalLimit * dailyLossPct / 100
        guard ledger.realizedPL > -dailyLossLimit, ledger.consecutiveLosses < 3 else { return }

        guard let quote = await market.quote(for: asset, force: true) else { return }
        let price = quote.price

        if setup.side == .long {
            guard price > setup.zoneHigh, price <= setup.entry + setup.atr * 0.35 else { return }
        } else {
            guard allowShorts, price < setup.zoneLow, price >= setup.entry - setup.atr * 0.35 else { return }
        }

        let stop = setup.stop
        let risk = setup.side == .long ? price - stop : stop - price
        guard risk > 0, setup.atr > 0 else { return }

        let riskATR = risk / setup.atr
        guard riskATR >= 0.35 && riskATR <= 2.20 else { return }

        let target = setup.side == .long ? price + risk * rewardRisk : price - risk * rewardRisk
        let riskBudget = autoCapitalLimit * riskPerTradePct / 100
        let maxPortfolioRisk = autoCapitalLimit * 0.03
        guard currentAutoRisk() + riskBudget <= maxPortfolioRisk + 0.0001 else { return }
        let qtyByRisk = riskBudget / risk

        let deployed = currentAutoNotional()
        let remainingBudget = max(0, autoCapitalLimit - deployed)
        let perPositionCap = autoCapitalLimit / Double(max(1, maxAutoPositions))
        let notionalCap = min(remainingBudget, perPositionCap, max(0, portfolio.cash * 0.95))
        let qtyByNotional = notionalCap / price
        let quantity = min(qtyByRisk, qtyByNotional)
        let notional = quantity * price

        guard quantity > 0, notional >= 25 else { return }

        do {
            switch setup.side {
            case .long:
                try portfolio.placeMarketOrder(asset: asset, side: .buy, dollars: nil, quantity: quantity, price: price)
            case .short:
                try portfolio.openShort(asset: asset, dollars: nil, quantity: quantity, price: price)
            }

            let state = ProTradeState(assetID: asset.id, side: setup.side, entry: price, stop: stop, target: target, initialRisk: risk, quantity: quantity, notional: notional, openedAt: Date(), bestR: 0)
            ProStore.saveTrade(state)

            let body = "\(setup.side.rawValue) \(asset.displaySymbol) • \(proMoney(notional)) at \(proPrice(price)) • SL \(proPrice(stop)) • TP \(proPrice(target)) • Gauge \(setup.gauge.score) • PF \(String(format: "%.2f", candidate.validation.combined.profitFactor))"
            appendLog("OPEN " + body)
            await ProNotifier.shared.send("NEXER AUTO TRADE — \(asset.displaySymbol)", body)
        } catch {
            appendLog("ENTRY FAILED \(asset.displaySymbol): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func manageOpenAutoTrades() async {
        let ids = ProStore.activeTradeIDs()
        guard !ids.isEmpty else { return }

        for assetID in ids {
            guard var state = ProStore.loadTrade(assetID),
                  let asset = market.asset(forID: assetID),
                  let quote = await market.quote(for: asset, force: true) else { continue }

            let price = quote.price
            let currentR: Double
            switch state.side {
            case .long: currentR = (price - state.entry) / max(state.initialRisk, 0.0000001)
            case .short: currentR = (state.entry - price) / max(state.initialRisk, 0.0000001)
            }
            state.bestR = max(state.bestR, currentR)

            if state.bestR >= breakEvenAtR {
                if state.side == .long { state.stop = max(state.stop, state.entry) }
                else { state.stop = min(state.stop, state.entry) }
            }
            if state.bestR >= trailAtR {
                if state.side == .long { state.stop = max(state.stop, state.entry + state.initialRisk * trailLockR) }
                else { state.stop = min(state.stop, state.entry - state.initialRisk * trailLockR) }
            }
            ProStore.saveTrade(state)

            let closeReason: String?
            switch state.side {
            case .long:
                if price <= state.stop { closeReason = state.stop >= state.entry ? "protected stop" : "stop loss" }
                else if price >= state.target { closeReason = "2.5R take profit" }
                else { closeReason = nil }
            case .short:
                if price >= state.stop { closeReason = state.stop <= state.entry ? "protected stop" : "stop loss" }
                else if price <= state.target { closeReason = "2.5R take profit" }
                else { closeReason = nil }
            }

            guard let reason = closeReason else { continue }

            do {
                let pl: Double
                switch state.side {
                case .long:
                    guard let position = portfolio.position(for: assetID) else { ProStore.clearTrade(assetID); continue }
                    try portfolio.placeMarketOrder(asset: asset, side: .sell, dollars: nil, quantity: position.quantity, price: price)
                    pl = portfolio.closedTrades.first(where: { $0.assetID == assetID })?.realizedPL ?? ((price - state.entry) * state.quantity)
                case .short:
                    guard let position = portfolio.shortPosition(for: assetID) else { ProStore.clearTrade(assetID); continue }
                    try portfolio.coverShort(asset: asset, quantity: position.quantity, price: price)
                    pl = portfolio.closedShortTrades.first(where: { $0.assetID == assetID })?.realizedPL ?? ((state.entry - price) * state.quantity)
                }

                ProStore.clearTrade(assetID)
                ProStore.setCooldown(assetID, until: Date().addingTimeInterval(60 * 60))
                ProStore.recordClose(pl: pl)
                let body = "\(asset.displaySymbol) closed at \(proPrice(price)) • \(reason) • P/L \(proMoney(pl))"
                appendLog("CLOSE " + body)
                await ProNotifier.shared.send("NEXER AUTO CLOSED — \(asset.displaySymbol)", body)
            } catch {
                appendLog("CLOSE FAILED \(asset.displaySymbol): \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func dailyValidation(asset: Asset) async -> ProValidationSummary? {
        if let cached = ProStore.loadValidation(asset.id, gaugeThreshold: gaugeThreshold) { return cached }

        do {
            let recentFetched = try await market.fetchCandles(symbol: asset.symbol, range: "1mo", interval: "15m", includePrePost: false)
            let sixFetched = try await market.fetchCandles(symbol: asset.symbol, range: "6mo", interval: "60m", includePrePost: false)
            let yearFetched = try await market.fetchCandles(symbol: asset.symbol, range: "1y", interval: "1d", includePrePost: false)
            let recent = completedBars(recentFetched, secondsPerBar: 15 * 60)
            let six = completedBars(sixFetched, secondsPerBar: 60 * 60)
            let year = yearFetched
            guard recent.count >= 120, six.count >= 120, year.count >= 120 else { return nil }

            let r1 = ProBacktester.run(recent, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.0, costBps: 6)
            let r2 = ProBacktester.run(six, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.0, costBps: 6)
            let r3 = ProBacktester.run(year, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.0, costBps: 6)
            let combined = ProBacktestReport.combined([r1, r2, r3])

            let o1 = ProBacktester.run(recent, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.70, costBps: 6)
            let o2 = ProBacktester.run(six, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.70, costBps: 6)
            let o3 = ProBacktester.run(year, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.70, costBps: 6)
            let oos = ProBacktestReport.combined([o1, o2, o3])

            let s1 = ProBacktester.run(recent, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.0, costBps: 12)
            let s2 = ProBacktester.run(six, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.0, costBps: 12)
            let s3 = ProBacktester.run(year, asset: asset, minimumGauge: gaugeThreshold, tradeStartFraction: 0.0, costBps: 12)
            let stress = ProBacktestReport.combined([s1, s2, s3])

            let reports = [r1, r2, r3]
            let profitableHorizons = reports.filter { $0.trades >= 3 && $0.profitFactor >= 1.0 && $0.expectancyR > 0 }.count
            let pfs = reports.filter { $0.trades >= 3 }.map(\.profitFactor)
            let worstPF = pfs.min() ?? 0

            let approved = combined.trades >= 20
                && combined.profitFactor >= 1.25
                && combined.expectancyR >= 0.08
                && combined.maxDrawdownR <= 8.0
                && combined.winRate >= 0.32
                && oos.trades >= 5
                && oos.profitFactor >= 1.10
                && oos.expectancyR > 0
                && stress.profitFactor >= 1.05
                && stress.expectancyR > 0
                && profitableHorizons >= 2
                && worstPF >= 0.80

            let summary = ProValidationSummary(dayKey: ProStore.dayKey(), gaugeThreshold: gaugeThreshold, approved: approved, combined: combined, outOfSample: oos, stress: stress, profitableHorizons: profitableHorizons, worstHorizonPF: worstPF, recentTrades: r1.trades, sixMonthTrades: r2.trades, oneYearTrades: r3.trades)
            ProStore.saveValidation(summary, assetID: asset.id)
            return summary
        } catch {
            return nil
        }
    }

    @MainActor
    private func updateMarketRegime() async {
        guard let spy = market.asset(forID: "SPY") ?? Asset.universe.first(where: { $0.id == "SPY" }) else { return }
        do {
            let bars = try await market.fetchCandles(symbol: spy.symbol, range: "3mo", interval: "60m", includePrePost: false)
            marketGaugeScore = ProGaugeMath.analyze(bars).score
        } catch {
            marketGaugeScore = 0
        }
    }

    private func combinedUniverse() -> [Asset] {
        var map: [String: Asset] = [:]
        for a in market.allUSStocks { map[a.id] = a }
        for a in Asset.universe { map[a.id] = a }
        return map.values.sorted { $0.displaySymbol < $1.displaySymbol }
    }

    private func makeScanBatch(_ universe: [Asset]) -> [Asset] {
        guard !universe.isEmpty else { return [] }
        let lookup = Dictionary(uniqueKeysWithValues: universe.map { ($0.id, $0) })
        var output: [Asset] = []
        var seen = Set<String>()
        for symbol in prioritySymbols {
            if let a = lookup[symbol], seen.insert(a.id).inserted { output.append(a) }
        }
        let start = abs(universeCursor) % universe.count
        let count = min(rotatingPerScan, universe.count)
        for offset in 0..<count {
            let a = universe[(start + offset) % universe.count]
            if seen.insert(a.id).inserted { output.append(a) }
        }
        universeCursor = (start + count) % universe.count
        return output
    }

    private func liquidityOK(asset: Asset, bars: [Candle], setup: ProSetup) -> Bool {
        guard setup.entry > 0 else { return false }
        if asset.type == .stock || asset.type == .etf {
            guard setup.entry >= 5 else { return false }
            let tail = bars.suffix(20)
            let avgDollar = tail.reduce(0.0) { $0 + $1.close * $1.volume } / Double(max(1, tail.count))
            return avgDollar >= 250_000
        }
        if asset.type == .crypto {
            let tail = bars.suffix(20)
            let avgDollar = tail.reduce(0.0) { $0 + $1.close * $1.volume } / Double(max(1, tail.count))
            return avgDollar >= 100_000
        }
        return true
    }

    private func completedBars(_ bars: [Candle], secondsPerBar: TimeInterval) -> [Candle] {
        guard let last = bars.last else { return bars }
        if Date().timeIntervalSince(last.date) >= 0 && Date().timeIntervalSince(last.date) < secondsPerBar {
            return Array(bars.dropLast())
        }
        return bars
    }

    private func currentAutoNotional() -> Double {
        ProStore.activeTradeIDs().compactMap { ProStore.loadTrade($0)?.notional }.reduce(0, +)
    }

    private func currentAutoRisk() -> Double {
        ProStore.activeTradeIDs().compactMap { id in
            guard let s = ProStore.loadTrade(id) else { return nil }
            return s.initialRisk * s.quantity
        }.reduce(0, +)
    }

    private func stockEntryWindowIsOpen(_ date: Date = Date()) -> Bool {
        guard let tz = TimeZone(identifier: "America/New_York") else { return true }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let weekday = cal.component(.weekday, from: date)
        guard weekday >= 2 && weekday <= 6 else { return false }
        let hour = cal.component(.hour, from: date)
        let minute = cal.component(.minute, from: date)
        let total = hour * 60 + minute
        return total >= (9 * 60 + 40) && total <= (15 * 60 + 30)
    }

    private func appendLog(_ text: String) {
        let line = "\(Date().formatted(date: .omitted, time: .shortened))  \(text)"
        log.insert(line, at: 0)
        if log.count > 200 { log.removeLast(log.count - 200) }
    }
}

private struct ProMetricCard: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct ProMiniStat: View {
    let title: String
    let value: String
    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(7)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private func proMoney(_ value: Double) -> String { String(format: "$%.2f", value) }
private func proPrice(_ value: Double) -> String {
    if abs(value) >= 1000 { return String(format: "$%.2f", value) }
    if abs(value) >= 1 { return String(format: "$%.4f", value) }
    return String(format: "$%.6f", value)
}
