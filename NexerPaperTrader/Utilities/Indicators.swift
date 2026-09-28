import Foundation

struct TechnicalSnapshot {
    let rsi: Double?
    let macd: Double?
    let signal: Double?
    let histogram: Double?
    let ema20: Double?
    let ema50: Double?
    let trend: String
    let patterns: [String]
}

enum Indicators {
    static func snapshot(_ candles: [Candle]) -> TechnicalSnapshot {
        let closes = candles.map(\.close)
        let rsiValue = rsi(closes, period: 14)
        let m = macd(closes)
        let e20 = ema(closes, period: 20).last
        let e50 = ema(closes, period: 50).last
        let last = closes.last
        var score = 0
        if let r = rsiValue { if r < 35 { score += 1 }; if r > 70 { score -= 1 } }
        if let h = m.histogram { score += h >= 0 ? 1 : -1 }
        if let l = last, let e = e20 { score += l >= e ? 1 : -1 }
        if let e20, let e50 { score += e20 >= e50 ? 1 : -1 }
        let trend = score >= 2 ? "Bullish" : score <= -2 ? "Bearish" : "Neutral"
        return .init(rsi: rsiValue, macd: m.macd, signal: m.signal, histogram: m.histogram, ema20: e20, ema50: e50, trend: trend, patterns: patterns(candles))
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
        for v in values.dropFirst() { result.append(v * k + (result.last ?? v) * (1 - k)) }
        return result
    }

    static func macd(_ values: [Double]) -> (macd: Double?, signal: Double?, histogram: Double?) {
        guard values.count >= 26 else { return (nil,nil,nil) }
        let e12 = ema(values, period: 12)
        let e26 = ema(values, period: 26)
        let line = zip(e12, e26).map { $0.0 - $0.1 }
        let sig = ema(line, period: 9)
        guard let m = line.last, let s = sig.last else { return (nil,nil,nil) }
        return (m, s, m - s)
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
