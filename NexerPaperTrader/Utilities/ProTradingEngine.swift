import Foundation

// MARK: - Strategy
enum ProStrategy {
    static func latestSetup(asset: Asset, bars: [Candle], minimumGauge: Int) -> ProSetup? {
        guard bars.count >= 80 else { return nil }
        let gauge = ProGaugeMath.analyze(bars)
        let direction: ProTradeSide
        if gauge.score >= minimumGauge { direction = .long }
        else if gauge.score <= -minimumGauge { direction = .short }
        else { return nil }

        guard gauge.adx >= 18 else { return nil }
        guard gauge.atrPercent >= 0.12 && gauge.atrPercent <= 8.0 else { return nil }
        guard gauge.volumeRatio >= 0.65 || asset.type == .forex || asset.type == .index else { return nil }
        if direction == .long {
            guard gauge.rsi <= 78, gauge.plusDI >= gauge.minusDI, gauge.ema20 >= gauge.ema50 else { return nil }
        } else {
            guard gauge.rsi >= 22, gauge.minusDI >= gauge.plusDI, gauge.ema20 <= gauge.ema50 else { return nil }
        }
        guard abs((bars.last?.close ?? 0) - gauge.vwap) <= max(gauge.atr * 2.25, 0.0000001) else { return nil }

        let lastIndex = bars.count - 1
        let last = bars[lastIndex]
        let atr = max(gauge.atr, 0.0000001)
        guard (last.high - last.low) <= atr * 3.0 else { return nil }

        let breakoutSearchStart = max(12, lastIndex - 24)
        let breakoutSearchEnd = max(12, lastIndex - 2)
        guard breakoutSearchEnd >= breakoutSearchStart else { return nil }

        for breakout in stride(from: breakoutSearchEnd, through: breakoutSearchStart, by: -1) {
            for baseLength in 4...10 {
                let baseEnd = breakout - 1
                let baseStart = baseEnd - baseLength + 1
                guard baseStart >= 2 else { continue }

                let base = bars[baseStart...baseEnd]
                guard let zoneHigh = base.map(\.high).max(), let zoneLow = base.map(\.low).min() else { continue }
                let zoneWidth = zoneHigh - zoneLow
                guard zoneWidth > 0, zoneWidth <= atr * 1.60 else { continue }

                let breakoutBar = bars[breakout]
                switch direction {
                case .long:
                    guard breakoutBar.close > zoneHigh + atr * 0.10 else { continue }
                    let displaced = breakoutBar.close - breakoutBar.open
                    guard displaced > atr * 0.20 else { continue }
                    let touched = bars.suffix(3).contains { $0.low <= zoneHigh + atr * 0.08 && $0.high >= zoneLow }
                    guard touched, last.close > zoneHigh else { continue }
                    let body = abs(last.close - last.open)
                    let lowerWick = min(last.open, last.close) - last.low
                    guard last.close >= last.open || lowerWick >= max(body * 0.70, atr * 0.05) else { continue }
                    let stop = zoneLow - atr * 0.20
                    let risk = last.close - stop
                    guard risk / atr >= 0.35 && risk / atr <= 2.20 else { continue }
                    let quality = qualityScore(gauge: gauge, zoneWidthATR: zoneWidth / atr, rejection: lowerWick / atr)
                    return ProSetup(side: .long, entry: last.close, stop: stop, target: last.close + risk * 2.5, zoneLow: zoneLow, zoneHigh: zoneHigh, atr: atr, gauge: gauge, barTime: last.date, quality: quality)

                case .short:
                    guard breakoutBar.close < zoneLow - atr * 0.10 else { continue }
                    let displaced = breakoutBar.open - breakoutBar.close
                    guard displaced > atr * 0.20 else { continue }
                    let touched = bars.suffix(3).contains { $0.high >= zoneLow - atr * 0.08 && $0.low <= zoneHigh }
                    guard touched, last.close < zoneLow else { continue }
                    let body = abs(last.close - last.open)
                    let upperWick = last.high - max(last.open, last.close)
                    guard last.close <= last.open || upperWick >= max(body * 0.70, atr * 0.05) else { continue }
                    let stop = zoneHigh + atr * 0.20
                    let risk = stop - last.close
                    guard risk / atr >= 0.35 && risk / atr <= 2.20 else { continue }
                    let quality = qualityScore(gauge: gauge, zoneWidthATR: zoneWidth / atr, rejection: upperWick / atr)
                    return ProSetup(side: .short, entry: last.close, stop: stop, target: last.close - risk * 2.5, zoneLow: zoneLow, zoneHigh: zoneHigh, atr: atr, gauge: gauge, barTime: last.date, quality: quality)
                }
            }
        }
        return nil
    }

    private static func qualityScore(gauge: ProGaugeSnapshot, zoneWidthATR: Double, rejection: Double) -> Int {
        var q = min(70, abs(gauge.score))
        if gauge.adx >= 25 { q += 8 }
        if gauge.volumeRatio >= 1.0 { q += 7 }
        if zoneWidthATR <= 1.0 { q += 7 }
        if rejection >= 0.15 { q += 8 }
        return min(100, q)
    }
}

// MARK: - Gauge math
enum ProGaugeMath {
    static func analyze(_ bars: [Candle]) -> ProGaugeSnapshot {
        guard bars.count >= 30 else {
            return ProGaugeSnapshot(score: 0, label: "WAIT", rsi: 50, adx: 0, atr: 0, atrPercent: 0, plusDI: 0, minusDI: 0, volumeRatio: 0, vwap: 0, ema20: 0, ema50: 0, ema200: 0, reasons: ["Not enough data"])
        }

        let closes = bars.map(\.close)
        let highs = bars.map(\.high)
        let lows = bars.map(\.low)
        let volumes = bars.map(\.volume)
        let last = closes.last ?? 0

        let e9 = ema(closes, 9).last ?? last
        let e20 = ema(closes, 20).last ?? last
        let e50 = ema(closes, 50).last ?? last
        let e200 = ema(closes, 200).last ?? e50
        let r = rsi(closes, 14)
        let macdValues = macd(closes)
        let stoch = stochastic(highs: highs, lows: lows, closes: closes, period: 14)
        let a = atr(bars, 14)
        let dmi = adx(bars, 14)
        let m = mfi(bars, 14)
        let roc = rateOfChange(closes, 10)
        let vwap = rollingVWAP(bars, 30)
        let volumeAvg = volumes.suffix(20).reduce(0, +) / Double(max(1, min(20, volumes.count)))
        let volumeRatio = volumeAvg > 0 ? (volumes.last ?? 0) / volumeAvg : 0
        let obvBias = obvTrend(closes: closes, volumes: volumes, lookback: 10)
        let bb = bollinger(closes, 20)
        let structure = structureBias(bars)
        let emaSlope = closes.count >= 8 ? e20 - (ema(Array(closes.dropLast(6)), 20).last ?? e20) : 0

        var score = 0
        var reasons: [String] = []

        func vote(_ bull: Bool, _ bear: Bool, _ weight: Int, _ bullText: String, _ bearText: String) {
            if bull { score += weight; reasons.append(bullText) }
            else if bear { score -= weight; reasons.append(bearText) }
        }

        vote(e9 > e20 && e20 > e50, e9 < e20 && e20 < e50, 14, "EMA 9/20/50 aligned up", "EMA 9/20/50 aligned down")
        vote(last > e200, last < e200, 8, "Price above EMA 200", "Price below EMA 200")
        vote(last > vwap, last < vwap, 10, "Price above rolling VWAP", "Price below rolling VWAP")
        vote(r >= 50 && r <= 72, r <= 50 && r >= 28, 8, "RSI supports buyers", "RSI supports sellers")
        vote(macdValues.line > macdValues.signal && macdValues.hist > 0, macdValues.line < macdValues.signal && macdValues.hist < 0, 10, "MACD bullish", "MACD bearish")
        vote(stoch.k > stoch.d && stoch.k < 88, stoch.k < stoch.d && stoch.k > 12, 6, "Stochastic bullish", "Stochastic bearish")
        vote(dmi.plus > dmi.minus && dmi.adx >= 18, dmi.minus > dmi.plus && dmi.adx >= 18, 12, "+DI leads with trend strength", "-DI leads with trend strength")
        vote(roc > 0, roc < 0, 6, "Rate of change positive", "Rate of change negative")
        vote(m >= 50 && m < 82, m < 50 && m > 18, 6, "Money flow positive", "Money flow negative")
        vote(obvBias > 0, obvBias < 0, 5, "OBV rising", "OBV falling")
        vote(volumeRatio >= 1.05 && last >= (bars.last?.open ?? last), volumeRatio >= 1.05 && last < (bars.last?.open ?? last), 5, "Volume confirms up move", "Volume confirms down move")
        vote(last > bb.mid, last < bb.mid, 5, "Price above Bollinger midline", "Price below Bollinger midline")
        vote(structure > 0, structure < 0, 3, "Recent structure making progress up", "Recent structure making progress down")
        vote(emaSlope > 0, emaSlope < 0, 2, "EMA 20 slope rising", "EMA 20 slope falling")

        score = max(-100, min(100, score))
        let label: String
        if score >= 65 { label = "STRONG BUY" }
        else if score >= 35 { label = "BUY" }
        else if score <= -65 { label = "STRONG SELL" }
        else if score <= -35 { label = "SELL" }
        else { label = "WAIT" }

        let atrPct = last > 0 ? a / last * 100 : 0
        return ProGaugeSnapshot(score: score, label: label, rsi: r, adx: dmi.adx, atr: a, atrPercent: atrPct, plusDI: dmi.plus, minusDI: dmi.minus, volumeRatio: volumeRatio, vwap: vwap, ema20: e20, ema50: e50, ema200: e200, reasons: Array(reasons.prefix(8)))
    }

    static func ema(_ values: [Double], _ period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let k = 2.0 / (Double(period) + 1.0)
        var out = [values[0]]
        for v in values.dropFirst() { out.append(v * k + (out.last ?? v) * (1 - k)) }
        return out
    }

    static func rsi(_ values: [Double], _ period: Int) -> Double {
        guard values.count > period else { return 50 }
        let changes = zip(values.dropFirst(), values).map { $0.0 - $0.1 }
        let recent = changes.suffix(period)
        let gains = recent.reduce(0.0) { $0 + max(0, $1) } / Double(period)
        let losses = recent.reduce(0.0) { $0 + max(0, -$1) } / Double(period)
        if losses == 0 { return 100 }
        let rs = gains / losses
        return 100 - 100 / (1 + rs)
    }

    static func macd(_ values: [Double]) -> (line: Double, signal: Double, hist: Double) {
        guard values.count >= 26 else { return (0, 0, 0) }
        let fast = ema(values, 12)
        let slow = ema(values, 26)
        let lineSeries = zip(fast, slow).map { $0.0 - $0.1 }
        let signalSeries = ema(lineSeries, 9)
        let line = lineSeries.last ?? 0
        let signal = signalSeries.last ?? 0
        return (line, signal, line - signal)
    }

    static func stochastic(highs: [Double], lows: [Double], closes: [Double], period: Int) -> (k: Double, d: Double) {
        guard highs.count >= period, lows.count >= period, closes.count >= period else { return (50, 50) }
        func kValue(endOffset: Int) -> Double {
            let end = closes.count - 1 - endOffset
            let start = max(0, end - period + 1)
            guard end >= start else { return 50 }
            let hh = highs[start...end].max() ?? closes[end]
            let ll = lows[start...end].min() ?? closes[end]
            let span = hh - ll
            return span > 0 ? 100 * (closes[end] - ll) / span : 50
        }
        let k0 = kValue(endOffset: 0)
        let ks = [k0, kValue(endOffset: 1), kValue(endOffset: 2)]
        return (k0, ks.reduce(0, +) / Double(ks.count))
    }

    static func atr(_ bars: [Candle], _ period: Int) -> Double {
        guard bars.count > 1 else { return 0 }
        var tr: [Double] = []
        for i in 1..<bars.count {
            let c = bars[i]
            let p = bars[i - 1].close
            tr.append(max(c.high - c.low, max(abs(c.high - p), abs(c.low - p))))
        }
        let tail = tr.suffix(period)
        return tail.reduce(0, +) / Double(max(1, tail.count))
    }

    static func adx(_ bars: [Candle], _ period: Int) -> (adx: Double, plus: Double, minus: Double) {
        guard bars.count > period + 2 else { return (0, 0, 0) }
        var trs: [Double] = []
        var plusDM: [Double] = []
        var minusDM: [Double] = []
        for i in 1..<bars.count {
            let c = bars[i]
            let p = bars[i - 1]
            let up = c.high - p.high
            let down = p.low - c.low
            plusDM.append(up > down && up > 0 ? up : 0)
            minusDM.append(down > up && down > 0 ? down : 0)
            trs.append(max(c.high - c.low, max(abs(c.high - p.close), abs(c.low - p.close))))
        }
        let count = min(period, trs.count)
        let tr = trs.suffix(count).reduce(0, +)
        guard tr > 0 else { return (0, 0, 0) }
        let plus = 100 * plusDM.suffix(count).reduce(0, +) / tr
        let minus = 100 * minusDM.suffix(count).reduce(0, +) / tr
        let denom = plus + minus
        let dx = denom > 0 ? 100 * abs(plus - minus) / denom : 0

        var dxs: [Double] = []
        if bars.count > period * 2 {
            let start = max(period + 1, bars.count - period)
            for end in start..<bars.count {
                let sub = Array(bars.prefix(end + 1))
                let mini = dmiOnly(sub, period)
                let d = mini.plus + mini.minus
                dxs.append(d > 0 ? 100 * abs(mini.plus - mini.minus) / d : 0)
            }
        }
        let adxValue = dxs.isEmpty ? dx : dxs.reduce(0, +) / Double(dxs.count)
        return (adxValue, plus, minus)
    }

    private static func dmiOnly(_ bars: [Candle], _ period: Int) -> (plus: Double, minus: Double) {
        guard bars.count > period else { return (0, 0) }
        let start = max(1, bars.count - period)
        var tr = 0.0, plus = 0.0, minus = 0.0
        for i in start..<bars.count {
            let c = bars[i], p = bars[i - 1]
            let up = c.high - p.high
            let down = p.low - c.low
            plus += up > down && up > 0 ? up : 0
            minus += down > up && down > 0 ? down : 0
            tr += max(c.high - c.low, max(abs(c.high - p.close), abs(c.low - p.close)))
        }
        guard tr > 0 else { return (0, 0) }
        return (100 * plus / tr, 100 * minus / tr)
    }

    static func mfi(_ bars: [Candle], _ period: Int) -> Double {
        guard bars.count > period else { return 50 }
        let tail = Array(bars.suffix(period + 1))
        var positive = 0.0, negative = 0.0
        for i in 1..<tail.count {
            let tp = (tail[i].high + tail[i].low + tail[i].close) / 3
            let prev = (tail[i - 1].high + tail[i - 1].low + tail[i - 1].close) / 3
            let flow = tp * tail[i].volume
            if tp > prev { positive += flow }
            else if tp < prev { negative += flow }
        }
        if negative == 0 { return positive > 0 ? 100 : 50 }
        let ratio = positive / negative
        return 100 - 100 / (1 + ratio)
    }

    static func rateOfChange(_ values: [Double], _ lookback: Int) -> Double {
        guard values.count > lookback else { return 0 }
        let old = values[values.count - 1 - lookback]
        guard old != 0 else { return 0 }
        return (values.last! - old) / old * 100
    }

    static func rollingVWAP(_ bars: [Candle], _ lookback: Int) -> Double {
        let tail = bars.suffix(lookback)
        let volume = tail.reduce(0.0) { $0 + $1.volume }
        guard volume > 0 else { return tail.map(\.close).reduce(0, +) / Double(max(1, tail.count)) }
        let pv = tail.reduce(0.0) { partial, c in
            partial + ((c.high + c.low + c.close) / 3) * c.volume
        }
        return pv / volume
    }

    static func obvTrend(closes: [Double], volumes: [Double], lookback: Int) -> Int {
        guard closes.count >= lookback + 1 else { return 0 }
        let start = closes.count - lookback - 1
        var obv = 0.0
        for i in (start + 1)..<closes.count {
            if closes[i] > closes[i - 1] { obv += volumes[i] }
            else if closes[i] < closes[i - 1] { obv -= volumes[i] }
        }
        return obv > 0 ? 1 : (obv < 0 ? -1 : 0)
    }

    static func bollinger(_ values: [Double], _ period: Int) -> (mid: Double, upper: Double, lower: Double) {
        let tail = Array(values.suffix(period))
        guard !tail.isEmpty else { return (0, 0, 0) }
        let mean = tail.reduce(0, +) / Double(tail.count)
        let variance = tail.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(tail.count)
        let sd = sqrt(max(0, variance))
        return (mean, mean + 2 * sd, mean - 2 * sd)
    }

    static func structureBias(_ bars: [Candle]) -> Int {
        guard bars.count >= 12 else { return 0 }
        let recent = Array(bars.suffix(6))
        let prior = Array(bars.dropLast(6).suffix(6))
        let recentHigh = recent.map(\.high).max() ?? 0
        let recentLow = recent.map(\.low).min() ?? 0
        let priorHigh = prior.map(\.high).max() ?? 0
        let priorLow = prior.map(\.low).min() ?? 0
        if recentHigh > priorHigh && recentLow > priorLow { return 1 }
        if recentHigh < priorHigh && recentLow < priorLow { return -1 }
        return 0
    }
}

// MARK: - Conservative backtester
enum ProBacktester {
    static func run(_ allBars: [Candle], asset: Asset, minimumGauge: Int, tradeStartFraction: Double, costBps: Double) -> ProBacktestReport {
        guard allBars.count >= 100 else { return ProBacktestReport() }
        let bars = allBars.count > 900 ? Array(allBars.suffix(900)) : allBars
        let startTradeIndex = max(80, Int(Double(bars.count) * tradeStartFraction))
        var report = ProBacktestReport()
        var equityR = 0.0
        var peakR = 0.0
        var i = 80

        while i < bars.count - 2 {
            if i < startTradeIndex { i += 1; continue }
            let history = Array(bars.prefix(i + 1))
            guard let setup = ProStrategy.latestSetup(asset: asset, bars: history, minimumGauge: minimumGauge) else {
                i += 1
                continue
            }

            let next = bars[i + 1]
            let entryRaw = next.open
            let slip = costBps / 10_000
            let entry = setup.side == .long ? entryRaw * (1 + slip) : entryRaw * (1 - slip)
            let initialRisk = setup.side == .long ? entry - setup.stop : setup.stop - entry
            guard initialRisk > 0 else { i += 1; continue }

            var stop = setup.stop
            let target = setup.side == .long ? entry + initialRisk * 2.5 : entry - initialRisk * 2.5
            var bestR = 0.0
            var closedR: Double?
            let maxHold = min(bars.count - 1, i + 40)
            var j = i + 1

            while j <= maxHold {
                let b = bars[j]
                switch setup.side {
                case .long:
                    if b.low <= stop {
                        closedR = (stop - entry) / initialRisk
                    } else if b.high >= target {
                        closedR = 2.5
                    } else {
                        bestR = max(bestR, (b.high - entry) / initialRisk)
                        if bestR >= 1.0 { stop = max(stop, entry) }
                        if bestR >= 1.75 { stop = max(stop, entry + initialRisk * 0.75) }
                    }
                case .short:
                    if b.high >= stop {
                        closedR = (entry - stop) / initialRisk
                    } else if b.low <= target {
                        closedR = 2.5
                    } else {
                        bestR = max(bestR, (entry - b.low) / initialRisk)
                        if bestR >= 1.0 { stop = min(stop, entry) }
                        if bestR >= 1.75 { stop = min(stop, entry - initialRisk * 0.75) }
                    }
                }
                if closedR != nil { break }
                j += 1
            }

            if closedR == nil {
                let exit = bars[maxHold].close
                closedR = setup.side == .long ? (exit - entry) / initialRisk : (entry - exit) / initialRisk
            }

            var r = closedR ?? 0
            let roundTripPriceCost = entry * (costBps * 2 / 10_000)
            r -= roundTripPriceCost / initialRisk
            r = max(-1.50, min(2.50, r))

            report.trades += 1
            if r > 0.05 { report.wins += 1; report.grossWinR += r }
            else if r < -0.05 { report.losses += 1; report.grossLossR += r }
            else { report.breakEvens += 1 }
            report.netR += r

            equityR += r
            peakR = max(peakR, equityR)
            report.maxDrawdownR = max(report.maxDrawdownR, peakR - equityR)

            i = max(i + 1, j)
        }
        return report
    }
}
