import Foundation

enum QuickSignalAction: String {
    case strongBuy = "STRONG BUY"
    case buy = "BUY"
    case wait = "WAIT"
    case sell = "SELL"
    case strongSell = "STRONG SELL"
}

struct TechnicalSnapshot {
    let rsi: Double?
    let macd: Double?
    let signal: Double?
    let histogram: Double?
    let ema20: Double?
    let ema50: Double?
    let ema200: Double?
    let sma20: Double?
    let atr14: Double?
    let momentum20: Double?
    let trendStrength: Double
    let trend: String
    let quickSignal: QuickSignalAction
    let signalScore: Int
    let confidence: Int
    let reasons: [String]
    let patterns: [String]
}

enum Indicators {
    static func snapshot(_ candles: [Candle]) -> TechnicalSnapshot {
        let closes = candles.map(\.close)
        let last = closes.last ?? 0
        let rsiValue = rsi(closes, period: 14)
        let m = macd(closes)
        let e20 = ema(closes, period: 20).last
        let e50 = closes.count >= 50 ? ema(closes, period: 50).last : nil
        let e200 = closes.count >= 200 ? ema(closes, period: 200).last : nil
        let s20 = sma(closes, period: 20)
        let atrValue = atr(candles, period: 14)
        let momentum = momentumPercent(closes, lookback: 20)

        var score = 0
        var confirmations = 0
        var reasons: [String] = []

        if let e20, let e50 {
            if last > e20 && e20 > e50 {
                score += 24
                confirmations += 1
                reasons.append("Price is above the 20 and 50 EMA")
            } else if last < e20 && e20 < e50 {
                score -= 24
                confirmations += 1
                reasons.append("Price is below the 20 and 50 EMA")
            } else {
                reasons.append("Short and medium trend are mixed")
            }
        }

        if let e50, let e200 {
            if last > e200 && e50 > e200 {
                score += 16
                confirmations += 1
                reasons.append("Long-term trend is bullish")
            } else if last < e200 && e50 < e200 {
                score -= 16
                confirmations += 1
                reasons.append("Long-term trend is bearish")
            }
        }

        if let macdValue = m.macd, let signalValue = m.signal, let hist = m.histogram {
            if macdValue > signalValue && hist > 0 {
                score += 20
                confirmations += 1
                reasons.append("MACD momentum is positive")
            } else if macdValue < signalValue && hist < 0 {
                score -= 20
                confirmations += 1
                reasons.append("MACD momentum is negative")
            }
        }

        if let r = rsiValue {
            if r >= 52 && r <= 68 {
                score += 12
                confirmations += 1
                reasons.append("RSI is bullish without being extremely overbought")
            } else if r >= 32 && r < 48 {
                score -= 12
                confirmations += 1
                reasons.append("RSI shows weak momentum")
            } else if r >= 70 {
                score -= 6
                reasons.append("RSI is overbought so chasing has extra risk")
            } else if r <= 30 {
                score += 2
                reasons.append("RSI is oversold but that alone is not a buy")
            } else {
                reasons.append("RSI is neutral")
            }
        }

        if let momentum {
            if momentum > 3 {
                score += 14
                confirmations += 1
                reasons.append("20-session momentum is positive")
            } else if momentum < -3 {
                score -= 14
                confirmations += 1
                reasons.append("20-session momentum is negative")
            }
        }

        score = max(-100, min(100, score))
        let strength = trendStrength(close: last, ema20: e20, ema50: e50, ema200: e200)

        var confidence = min(95, 45 + confirmations * 9 + Int(strength * 0.15))
        if let atrValue, last > 0 {
            let atrPct = atrValue / last * 100
            if atrPct > 7 {
                confidence -= 12
                reasons.append("Volatility is very high so confidence is reduced")
            } else if atrPct > 4 {
                confidence -= 6
                reasons.append("Volatility is elevated")
            }
        }

        let action: QuickSignalAction
        if score >= 65 && confirmations >= 4 {
            action = .strongBuy
        } else if score >= 35 && confirmations >= 3 {
            action = .buy
        } else if score <= -65 && confirmations >= 4 {
            action = .strongSell
        } else if score <= -35 && confirmations >= 3 {
            action = .sell
        } else {
            action = .wait
            confidence = min(confidence, 72)
        }

        let trend: String
        if strength >= 70 {
            trend = score >= 0 ? "Strong Uptrend" : "Strong Downtrend"
        } else if strength >= 40 {
            trend = score >= 0 ? "Uptrend" : "Downtrend"
        } else {
            trend = "Weak / Choppy"
        }

        return .init(
            rsi: rsiValue,
            macd: m.macd,
            signal: m.signal,
            histogram: m.histogram,
            ema20: e20,
            ema50: e50,
            ema200: e200,
            sma20: s20,
            atr14: atrValue,
            momentum20: momentum,
            trendStrength: strength,
            trend: trend,
            quickSignal: action,
            signalScore: score,
            confidence: max(20, confidence),
            reasons: reasons,
            patterns: patterns(candles)
        )
    }

    static func sma(_ values: [Double], period: Int) -> Double? {
        guard period > 0, values.count >= period else { return nil }
        return values.suffix(period).reduce(0, +) / Double(period)
    }

    static func rsi(_ values: [Double], period: Int) -> Double? {
        guard values.count > period else { return nil }
        let changes = zip(values.dropFirst(), values).map { $0.0 - $0.1 }
        let recent = changes.suffix(period)
        let gains = recent.reduce(0) { $0 + max($1, 0) } / Double(period)
        let losses = recent.reduce(0) { $0 + max(-$1, 0) } / Double(period)
        if losses == 0 { return 100 }
        let rs = gains / losses
        return 100 - (100 / (1 + rs))
    }

    static func ema(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let k = 2.0 / (Double(period) + 1)
        var result: [Double] = [values[0]]
        for v in values.dropFirst() {
            result.append(v * k + (result.last ?? v) * (1 - k))
        }
        return result
    }

    static func macd(_ values: [Double]) -> (macd: Double?, signal: Double?, histogram: Double?) {
        guard values.count >= 26 else { return (nil, nil, nil) }
        let e12 = ema(values, period: 12)
        let e26 = ema(values, period: 26)
        let line = zip(e12, e26).map { $0.0 - $0.1 }
        let sig = ema(line, period: 9)
        guard let m = line.last, let s = sig.last else { return (nil, nil, nil) }
        return (m, s, m - s)
    }

    static func atr(_ candles: [Candle], period: Int) -> Double? {
        guard candles.count > period else { return nil }
        var values: [Double] = []
        for i in 1..<candles.count {
            let c = candles[i]
            let previousClose = candles[i - 1].close
            let highLow = c.high - c.low
            let highPrevious = abs(c.high - previousClose)
            let lowPrevious = abs(c.low - previousClose)
            values.append(max(highLow, max(highPrevious, lowPrevious)))
        }
        return sma(values, period: period)
    }

    static func momentumPercent(_ values: [Double], lookback: Int) -> Double? {
        guard values.count > lookback else { return nil }
        let current = values[values.count - 1]
        let old = values[values.count - 1 - lookback]
        guard old != 0 else { return nil }
        return (current - old) / old * 100
    }

    static func trendStrength(close: Double, ema20: Double?, ema50: Double?, ema200: Double?) -> Double {
        guard let e20 = ema20, let e50 = ema50, close != 0 else { return 0 }
        let bull = close > e20 && e20 > e50
        let bear = close < e20 && e20 < e50
        let spread = abs(e20 - e50) / abs(close) * 100
        var score = min(spread * 20, 65)
        if bull || bear { score += 20 }
        if let longEMA = ema200 {
            if (bull && e50 > longEMA) || (bear && e50 < longEMA) {
                score += 15
            }
        }
        return min(100, max(0, score))
    }

    static func patterns(_ candles: [Candle]) -> [String] {
        guard let c = candles.last else { return [] }
        var out: [String] = []
        let body = abs(c.close - c.open)
        let range = max(c.high - c.low, 0.0000001)
        let lower = min(c.open, c.close) - c.low
        let upper = c.high - max(c.open, c.close)
        if body / range < 0.1 { out.append("Doji") }
        if lower > body * 2 && upper < body { out.append("Hammer") }
        if upper > body * 2 && lower < body { out.append("Shooting Star") }
        if candles.count >= 2 {
            let p = candles[candles.count - 2]
            let bullishEngulf = p.close < p.open && c.close > c.open && c.open <= p.close && c.close >= p.open
            let bearishEngulf = p.close > p.open && c.close < c.open && c.open >= p.close && c.close <= p.open
            if bullishEngulf { out.append("Bullish Engulfing") }
            if bearishEngulf { out.append("Bearish Engulfing") }
        }
        return out
    }
}
