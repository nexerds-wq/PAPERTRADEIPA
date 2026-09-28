import Foundation

@MainActor
final class MarketDataService: ObservableObject {
    @Published var quotes: [String: Quote] = [:]
    @Published var loadingSymbols: Set<String> = []
    @Published var lastError: String?

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    func quote(for asset: Asset, force: Bool = false) async -> Quote? {
        if !force, let q = quotes[asset.id], Date().timeIntervalSince(q.timestamp) < 20 { return q }
        loadingSymbols.insert(asset.id)
        defer { loadingSymbols.remove(asset.id) }
        do {
            let candles = try await fetchCandles(symbol: asset.symbol, range: "5d", interval: "5m")
            guard let last = candles.last else { return nil }
            let prior = candles.dropLast().last?.close ?? last.close
            let q = Quote(symbol: asset.symbol, price: last.close, previousClose: prior, timestamp: Date())
            quotes[asset.id] = q
            return q
        } catch {
            lastError = error.localizedDescription
            return quotes[asset.id]
        }
    }

    func refreshUniverse(_ assets: [Asset] = Asset.universe) async {
        await withTaskGroup(of: Void.self) { group in
            for asset in assets {
                group.addTask { @MainActor in _ = await self.quote(for: asset, force: true) }
            }
        }
    }

    func fetchCandles(symbol: String, range: String = "1mo", interval: String = "1d") async throws -> [Candle] {
        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encoded)?range=\(range)&interval=\(interval)&includePrePost=false&events=div%2Csplits") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first,
              let timestamps = result.timestamp,
              let quote = result.indicators.quote.first else { return [] }

        return timestamps.enumerated().compactMap { idx, ts in
            guard idx < quote.close.count,
                  let o = quote.open[idx], let h = quote.high[idx], let l = quote.low[idx], let c = quote.close[idx] else { return nil }
            let v = idx < quote.volume.count ? Double(quote.volume[idx] ?? 0) : 0
            let d = Date(timeIntervalSince1970: TimeInterval(ts))
            return Candle(id: d, date: d, open: o, high: h, low: l, close: c, volume: v)
        }
    }
}

private struct YahooChartResponse: Decodable {
    let chart: Chart
    struct Chart: Decodable { let result: [Result]? }
    struct Result: Decodable {
        let timestamp: [Int]?
        let indicators: Indicators
    }
    struct Indicators: Decodable { let quote: [OHLC] }
    struct OHLC: Decodable {
        let open: [Double?]
        let high: [Double?]
        let low: [Double?]
        let close: [Double?]
        let volume: [Int?]
    }
}
