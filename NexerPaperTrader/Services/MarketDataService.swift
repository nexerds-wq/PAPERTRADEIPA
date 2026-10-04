import Foundation

@MainActor
final class MarketDataService: ObservableObject {
    @Published var quotes: [String: Quote] = [:]
    @Published var loadingSymbols: Set<String> = []
    @Published var lastError: String?
    @Published var allUSStocks: [Asset] = []
    @Published var universeStatus: String = "Stock universe not loaded"

    private let session: URLSession
    private var lastRequestAt = Date.distantPast
    private var discoveredAssets: [String: Asset] = [:]

    private let universeCacheKey = "nexer.us.stock.universe.v2"
    private let universeCacheDateKey = "nexer.us.stock.universe.date.v2"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)

        for asset in Asset.universe {
            discoveredAssets[asset.id] = asset
        }
        loadCachedUniverse()
    }

    func asset(forID id: String) -> Asset? {
        discoveredAssets[id] ?? Asset.universe.first(where: { $0.id == id })
    }

    func quote(for asset: Asset, force: Bool = false) async -> Quote? {
        if !force, let q = quotes[asset.id], Date().timeIntervalSince(q.timestamp) < 15 {
            return q
        }

        loadingSymbols.insert(asset.id)
        defer { loadingSymbols.remove(asset.id) }

        do {
            let chart = try await fetchChart(symbol: asset.symbol, range: "5d", interval: "5m", includePrePost: true)
            guard let result = chart.chart.result?.first else { throw URLError(.cannotParseResponse) }
            let candles = parseCandles(result)
            guard let latest = result.meta.regularMarketPrice ?? candles.last?.close else { throw URLError(.cannotParseResponse) }

            let previous = result.meta.chartPreviousClose ?? result.meta.previousClose ?? candles.dropLast().last?.close ?? latest
            let q = Quote(symbol: asset.symbol, price: latest, previousClose: previous, timestamp: Date())
            quotes[asset.id] = q
            discoveredAssets[asset.id] = asset
            lastError = nil
            return q
        } catch {
            lastError = error.localizedDescription
            return quotes[asset.id]
        }
    }

    func refreshUniverse(_ assets: [Asset] = Asset.universe) async {
        for asset in assets {
            _ = await quote(for: asset, force: true)
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    func fetchCandles(symbol: String, range: String = "1mo", interval: String = "1d", includePrePost: Bool = false) async throws -> [Candle] {
        let decoded = try await fetchChart(symbol: symbol, range: range, interval: interval, includePrePost: includePrePost)
        guard let result = decoded.chart.result?.first else { return [] }
        return parseCandles(result)
    }

    /// Loads the U.S. listed stock/ETF directory without an API key.
    /// Price history still comes from Yahoo Finance's public chart endpoint.
    func loadUSStockUniverse(force: Bool = false) async {
        if !force,
           !allUSStocks.isEmpty,
           let cacheDate = UserDefaults.standard.object(forKey: universeCacheDateKey) as? Date,
           Date().timeIntervalSince(cacheDate) < 24 * 60 * 60 {
            universeStatus = "\(allUSStocks.count) U.S. symbols loaded"
            return
        }

        universeStatus = "Loading U.S. market symbols…"

        do {
            async let nasdaqText = fetchText("https://www.nasdaqtrader.com/dynamic/SymDir/nasdaqlisted.txt")
            async let otherText = fetchText("https://www.nasdaqtrader.com/dynamic/SymDir/otherlisted.txt")
            let (nasdaq, other) = try await (nasdaqText, otherText)

            var merged: [String: Asset] = [:]
            for asset in parseNasdaqListed(nasdaq) { merged[asset.id] = asset }
            for asset in parseOtherListed(other) { merged[asset.id] = asset }

            for asset in Asset.universe where asset.type == .stock || asset.type == .etf {
                merged[asset.id] = asset
            }

            let sorted = merged.values.sorted {
                $0.displaySymbol.localizedStandardCompare($1.displaySymbol) == .orderedAscending
            }

            allUSStocks = sorted
            for asset in sorted { discoveredAssets[asset.id] = asset }

            if let data = try? JSONEncoder().encode(sorted) {
                UserDefaults.standard.set(data, forKey: universeCacheKey)
                UserDefaults.standard.set(Date(), forKey: universeCacheDateKey)
            }

            universeStatus = "\(sorted.count) U.S. symbols loaded"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if allUSStocks.isEmpty {
                let fallback = Asset.universe.filter { $0.type == .stock || $0.type == .etf }
                allUSStocks = fallback
                for asset in fallback { discoveredAssets[asset.id] = asset }
                universeStatus = "Using \(fallback.count) fallback symbols"
            } else {
                universeStatus = "\(allUSStocks.count) cached symbols loaded"
            }
        }
    }

    private func loadCachedUniverse() {
        guard let data = UserDefaults.standard.data(forKey: universeCacheKey),
              let assets = try? JSONDecoder().decode([Asset].self, from: data),
              !assets.isEmpty else {
            let fallback = Asset.universe.filter { $0.type == .stock || $0.type == .etf }
            allUSStocks = fallback
            for asset in fallback { discoveredAssets[asset.id] = asset }
            return
        }

        allUSStocks = assets
        for asset in assets { discoveredAssets[asset.id] = asset }
        universeStatus = "\(assets.count) cached U.S. symbols loaded"
    }

    private func fetchText(_ urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let text = String(data: data, encoding: .utf8) else {
            throw URLError(.badServerResponse)
        }
        return text
    }

    private func parseNasdaqListed(_ text: String) -> [Asset] {
        var output: [Asset] = []

        for line in text.split(whereSeparator: { $0.isNewline }).dropFirst() {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 8 else { continue }

            let rawSymbol = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let testIssue = fields[3].uppercased()
            let isETF = fields[6].uppercased() == "Y"

            guard testIssue != "Y",
                  let symbol = normalizedYahooSymbol(rawSymbol),
                  isTradableSecurityName(name) else { continue }

            output.append(Asset(id: symbol, symbol: symbol, displaySymbol: rawSymbol, name: cleanSecurityName(name), type: isETF ? .etf : .stock))
        }

        return output
    }

    private func parseOtherListed(_ text: String) -> [Asset] {
        var output: [Asset] = []

        for line in text.split(whereSeparator: { $0.isNewline }).dropFirst() {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { continue }

            let rawSymbol = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let isETF = fields[4].uppercased() == "Y"
            let testIssue = fields[6].uppercased()

            guard testIssue != "Y",
                  let symbol = normalizedYahooSymbol(rawSymbol),
                  isTradableSecurityName(name) else { continue }

            output.append(Asset(id: symbol, symbol: symbol, displaySymbol: rawSymbol, name: cleanSecurityName(name), type: isETF ? .etf : .stock))
        }

        return output
    }

    private func normalizedYahooSymbol(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 12,
              !trimmed.contains("^"),
              !trimmed.contains("/") else { return nil }

        let yahoo = trimmed.replacingOccurrences(of: ".", with: "-")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        guard yahoo.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return yahoo.uppercased()
    }

    private func isTradableSecurityName(_ name: String) -> Bool {
        let n = name.lowercased()
        let blocked = [
            "warrant", "rights", "right exp", "units", "unit exp",
            "preferred", "depositary shares", "notes due", "senior notes",
            "debenture", "bond", "test stock"
        ]
        return !blocked.contains(where: { n.contains($0) })
    }

    private func cleanSecurityName(_ name: String) -> String {
        name.replacingOccurrences(of: " - Common Stock", with: "")
            .replacingOccurrences(of: " Common Stock", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchChart(symbol: String, range: String, interval: String, includePrePost: Bool) async throws -> YahooChartResponse {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < 0.25 {
            try? await Task.sleep(nanoseconds: UInt64((0.25 - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()

        let encoded = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol
        let prePost = includePrePost ? "true" : "false"
        guard let url = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(encoded)?range=\(range)&interval=\(interval)&includePrePost=\(prePost)&events=div%2Csplits") else {
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
                    try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 900_000_000))
                    continue
                }

                guard 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
                return try JSONDecoder().decode(YahooChartResponse.self, from: data)
            } catch {
                lastFailure = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64((attempt + 1) * 500_000_000))
                }
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
