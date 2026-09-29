import Foundation

@MainActor
final class MarketDataService: ObservableObject {
    @Published var quotes: [String: Quote] = [:]
    @Published var loadingSymbols: Set<String> = []
    @Published var lastError: String?

    private let session: URLSession
    private var lastRequestAt = Date.distantPast

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
            let chart = try await fetchChart(symbol: asset.symbol, range: "5d", interval: "5m")
            guard let result = chart.chart.result?.first else { throw URLError(.cannotParseResponse) }
            let candles = parseCandles(result)
            guard let latest = result.meta.regularMarketPrice ?? candles.last?.close else { throw URLError(.cannotParseResponse) }

            // Use Yahoo's actual prior session close when available instead of the previous 5-minute candle.
            let previous = result.meta.chartPreviousClose ?? result.meta.previousClose ?? candles.dropLast().last?.close ?? latest
            let q = Quote(symbol: asset.symbol, price: latest, previousClose: previous, timestamp: Date())
            quotes[asset.id] = q
            lastError = nil
            return q
        } catch {
            lastError = error.localizedDescription
            return quotes[asset.id]
        }
    }

    func refreshUniverse(_ assets: [Asset] = Asset.universe) async {
        // A small sequential delay is intentional because this is a free unofficial endpoint.
        // It avoids hammering the source and makes rate limiting less likely.
        for asset in assets {
            _ = await quote(for: asset, force: true)
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    func fetchCandles(symbol: String, range: String = "1mo", interval: String = "1d") async throws -> [Candle] {
        let decoded = try await fetchChart(symbol: symbol, range: range, interval: interval)
        guard let result = decoded.chart.result?.first else { return [] }
        return parseCandles(result)
    }

    private func fetchChart(symbol: String, range: String, interval: String) async throws -> YahooChartResponse {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < 0.25 {
            try? await Task.sleep(nanoseconds: UInt64((0.25 - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()

        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        guard let url = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(encoded)?range=\(range)&interval=\(interval)&includePrePost=true&events=div%2Csplits") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var lastFailure: Error = URLError(.badServerResponse)

        for attempt in 0..<3 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

                if http.statusCode == 429 {
                    lastFailure = URLError(.resourceUnavailable)
                    try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 800_000_000))
                    continue
                }

                guard 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
                return try JSONDecoder().decode(YahooChartResponse.self, from: data)
            } catch {
                lastFailure = error
                if attempt < 2 { try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 500_000_000)) }
            }
        }

        throw lastFailure
    }

    private func parseCandles(_ result: YahooChartResponse.Result) -> [Candle] {
        guard let timestamps = result.timestamp,
              let quote = result.indicators.quote.first else { return [] }

        return timestamps.enumerated().compactMap { idx, ts in
            guard idx < quote.close.count,
                  idx < quote.open.count,
                  idx < quote.high.count,
                  idx < quote.low.count,
                  let o = quote.open[idx],
                  let h = quote.high[idx],
                  let l = quote.low[idx],
                  let c = quote.close[idx] else { return nil }

            let v = idx < quote.volume.count ? Double(quote.volume[idx] ?? 0) : 0
            let d = Date(timeIntervalSince1970: TimeInterval(ts))
            return Candle(id: d, date: d, open: o, high: h, low: l, close: c, volume: v)
        }
    }
}

private struct YahooChartResponse: Decodable {
    let chart: Chart

    struct Chart: Decodable {
        let result: [Result]?
    }

    struct Result: Decodable {
        let meta: Meta
        let timestamp: [Int]?
        let indicators: Indicators
    }

    struct Meta: Decodable {
        let regularMarketPrice: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
    }

    struct Indicators: Decodable {
        let quote: [OHLC]
    }

    struct OHLC: Decodable {
        let open: [Double?]
        let high: [Double?]
        let low: [Double?]
        let close: [Double?]
        let volume: [Int?]
    }
}
