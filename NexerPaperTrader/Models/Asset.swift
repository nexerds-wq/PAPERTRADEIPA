import Foundation

enum AssetType: String, Codable, CaseIterable, Identifiable {
    case stock = "Stocks"
    case etf = "ETFs"
    case crypto = "Crypto"
    case forex = "Forex"
    case index = "Indexes"
    case commodity = "Commodities"
    var id: String { rawValue }
}

struct Asset: Identifiable, Codable, Hashable {
    let id: String
    let symbol: String
    let displaySymbol: String
    let name: String
    let type: AssetType

    static let universe: [Asset] = [
        // MARK: Stocks
        .init(id: "AAPL", symbol: "AAPL", displaySymbol: "AAPL", name: "Apple", type: .stock),
        .init(id: "MSFT", symbol: "MSFT", displaySymbol: "MSFT", name: "Microsoft", type: .stock),
        .init(id: "NVDA", symbol: "NVDA", displaySymbol: "NVDA", name: "NVIDIA", type: .stock),
        .init(id: "TSLA", symbol: "TSLA", displaySymbol: "TSLA", name: "Tesla", type: .stock),
        .init(id: "AMZN", symbol: "AMZN", displaySymbol: "AMZN", name: "Amazon", type: .stock),
        .init(id: "META", symbol: "META", displaySymbol: "META", name: "Meta Platforms", type: .stock),
        .init(id: "GOOGL", symbol: "GOOGL", displaySymbol: "GOOGL", name: "Alphabet Class A", type: .stock),
        .init(id: "GOOG", symbol: "GOOG", displaySymbol: "GOOG", name: "Alphabet Class C", type: .stock),
        .init(id: "AVGO", symbol: "AVGO", displaySymbol: "AVGO", name: "Broadcom", type: .stock),
        .init(id: "AMD", symbol: "AMD", displaySymbol: "AMD", name: "AMD", type: .stock),
        .init(id: "NFLX", symbol: "NFLX", displaySymbol: "NFLX", name: "Netflix", type: .stock),
        .init(id: "ORCL", symbol: "ORCL", displaySymbol: "ORCL", name: "Oracle", type: .stock),
        .init(id: "CRM", symbol: "CRM", displaySymbol: "CRM", name: "Salesforce", type: .stock),
        .init(id: "ADBE", symbol: "ADBE", displaySymbol: "ADBE", name: "Adobe", type: .stock),
        .init(id: "INTC", symbol: "INTC", displaySymbol: "INTC", name: "Intel", type: .stock),
        .init(id: "QCOM", symbol: "QCOM", displaySymbol: "QCOM", name: "Qualcomm", type: .stock),
        .init(id: "MU", symbol: "MU", displaySymbol: "MU", name: "Micron", type: .stock),
        .init(id: "ARM", symbol: "ARM", displaySymbol: "ARM", name: "Arm Holdings", type: .stock),
        .init(id: "PLTR", symbol: "PLTR", displaySymbol: "PLTR", name: "Palantir", type: .stock),
        .init(id: "COIN", symbol: "COIN", displaySymbol: "COIN", name: "Coinbase", type: .stock),
        .init(id: "HOOD", symbol: "HOOD", displaySymbol: "HOOD", name: "Robinhood", type: .stock),
        .init(id: "JPM", symbol: "JPM", displaySymbol: "JPM", name: "JPMorgan Chase", type: .stock),
        .init(id: "BAC", symbol: "BAC", displaySymbol: "BAC", name: "Bank of America", type: .stock),
        .init(id: "WFC", symbol: "WFC", displaySymbol: "WFC", name: "Wells Fargo", type: .stock),
        .init(id: "GS", symbol: "GS", displaySymbol: "GS", name: "Goldman Sachs", type: .stock),
        .init(id: "V", symbol: "V", displaySymbol: "V", name: "Visa", type: .stock),
        .init(id: "MA", symbol: "MA", displaySymbol: "MA", name: "Mastercard", type: .stock),
        .init(id: "PYPL", symbol: "PYPL", displaySymbol: "PYPL", name: "PayPal", type: .stock),
        .init(id: "WMT", symbol: "WMT", displaySymbol: "WMT", name: "Walmart", type: .stock),
        .init(id: "COST", symbol: "COST", displaySymbol: "COST", name: "Costco", type: .stock),
        .init(id: "HD", symbol: "HD", displaySymbol: "HD", name: "Home Depot", type: .stock),
        .init(id: "MCD", symbol: "MCD", displaySymbol: "MCD", name: "McDonald's", type: .stock),
        .init(id: "NKE", symbol: "NKE", displaySymbol: "NKE", name: "Nike", type: .stock),
        .init(id: "DIS", symbol: "DIS", displaySymbol: "DIS", name: "Disney", type: .stock),
        .init(id: "KO", symbol: "KO", displaySymbol: "KO", name: "Coca-Cola", type: .stock),
        .init(id: "PEP", symbol: "PEP", displaySymbol: "PEP", name: "PepsiCo", type: .stock),
        .init(id: "LLY", symbol: "LLY", displaySymbol: "LLY", name: "Eli Lilly", type: .stock),
        .init(id: "JNJ", symbol: "JNJ", displaySymbol: "JNJ", name: "Johnson & Johnson", type: .stock),
        .init(id: "UNH", symbol: "UNH", displaySymbol: "UNH", name: "UnitedHealth", type: .stock),
        .init(id: "XOM", symbol: "XOM", displaySymbol: "XOM", name: "Exxon Mobil", type: .stock),
        .init(id: "CVX", symbol: "CVX", displaySymbol: "CVX", name: "Chevron", type: .stock),
        .init(id: "BA", symbol: "BA", displaySymbol: "BA", name: "Boeing", type: .stock),
        .init(id: "CAT", symbol: "CAT", displaySymbol: "CAT", name: "Caterpillar", type: .stock),
        .init(id: "GE", symbol: "GE", displaySymbol: "GE", name: "GE Aerospace", type: .stock),
        .init(id: "F", symbol: "F", displaySymbol: "F", name: "Ford", type: .stock),
        .init(id: "GM", symbol: "GM", displaySymbol: "GM", name: "General Motors", type: .stock),
        .init(id: "UBER", symbol: "UBER", displaySymbol: "UBER", name: "Uber", type: .stock),
        .init(id: "ABNB", symbol: "ABNB", displaySymbol: "ABNB", name: "Airbnb", type: .stock),
        .init(id: "RBLX", symbol: "RBLX", displaySymbol: "RBLX", name: "Roblox", type: .stock),
        .init(id: "SNAP", symbol: "SNAP", displaySymbol: "SNAP", name: "Snap", type: .stock),
        .init(id: "SHOP", symbol: "SHOP", displaySymbol: "SHOP", name: "Shopify", type: .stock),
        .init(id: "SQ", symbol: "XYZ", displaySymbol: "XYZ", name: "Block", type: .stock),
        .init(id: "SOFI", symbol: "SOFI", displaySymbol: "SOFI", name: "SoFi", type: .stock),
        .init(id: "RKLB", symbol: "RKLB", displaySymbol: "RKLB", name: "Rocket Lab", type: .stock),
        .init(id: "SMCI", symbol: "SMCI", displaySymbol: "SMCI", name: "Super Micro Computer", type: .stock),

        // MARK: ETFs
        .init(id: "SPY", symbol: "SPY", displaySymbol: "SPY", name: "SPDR S&P 500 ETF", type: .etf),
        .init(id: "VOO", symbol: "VOO", displaySymbol: "VOO", name: "Vanguard S&P 500 ETF", type: .etf),
        .init(id: "QQQ", symbol: "QQQ", displaySymbol: "QQQ", name: "Invesco QQQ", type: .etf),
        .init(id: "QQQM", symbol: "QQQM", displaySymbol: "QQQM", name: "Invesco NASDAQ 100 ETF", type: .etf),
        .init(id: "VTI", symbol: "VTI", displaySymbol: "VTI", name: "Vanguard Total Stock Market ETF", type: .etf),
        .init(id: "IWM", symbol: "IWM", displaySymbol: "IWM", name: "iShares Russell 2000 ETF", type: .etf),
        .init(id: "DIA", symbol: "DIA", displaySymbol: "DIA", name: "SPDR Dow Jones ETF", type: .etf),
        .init(id: "SCHD", symbol: "SCHD", displaySymbol: "SCHD", name: "Schwab U.S. Dividend Equity ETF", type: .etf),
        .init(id: "XLK", symbol: "XLK", displaySymbol: "XLK", name: "Technology Select Sector ETF", type: .etf),
        .init(id: "XLF", symbol: "XLF", displaySymbol: "XLF", name: "Financial Select Sector ETF", type: .etf),
        .init(id: "XLE", symbol: "XLE", displaySymbol: "XLE", name: "Energy Select Sector ETF", type: .etf),
        .init(id: "SMH", symbol: "SMH", displaySymbol: "SMH", name: "VanEck Semiconductor ETF", type: .etf),
        .init(id: "SOXX", symbol: "SOXX", displaySymbol: "SOXX", name: "iShares Semiconductor ETF", type: .etf),
        .init(id: "ARKK", symbol: "ARKK", displaySymbol: "ARKK", name: "ARK Innovation ETF", type: .etf),
        .init(id: "GLD", symbol: "GLD", displaySymbol: "GLD", name: "SPDR Gold Shares", type: .etf),
        .init(id: "SLV", symbol: "SLV", displaySymbol: "SLV", name: "iShares Silver Trust", type: .etf),

        // MARK: Crypto
        .init(id: "BTC-USD", symbol: "BTC-USD", displaySymbol: "BTC/USD", name: "Bitcoin", type: .crypto),
        .init(id: "ETH-USD", symbol: "ETH-USD", displaySymbol: "ETH/USD", name: "Ethereum", type: .crypto),
        .init(id: "SOL-USD", symbol: "SOL-USD", displaySymbol: "SOL/USD", name: "Solana", type: .crypto),
        .init(id: "XRP-USD", symbol: "XRP-USD", displaySymbol: "XRP/USD", name: "XRP", type: .crypto),
        .init(id: "DOGE-USD", symbol: "DOGE-USD", displaySymbol: "DOGE/USD", name: "Dogecoin", type: .crypto),
        .init(id: "ADA-USD", symbol: "ADA-USD", displaySymbol: "ADA/USD", name: "Cardano", type: .crypto),
        .init(id: "AVAX-USD", symbol: "AVAX-USD", displaySymbol: "AVAX/USD", name: "Avalanche", type: .crypto),
        .init(id: "LINK-USD", symbol: "LINK-USD", displaySymbol: "LINK/USD", name: "Chainlink", type: .crypto),
        .init(id: "LTC-USD", symbol: "LTC-USD", displaySymbol: "LTC/USD", name: "Litecoin", type: .crypto),
        .init(id: "BCH-USD", symbol: "BCH-USD", displaySymbol: "BCH/USD", name: "Bitcoin Cash", type: .crypto),
        .init(id: "DOT-USD", symbol: "DOT-USD", displaySymbol: "DOT/USD", name: "Polkadot", type: .crypto),
        .init(id: "UNI-USD", symbol: "UNI-USD", displaySymbol: "UNI/USD", name: "Uniswap", type: .crypto),
        .init(id: "SHIB-USD", symbol: "SHIB-USD", displaySymbol: "SHIB/USD", name: "Shiba Inu", type: .crypto),
        .init(id: "PEPE-USD", symbol: "PEPE-USD", displaySymbol: "PEPE/USD", name: "Pepe", type: .crypto),

        // MARK: Forex
        .init(id: "EURUSD=X", symbol: "EURUSD=X", displaySymbol: "EUR/USD", name: "Euro / U.S. Dollar", type: .forex),
        .init(id: "GBPUSD=X", symbol: "GBPUSD=X", displaySymbol: "GBP/USD", name: "British Pound / U.S. Dollar", type: .forex),
        .init(id: "USDJPY=X", symbol: "USDJPY=X", displaySymbol: "USD/JPY", name: "U.S. Dollar / Japanese Yen", type: .forex),
        .init(id: "USDCHF=X", symbol: "USDCHF=X", displaySymbol: "USD/CHF", name: "U.S. Dollar / Swiss Franc", type: .forex),
        .init(id: "AUDUSD=X", symbol: "AUDUSD=X", displaySymbol: "AUD/USD", name: "Australian Dollar / U.S. Dollar", type: .forex),
        .init(id: "NZDUSD=X", symbol: "NZDUSD=X", displaySymbol: "NZD/USD", name: "New Zealand Dollar / U.S. Dollar", type: .forex),
        .init(id: "USDCAD=X", symbol: "USDCAD=X", displaySymbol: "USD/CAD", name: "U.S. Dollar / Canadian Dollar", type: .forex),
        .init(id: "EURGBP=X", symbol: "EURGBP=X", displaySymbol: "EUR/GBP", name: "Euro / British Pound", type: .forex),
        .init(id: "EURJPY=X", symbol: "EURJPY=X", displaySymbol: "EUR/JPY", name: "Euro / Japanese Yen", type: .forex),
        .init(id: "GBPJPY=X", symbol: "GBPJPY=X", displaySymbol: "GBP/JPY", name: "British Pound / Japanese Yen", type: .forex),
        .init(id: "AUDJPY=X", symbol: "AUDJPY=X", displaySymbol: "AUD/JPY", name: "Australian Dollar / Japanese Yen", type: .forex),
        .init(id: "EURCHF=X", symbol: "EURCHF=X", displaySymbol: "EUR/CHF", name: "Euro / Swiss Franc", type: .forex),

        // MARK: Indexes
        .init(id: "^GSPC", symbol: "^GSPC", displaySymbol: "S&P 500", name: "S&P 500 Index", type: .index),
        .init(id: "^IXIC", symbol: "^IXIC", displaySymbol: "NASDAQ", name: "NASDAQ Composite", type: .index),
        .init(id: "^DJI", symbol: "^DJI", displaySymbol: "DOW", name: "Dow Jones Industrial Average", type: .index),
        .init(id: "^RUT", symbol: "^RUT", displaySymbol: "RUT", name: "Russell 2000 Index", type: .index),
        .init(id: "^VIX", symbol: "^VIX", displaySymbol: "VIX", name: "CBOE Volatility Index", type: .index),

        // MARK: Commodities
        .init(id: "GC=F", symbol: "GC=F", displaySymbol: "Gold", name: "Gold Futures", type: .commodity),
        .init(id: "SI=F", symbol: "SI=F", displaySymbol: "Silver", name: "Silver Futures", type: .commodity),
        .init(id: "CL=F", symbol: "CL=F", displaySymbol: "Oil", name: "Crude Oil Futures", type: .commodity),
        .init(id: "NG=F", symbol: "NG=F", displaySymbol: "Nat Gas", name: "Natural Gas Futures", type: .commodity)
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
