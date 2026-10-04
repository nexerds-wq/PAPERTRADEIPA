import Foundation
import UserNotifications

// MARK: - Professional auto-trader models
enum ProTradeSide: String, Codable {
    case long = "BUY"
    case short = "SHORT"
}

struct ProTradeState: Codable {
    let assetID: String
    let side: ProTradeSide
    let entry: Double
    var stop: Double
    let target: Double
    let initialRisk: Double
    let quantity: Double
    let notional: Double
    let openedAt: Date
    var bestR: Double
}

struct ProRiskLedger: Codable {
    var dayKey: String
    var realizedPL: Double
    var trades: Int
    var consecutiveLosses: Int
}

struct ProBacktestReport: Codable {
    var trades: Int = 0
    var wins: Int = 0
    var losses: Int = 0
    var breakEvens: Int = 0
    var grossWinR: Double = 0
    var grossLossR: Double = 0
    var netR: Double = 0
    var maxDrawdownR: Double = 0

    var winRate: Double { trades > 0 ? Double(wins) / Double(trades) : 0 }
    var expectancyR: Double { trades > 0 ? netR / Double(trades) : 0 }
    var profitFactor: Double {
        let loss = abs(grossLossR)
        if loss > 0 { return grossWinR / loss }
        return grossWinR > 0 ? 99 : 0
    }

    static func combined(_ reports: [ProBacktestReport]) -> ProBacktestReport {
        var out = ProBacktestReport()
        for r in reports {
            out.trades += r.trades
            out.wins += r.wins
            out.losses += r.losses
            out.breakEvens += r.breakEvens
            out.grossWinR += r.grossWinR
            out.grossLossR += r.grossLossR
            out.netR += r.netR
            out.maxDrawdownR = max(out.maxDrawdownR, r.maxDrawdownR)
        }
        return out
    }
}

struct ProValidationSummary: Codable {
    let dayKey: String
    let gaugeThreshold: Int
    let approved: Bool
    let combined: ProBacktestReport
    let outOfSample: ProBacktestReport
    let stress: ProBacktestReport
    let profitableHorizons: Int
    let worstHorizonPF: Double
    let recentTrades: Int
    let sixMonthTrades: Int
    let oneYearTrades: Int
}

struct ProGaugeSnapshot {
    let score: Int
    let label: String
    let rsi: Double
    let adx: Double
    let atr: Double
    let atrPercent: Double
    let plusDI: Double
    let minusDI: Double
    let volumeRatio: Double
    let vwap: Double
    let ema20: Double
    let ema50: Double
    let ema200: Double
    let reasons: [String]
}

struct ProSetup {
    let side: ProTradeSide
    let entry: Double
    let stop: Double
    let target: Double
    let zoneLow: Double
    let zoneHigh: Double
    let atr: Double
    let gauge: ProGaugeSnapshot
    let barTime: Date
    let quality: Int
}

struct ProCandidate: Identifiable {
    let asset: Asset
    let setup: ProSetup
    let higherTimeframeScore: Int
    let marketScore: Int
    let validation: ProValidationSummary

    var id: String { "\(asset.id)-\(setup.side.rawValue)" }
}

// MARK: - Persistence
enum ProStore {
    static let tradePrefix = "nexer.pro.trade.v1."
    static let ledgerKey = "nexer.pro.risk.ledger.v1"
    static let validationPrefix = "nexer.pro.validation.v1."
    static let cooldownPrefix = "nexer.pro.cooldown.v1."

    static func dayKey(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func tradeKey(_ assetID: String) -> String { tradePrefix + assetID }

    static func loadTrade(_ assetID: String) -> ProTradeState? {
        guard let data = UserDefaults.standard.data(forKey: tradeKey(assetID)) else { return nil }
        return try? JSONDecoder().decode(ProTradeState.self, from: data)
    }

    static func saveTrade(_ state: ProTradeState) {
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: tradeKey(state.assetID))
        }
    }

    static func clearTrade(_ assetID: String) {
        UserDefaults.standard.removeObject(forKey: tradeKey(assetID))
    }

    static func activeTradeIDs() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key in
            guard key.hasPrefix(tradePrefix) else { return nil }
            return String(key.dropFirst(tradePrefix.count))
        }
    }

    static func ledger() -> ProRiskLedger {
        if let data = UserDefaults.standard.data(forKey: ledgerKey),
           let decoded = try? JSONDecoder().decode(ProRiskLedger.self, from: data),
           decoded.dayKey == dayKey() {
            return decoded
        }
        return ProRiskLedger(dayKey: dayKey(), realizedPL: 0, trades: 0, consecutiveLosses: 0)
    }

    static func saveLedger(_ ledger: ProRiskLedger) {
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: ledgerKey)
        }
    }

    static func recordClose(pl: Double) {
        var l = ledger()
        l.realizedPL += pl
        l.trades += 1
        l.consecutiveLosses = pl < 0 ? l.consecutiveLosses + 1 : 0
        saveLedger(l)
    }

    static func loadValidation(_ assetID: String, gaugeThreshold: Int) -> ProValidationSummary? {
        guard let data = UserDefaults.standard.data(forKey: validationPrefix + assetID),
              let v = try? JSONDecoder().decode(ProValidationSummary.self, from: data),
              v.dayKey == dayKey(),
              v.gaugeThreshold == gaugeThreshold else { return nil }
        return v
    }

    static func saveValidation(_ value: ProValidationSummary, assetID: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: validationPrefix + assetID)
        }
    }

    static func setCooldown(_ assetID: String, until: Date) {
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: cooldownPrefix + assetID)
    }

    static func isCoolingDown(_ assetID: String) -> Bool {
        let until = UserDefaults.standard.double(forKey: cooldownPrefix + assetID)
        return until > Date().timeIntervalSince1970
    }
}

actor ProNotifier {
    static let shared = ProNotifier()

    func prepare() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    func send(_ title: String, _ body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
