import Foundation

enum AssetType: String, Codable, CaseIterable, Identifiable {
    case stock = "Stocks"
    case etf = "ETFs"
    case crypto = "Crypto"
    case forex = "Forex"
    var id: String { rawValue }
}

struct Asset: Identifiable, Codable, Hashable {
    let id: String
    let symbol: String
    let displaySymbol: String
    let name: String
    let type: AssetType

    static let universe: [Asset] = [
        .init(id: "AAPL", symbol: "AAPL", displaySymbol: "AAPL", name: "Apple", type: .stock),
        .init(id: "MSFT", symbol: "MSFT", displaySymbol: "MSFT", name: "Microsoft", type: .stock),
        .init(id: "NVDA", symbol: "NVDA", displaySymbol: "NVDA", name: "NVIDIA", type: .stock),
        .init(id: "TSLA", symbol: "TSLA", displaySymbol: "TSLA", name: "Tesla", type: .stock),
        .init(id: "AMZN", symbol: "AMZN", displaySymbol: "AMZN", name: "Amazon", type: .stock),
        .init(id: "META", symbol: "META", displaySymbol: "META", name: "Meta Platforms", type: .stock),
        .init(id: "GOOGL", symbol: "GOOGL", displaySymbol: "GOOGL", name: "Alphabet", type: .stock),
        .init(id: "SPY", symbol: "SPY", displaySymbol: "SPY", name: "SPDR S&P 500 ETF", type: .etf),
        .init(id: "QQQ", symbol: "QQQ", displaySymbol: "QQQ", name: "Invesco QQQ ETF", type: .etf),
        .init(id: "BTC-USD", symbol: "BTC-USD", displaySymbol: "BTC/USD", name: "Bitcoin", type: .crypto),
        .init(id: "ETH-USD", symbol: "ETH-USD", displaySymbol: "ETH/USD", name: "Ethereum", type: .crypto),
        .init(id: "SOL-USD", symbol: "SOL-USD", displaySymbol: "SOL/USD", name: "Solana", type: .crypto),
        .init(id: "EURUSD=X", symbol: "EURUSD=X", displaySymbol: "EUR/USD", name: "Euro / U.S. Dollar", type: .forex),
        .init(id: "GBPUSD=X", symbol: "GBPUSD=X", displaySymbol: "GBP/USD", name: "British Pound / U.S. Dollar", type: .forex),
        .init(id: "USDJPY=X", symbol: "USDJPY=X", displaySymbol: "USD/JPY", name: "U.S. Dollar / Japanese Yen", type: .forex)
    ]
}

struct Quote: Codable, Hashable {
    let symbol: String
    let price: Double
    let previousClose: Double
    let timestamp: Date

    var change: Double { price - previousClose }
    var changePercent: Double { previousClose == 0 ? 0 : change / previousClose * 100 }
}

struct Candle: Identifiable, Codable, Hashable {
    let id: Date
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double
}
