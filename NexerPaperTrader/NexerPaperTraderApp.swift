import SwiftUI
import Foundation
import UserNotifications

@main
struct NexerPaperTraderApp: App {
    @StateObject private var portfolio = PortfolioStore()
    @StateObject private var market = MarketDataService()

    var body: some Scene {
        WindowGroup {
            MainAppView()
                .environmentObject(portfolio)
                .environmentObject(market)
                .preferredColorScheme(.dark)
        }
    }
}

struct MainAppView: View {
    var body: some View {
        TabView {
            NavigationStack { SupplyDemandAutoTraderView() }
                .tabItem { Label("Retest", systemImage: "arrow.triangle.2.circlepath") }

            NavigationStack { SignalDashboardView() }
                .tabItem { Label("Signals", systemImage: "gauge.with.dots.needle.67percent") }

            NavigationStack { PortfolioView() }
                .tabItem { Label("Portfolio", systemImage: "briefcase.fill") }

            NavigationStack { HistoryView() }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .tint(.green)
        .task { await AppNotificationSetup.prepare() }
    }
}

private final class AppNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

private enum AppNotificationSetup {
    static func prepare() async {
        let center = UNUserNotificationCenter.current()
        await MainActor.run {
            center.delegate = AppNotificationPresenter.shared
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
}

private enum DashboardInterval: String, CaseIterable, Identifiable {
    case fiveMinute = "5m"
    case fifteenMinute = "15m"
    case thirtyMinute = "30m"
    case oneHour = "1h"
    case oneDay = "1d"

    var id: String { rawValue }

    var yahooInterval: String {
        switch self {
        case .fiveMinute: return "5m"
        case .fifteenMinute: return "15m"
        case .thirtyMinute: return "30m"
        case .oneHour: return "60m"
        case .oneDay: return "1d"
        }
    }

    var range: String {
        switch self {
        case .fiveMinute: return "5d"
        case .fifteenMinute, .thirtyMinute: return "1mo"
        case .oneHour: return "3mo"
        case .oneDay: return "1y"
        }
    }
}

private struct SignalVote: Identifiable {
    let id = UUID()
    let title: String
    let vote: String
    let points: Int
    let detail: String
}

private struct DashboardAnalysis {
    let score: Int
    let label: String
    let close: Double
    let support: Double?
    let resistance: Double?

    let rsi: Double?
    let macd: Double?
    let macdSignal: Double?
    let stochasticK: Double?
    let stochasticD: Double?
    let adx: Double?
    let plusDI: Double?
    let minusDI: Double?
    let atr: Double?
    let mfi: Double?
    let roc: Double?

    let votes: [SignalVote]

    let closeSeries: [Double]
    let ema9Series: [Double]
    let ema20Series: [Double]
    let ema50Series: [Double]
    let ema200Series: [Double]
    let vwapSeries: [Double]
    let bbUpperSeries: [Double]
    let bbLowerSeries: [Double]
    let rsiSeries: [Double]
    let macdSeries: [Double]
    let macdSignalSeries: [Double]
    let macdHistogramSeries: [Double]
    let stochasticKSeries: [Double]
    let stochasticDSeries: [Double]
    let adxSeries: [Double]
    let plusDISeries: [Double]
    let minusDISeries: [Double]
    let atrSeries: [Double]
    let obvSeries: [Double]
    let rocSeries: [Double]
    let mfiSeries: [Double]
    let volumeSeries: [Double]
}

struct SignalDashboardView: View {
    @EnvironmentObject private var market: MarketDataService

    @State private var symbol = "BTC-USD"
    @State private var interval: DashboardInterval = .fifteenMinute
    @State private var candles: [Candle] = []
    @State private var analysis: DashboardAnalysis?
    @State private var isLoading = false
    @State private var errorText: String?

    private var normalizedSymbol: String {
        symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls

                if isLoading && analysis == nil {
                    ProgressView("Loading market data…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if let analysis {
                    SignalGaugeView(score: analysis.score, label: analysis.label)
                        .frame(height: 250)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    quickStats(analysis)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Price")
                                .font(.title2.bold())
                            Spacer()
                            Text(priceText(analysis.close))
                                .font(.headline.monospacedDigit())
                        }

                        CandlestickChartView(candles: candles)
                            .frame(height: 260)

                        if let support = analysis.support, let resistance = analysis.resistance {
                            HStack {
                                Label("Support \(priceText(support))", systemImage: "arrow.down.to.line")
                                    .foregroundStyle(.green)
                                Spacer()
                                Label("Resistance \(priceText(resistance))", systemImage: "arrow.up.to.line")
                                    .foregroundStyle(.red)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    indicatorCharts(analysis)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("What is moving the needle")
                            .font(.title2.bold())

                        ForEach(analysis.votes) { vote in
                            HStack(alignment: .top, spacing: 10) {
                                Text(vote.vote)
                                    .font(.caption.bold())
                                    .foregroundStyle(voteColor(vote.vote))
                                    .frame(width: 52, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vote.title).font(.subheadline.bold())
                                    Text(vote.detail).font(.caption).foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(vote.points >= 0 ? "+\(vote.points)" : "\(vote.points)")
                                    .font(.caption.monospacedDigit().bold())
                                    .foregroundStyle(vote.points > 0 ? Color.green : (vote.points < 0 ? Color.red : Color.secondary))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    Text("The gauge combines technical indicators into one -100 to +100 research score. It is not a guaranteed prediction and does not replace the retest rules in the Retest tab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 24)
                }
            }
            .padding()
        }
        .navigationTitle("Signal Dashboard")
        .task {
            if analysis == nil {
                await refresh()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NEXER Signal Dashboard")
                .font(.largeTitle.bold())
            Text("Major indicators + one overall BUY / WAIT / SELL needle")
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("Yahoo symbol", text: $symbol)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { Task { await refresh() } }
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task { await refresh() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isLoading || normalizedSymbol.isEmpty)
            }

            Picker("Interval", selection: $interval) {
                ForEach(DashboardInterval.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: interval) { _, _ in
                Task { await refresh() }
            }

            HStack {
                Text("Examples: BTC-USD • NVDA • SPY • EURUSD=X")
                Spacer()
                Text("Yahoo data")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func quickStats(_ a: DashboardAnalysis) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, spacing: 10) {
            SignalStatCard(title: "RSI", value: number(a.rsi))
            SignalStatCard(title: "ADX", value: number(a.adx))
            SignalStatCard(title: "ATR", value: number(a.atr))
            SignalStatCard(title: "STOCH", value: number(a.stochasticK))
            SignalStatCard(title: "MFI", value: number(a.mfi))
            SignalStatCard(title: "ROC", value: a.roc.map { String(format: "%+.2f%%", $0) } ?? "—")
        }
    }

    @ViewBuilder
    private func indicatorCharts(_ a: DashboardAnalysis) -> some View {
        VStack(spacing: 14) {
            SignalLineChart(
                title: "Trend • Close / EMA 9 / EMA 20 / EMA 50 / EMA 200 / VWAP",
                series: [
                    .init(name: "Close", values: a.closeSeries, color: .white),
                    .init(name: "EMA9", values: a.ema9Series, color: .green),
                    .init(name: "EMA20", values: a.ema20Series, color: .cyan),
                    .init(name: "EMA50", values: a.ema50Series, color: .orange),
                    .init(name: "EMA200", values: a.ema200Series, color: .purple),
                    .init(name: "VWAP", values: a.vwapSeries, color: .yellow)
                ],
                guides: [],
                fixedRange: nil
            )

            SignalLineChart(
                title: "Bollinger Bands",
                series: [
                    .init(name: "Upper", values: a.bbUpperSeries, color: .orange),
                    .init(name: "Close", values: a.closeSeries, color: .white),
                    .init(name: "Lower", values: a.bbLowerSeries, color: .cyan)
                ],
                guides: [],
                fixedRange: nil
            )

            SignalLineChart(
                title: "RSI 14",
                series: [.init(name: "RSI", values: a.rsiSeries, color: .green)],
                guides: [30, 50, 70],
                fixedRange: 0...100
            )

            SignalLineChart(
                title: "MACD",
                series: [
                    .init(name: "MACD", values: a.macdSeries, color: .green),
                    .init(name: "Signal", values: a.macdSignalSeries, color: .orange),
                    .init(name: "Histogram", values: a.macdHistogramSeries, color: .secondary)
                ],
                guides: [0],
                fixedRange: nil
            )

            SignalLineChart(
                title: "Stochastic",
                series: [
                    .init(name: "%K", values: a.stochasticKSeries, color: .green),
                    .init(name: "%D", values: a.stochasticDSeries, color: .orange)
                ],
                guides: [20, 80],
                fixedRange: 0...100
            )

            SignalLineChart(
                title: "ADX / DMI",
                series: [
                    .init(name: "ADX", values: a.adxSeries, color: .white),
                    .init(name: "+DI", values: a.plusDISeries, color: .green),
                    .init(name: "-DI", values: a.minusDISeries, color: .red)
                ],
                guides: [20],
                fixedRange: 0...100
            )

            SignalLineChart(
                title: "ATR",
                series: [.init(name: "ATR", values: a.atrSeries, color: .orange)],
                guides: [],
                fixedRange: nil
            )

            SignalLineChart(
                title: "OBV",
                series: [.init(name: "OBV", values: a.obvSeries, color: .cyan)],
                guides: [],
                fixedRange: nil
            )

            SignalLineChart(
                title: "Rate of Change",
                series: [.init(name: "ROC %", values: a.rocSeries, color: .green)],
                guides: [0],
                fixedRange: nil
            )

            SignalLineChart(
                title: "Money Flow Index",
                series: [.init(name: "MFI", values: a.mfiSeries, color: .purple)],
                guides: [20, 50, 80],
                fixedRange: 0...100
            )

            SignalLineChart(
                title: "Volume",
                series: [.init(name: "Volume", values: a.volumeSeries, color: .green)],
                guides: [],
                fixedRange: nil
            )
        }
    }

    @MainActor
    private func refresh() async {
        let requested = normalizedSymbol
        guard !requested.isEmpty else { return }

        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let result = try await market.fetchCandles(
                symbol: requested,
                range: interval.range,
                interval: interval.yahooInterval,
                includePrePost: false
            )

            guard result.count >= 30 else {
                throw DashboardError.notEnoughData
            }

            candles = result
            analysis = DashboardMath.analyze(result)
            symbol = requested
        } catch {
            errorText = "Could not load \(requested): \(error.localizedDescription)"
        }
    }

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", value)
    }

    private func priceText(_ value: Double) -> String {
        if abs(value) >= 1000 { return String(format: "$%.2f", value) }
        if abs(value) >= 1 { return String(format: "$%.4f", value) }
        return String(format: "$%.6f", value)
    }

    private func voteColor(_ vote: String) -> Color {
        if vote == "BUY" { return .green }
        if vote == "SELL" { return .red }
        return .secondary
    }
}

private enum DashboardError: LocalizedError {
    case notEnoughData

    var errorDescription: String? {
        switch self {
        case .notEnoughData:
            return "Not enough candle history for the indicator dashboard."
        }
    }
}

private struct SignalStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct SignalGaugeView: View {
    let score: Int
    let label: String

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height * 0.82)
                    let radius = min(size.width * 0.42, size.height * 0.68)

                    let segments: [(Double, Double, Color)] = [
                        (-100, -60, .red.opacity(0.65)),
                        (-60, -25, .red.opacity(0.35)),
                        (-25, 25, .gray.opacity(0.45)),
                        (25, 60, .green.opacity(0.35)),
                        (60, 100, .green.opacity(0.80))
                    ]

                    for segment in segments {
                        var arc = Path()
                        arc.addArc(
                            center: center,
                            radius: radius,
                            startAngle: .degrees(angle(for: segment.0)),
                            endAngle: .degrees(angle(for: segment.1)),
                            clockwise: false
                        )
                        context.stroke(
                            arc,
                            with: .color(segment.2),
                            style: StrokeStyle(lineWidth: 24, lineCap: .butt)
                        )
                    }

                    let needleAngle = angle(for: Double(score)) * Double.pi / 180
                    let needleEnd = CGPoint(
                        x: center.x + CGFloat(cos(needleAngle)) * radius * 0.82,
                        y: center.y + CGFloat(sin(needleAngle)) * radius * 0.82
                    )

                    var needle = Path()
                    needle.move(to: center)
                    needle.addLine(to: needleEnd)
                    context.stroke(needle, with: .color(.white), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    context.fill(
                        Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
                        with: .color(.white)
                    )
                }

                VStack(spacing: 3) {
                    Spacer()
                    Text(label)
                        .font(.title2.bold())
                        .foregroundStyle(labelColor)
                    Text("\(score >= 0 ? "+" : "")\(score) / 100")
                        .font(.headline.monospacedDigit())
                    HStack {
                        Text("SELL").foregroundStyle(.red)
                        Spacer()
                        Text("WAIT").foregroundStyle(.secondary)
                        Spacer()
                        Text("BUY").foregroundStyle(.green)
                    }
                    .font(.caption.bold())
                }
            }
        }
    }

    private func angle(for value: Double) -> Double {
        let clamped = min(100, max(-100, value))
        return 180 + ((clamped + 100) / 200) * 180
    }

    private var labelColor: Color {
        if score >= 25 { return .green }
        if score <= -25 { return .red }
        return .secondary
    }
}

private struct SignalChartSeries {
    let name: String
    let values: [Double]
    let color: Color
}

private struct SignalLineChart: View {
    let title: String
    let series: [SignalChartSeries]
    let guides: [Double]
    let fixedRange: ClosedRange<Double>?

    private let maxPoints = 140

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            GeometryReader { geo in
                Canvas { context, size in
                    let trimmed = series.map { item in
                        SignalChartSeries(
                            name: item.name,
                            values: Array(item.values.suffix(maxPoints)),
                            color: item.color
                        )
                    }

                    let finiteValues = trimmed
                        .flatMap(\.values)
                        .filter(\.isFinite)

                    guard !finiteValues.isEmpty else { return }

                    var low = fixedRange?.lowerBound ?? finiteValues.min()!
                    var high = fixedRange?.upperBound ?? finiteValues.max()!

                    if high <= low {
                        high = low + 1
                    } else if fixedRange == nil {
                        let padding = (high - low) * 0.08
                        low -= padding
                        high += padding
                    }

                    func y(_ value: Double) -> CGFloat {
                        size.height - CGFloat((value - low) / (high - low)) * size.height
                    }

                    for guide in guides where guide >= low && guide <= high {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y(guide)))
                        path.addLine(to: CGPoint(x: size.width, y: y(guide)))
                        context.stroke(
                            path,
                            with: .color(Color.secondary.opacity(0.25)),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                        )
                    }

                    for item in trimmed {
                        let count = item.values.count
                        guard count > 1 else { continue }

                        var path = Path()
                        var drawing = false

                        for (index, value) in item.values.enumerated() {
                            guard value.isFinite else {
                                drawing = false
                                continue
                            }

                            let x = CGFloat(index) / CGFloat(max(count - 1, 1)) * size.width
                            let point = CGPoint(x: x, y: y(value))

                            if drawing {
                                path.addLine(to: point)
                            } else {
                                path.move(to: point)
                                drawing = true
                            }
                        }

                        context.stroke(
                            path,
                            with: .color(item.color),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )
                    }
                }
            }
            .frame(height: 160)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                ForEach(Array(series.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Circle().fill(item.color).frame(width: 7, height: 7)
                        Text(item.name)
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private enum DashboardMath {
    static func analyze(_ candles: [Candle]) -> DashboardAnalysis {
        let closes = candles.map(\.close)
        let highs = candles.map(\.high)
        let lows = candles.map(\.low)
        let volumes = candles.map(\.volume)

        let ema9 = ema(closes, period: 9)
        let ema20 = ema(closes, period: 20)
        let ema50 = ema(closes, period: 50)
        let ema200 = ema(closes, period: 200)

        let rsi14 = rsiSeries(closes, period: 14)
        let macdPack = macd(closes)
        let stoch = stochastic(highs: highs, lows: lows, closes: closes, period: 14, smooth: 3)
        let atr14 = atrSeries(candles, period: 14)
        let dmi = adxSeries(candles, period: 14)
        let obv = obvSeries(closes: closes, volumes: volumes)
        let roc = rocSeries(closes, lookback: 10)
        let mfi = mfiSeries(candles, period: 14)
        let vwap = vwapSeries(candles)
        let bands = bollinger(closes, period: 20, deviations: 2)

        let lastIndex = closes.count - 1
        let previousIndex = max(0, lastIndex - 1)

        func latest(_ values: [Double]) -> Double? {
            guard let value = values.last, value.isFinite else { return nil }
            return value
        }

        func previous(_ values: [Double]) -> Double? {
            guard previousIndex < values.count else { return nil }
            let value = values[previousIndex]
            return value.isFinite ? value : nil
        }

        var score = 0
        var votes: [SignalVote] = []

        func addVote(
            title: String,
            bullish: Bool,
            bearish: Bool,
            weight: Int,
            bullDetail: String,
            bearDetail: String
        ) {
            if bullish {
                score += weight
                votes.append(.init(title: title, vote: "BUY", points: weight, detail: bullDetail))
            } else if bearish {
                score -= weight
                votes.append(.init(title: title, vote: "SELL", points: -weight, detail: bearDetail))
            } else {
                votes.append(.init(title: title, vote: "WAIT", points: 0, detail: "Neutral / mixed"))
            }
        }

        let close = closes[lastIndex]
        let e9 = latest(ema9)
        let e20 = latest(ema20)
        let e50 = latest(ema50)
        let e200 = latest(ema200)
        let lastVWAP = latest(vwap)

        addVote(
            title: "EMA trend",
            bullish: e9 != nil && e20 != nil && e50 != nil && e9! > e20! && e20! > e50!,
            bearish: e9 != nil && e20 != nil && e50 != nil && e9! < e20! && e20! < e50!,
            weight: 18,
            bullDetail: "EMA 9 > EMA 20 > EMA 50",
            bearDetail: "EMA 9 < EMA 20 < EMA 50"
        )

        addVote(
            title: "Price vs EMA 200",
            bullish: e200 != nil && close > e200!,
            bearish: e200 != nil && close < e200!,
            weight: 10,
            bullDetail: "Price is above EMA 200",
            bearDetail: "Price is below EMA 200"
        )

        addVote(
            title: "VWAP",
            bullish: lastVWAP != nil && close > lastVWAP!,
            bearish: lastVWAP != nil && close < lastVWAP!,
            weight: 12,
            bullDetail: "Price is above VWAP",
            bearDetail: "Price is below VWAP"
        )

        let rsiNow = latest(rsi14)
        let rsiPrevious = previous(rsi14)
        addVote(
            title: "RSI",
            bullish: rsiNow != nil && rsiPrevious != nil && rsiNow! >= 50 && rsiNow! <= 70 && rsiNow! >= rsiPrevious!,
            bearish: rsiNow != nil && rsiPrevious != nil && rsiNow! >= 30 && rsiNow! < 50 && rsiNow! <= rsiPrevious!,
            weight: 10,
            bullDetail: "RSI is bullish and rising",
            bearDetail: "RSI is bearish and falling"
        )

        let macdNow = latest(macdPack.line)
        let macdSignalNow = latest(macdPack.signal)
        let macdHistNow = latest(macdPack.histogram)
        addVote(
            title: "MACD",
            bullish: macdNow != nil && macdSignalNow != nil && macdHistNow != nil && macdNow! > macdSignalNow! && macdHistNow! > 0,
            bearish: macdNow != nil && macdSignalNow != nil && macdHistNow != nil && macdNow! < macdSignalNow! && macdHistNow! < 0,
            weight: 14,
            bullDetail: "MACD is above signal with positive histogram",
            bearDetail: "MACD is below signal with negative histogram"
        )

        let kNow = latest(stoch.k)
        let dNow = latest(stoch.d)
        addVote(
            title: "Stochastic",
            bullish: kNow != nil && dNow != nil && kNow! > dNow! && kNow! < 80,
            bearish: kNow != nil && dNow != nil && kNow! < dNow! && kNow! > 20,
            weight: 8,
            bullDetail: "%K is above %D without being overbought",
            bearDetail: "%K is below %D without being oversold"
        )

        let adxNow = latest(dmi.adx)
        let plusNow = latest(dmi.plusDI)
        let minusNow = latest(dmi.minusDI)
        addVote(
            title: "ADX / DMI",
            bullish: adxNow != nil && plusNow != nil && minusNow != nil && adxNow! >= 18 && plusNow! > minusNow!,
            bearish: adxNow != nil && plusNow != nil && minusNow != nil && adxNow! >= 18 && minusNow! > plusNow!,
            weight: 12,
            bullDetail: "+DI is leading with usable trend strength",
            bearDetail: "-DI is leading with usable trend strength"
        )

        let rocNow = latest(roc)
        addVote(
            title: "Momentum ROC",
            bullish: rocNow != nil && rocNow! > 0,
            bearish: rocNow != nil && rocNow! < 0,
            weight: 7,
            bullDetail: "10-bar rate of change is positive",
            bearDetail: "10-bar rate of change is negative"
        )

        let recentOBV = Array(obv.suffix(10)).filter(\.isFinite)
        let obvBull = recentOBV.count >= 2 && recentOBV.last! > recentOBV.first!
        let obvBear = recentOBV.count >= 2 && recentOBV.last! < recentOBV.first!
        addVote(
            title: "OBV",
            bullish: obvBull,
            bearish: obvBear,
            weight: 5,
            bullDetail: "On-balance volume is trending up",
            bearDetail: "On-balance volume is trending down"
        )

        let mfiNow = latest(mfi)
        addVote(
            title: "MFI",
            bullish: mfiNow != nil && mfiNow! >= 50 && mfiNow! < 80,
            bearish: mfiNow != nil && mfiNow! > 20 && mfiNow! < 50,
            weight: 4,
            bullDetail: "Money flow is positive",
            bearDetail: "Money flow is negative"
        )

        score = min(100, max(-100, score))

        let label: String
        if score >= 60 {
            label = "STRONG BUY"
        } else if score >= 25 {
            label = "BUY"
        } else if score > -25 {
            label = "WAIT"
        } else if score > -60 {
            label = "SELL"
        } else {
            label = "STRONG SELL"
        }

        return DashboardAnalysis(
            score: score,
            label: label,
            close: close,
            support: Array(lows.suffix(20)).min(),
            resistance: Array(highs.suffix(20)).max(),
            rsi: rsiNow,
            macd: macdNow,
            macdSignal: macdSignalNow,
            stochasticK: kNow,
            stochasticD: dNow,
            adx: adxNow,
            plusDI: plusNow,
            minusDI: minusNow,
            atr: latest(atr14),
            mfi: mfiNow,
            roc: rocNow,
            votes: votes,
            closeSeries: closes,
            ema9Series: ema9,
            ema20Series: ema20,
            ema50Series: ema50,
            ema200Series: ema200,
            vwapSeries: vwap,
            bbUpperSeries: bands.upper,
            bbLowerSeries: bands.lower,
            rsiSeries: rsi14,
            macdSeries: macdPack.line,
            macdSignalSeries: macdPack.signal,
            macdHistogramSeries: macdPack.histogram,
            stochasticKSeries: stoch.k,
            stochasticDSeries: stoch.d,
            adxSeries: dmi.adx,
            plusDISeries: dmi.plusDI,
            minusDISeries: dmi.minusDI,
            atrSeries: atr14,
            obvSeries: obv,
            rocSeries: roc,
            mfiSeries: mfi,
            volumeSeries: volumes
        )
    }

    private static func ema(_ values: [Double], period: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        let alpha = 2.0 / (Double(period) + 1.0)
        var output = Array(repeating: Double.nan, count: values.count)
        var current = values[0]
        output[0] = current

        for index in 1..<values.count {
            current = values[index] * alpha + current * (1 - alpha)
            output[index] = current
        }

        return output
    }

    private static func smaSeries(_ values: [Double], period: Int) -> [Double] {
        guard period > 0 else { return Array(repeating: .nan, count: values.count) }
        var output = Array(repeating: Double.nan, count: values.count)
        var sum = 0.0

        for index in values.indices {
            sum += values[index]
            if index >= period {
                sum -= values[index - period]
            }
            if index >= period - 1 {
                output[index] = sum / Double(period)
            }
        }

        return output
    }

    private static func rsiSeries(_ values: [Double], period: Int) -> [Double] {
        guard values.count > period else { return Array(repeating: .nan, count: values.count) }

        var output = Array(repeating: Double.nan, count: values.count)
        var avgGain = 0.0
        var avgLoss = 0.0

        for index in 1...period {
            let change = values[index] - values[index - 1]
            avgGain += max(change, 0)
            avgLoss += max(-change, 0)
        }

        avgGain /= Double(period)
        avgLoss /= Double(period)

        output[period] = rsiValue(gain: avgGain, loss: avgLoss)

        guard values.count > period + 1 else { return output }

        for index in (period + 1)..<values.count {
            let change = values[index] - values[index - 1]
            let gain = max(change, 0)
            let loss = max(-change, 0)
            avgGain = ((avgGain * Double(period - 1)) + gain) / Double(period)
            avgLoss = ((avgLoss * Double(period - 1)) + loss) / Double(period)
            output[index] = rsiValue(gain: avgGain, loss: avgLoss)
        }

        return output
    }

    private static func rsiValue(gain: Double, loss: Double) -> Double {
        if loss == 0 { return 100 }
        let rs = gain / loss
        return 100 - (100 / (1 + rs))
    }

    private static func macd(_ values: [Double]) -> (line: [Double], signal: [Double], histogram: [Double]) {
        let fast = ema(values, period: 12)
        let slow = ema(values, period: 26)
        let line = zip(fast, slow).map { $0.0 - $0.1 }
        let signal = ema(line, period: 9)
        let histogram = zip(line, signal).map { $0.0 - $0.1 }
        return (line, signal, histogram)
    }

    private static func stochastic(
        highs: [Double],
        lows: [Double],
        closes: [Double],
        period: Int,
        smooth: Int
    ) -> (k: [Double], d: [Double]) {
        var k = Array(repeating: Double.nan, count: closes.count)

        guard closes.count >= period else {
            return (k, Array(repeating: Double.nan, count: closes.count))
        }

        for index in (period - 1)..<closes.count {
            let low = lows[(index - period + 1)...index].min() ?? closes[index]
            let high = highs[(index - period + 1)...index].max() ?? closes[index]
            if high != low {
                k[index] = 100 * (closes[index] - low) / (high - low)
            }
        }

        var d = Array(repeating: Double.nan, count: closes.count)
        if smooth > 0 {
            for index in k.indices where index >= smooth - 1 {
                let window = Array(k[(index - smooth + 1)...index]).filter(\.isFinite)
                if window.count == smooth {
                    d[index] = window.reduce(0, +) / Double(smooth)
                }
            }
        }

        return (k, d)
    }

    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double] {
        guard !candles.isEmpty else { return [] }
        var trueRanges = Array(repeating: 0.0, count: candles.count)

        for index in candles.indices {
            if index == 0 {
                trueRanges[index] = candles[index].high - candles[index].low
            } else {
                let previousClose = candles[index - 1].close
                trueRanges[index] = max(
                    candles[index].high - candles[index].low,
                    max(abs(candles[index].high - previousClose), abs(candles[index].low - previousClose))
                )
            }
        }

        return wilderAverage(trueRanges, period: period)
    }

    private static func adxSeries(_ candles: [Candle], period: Int) -> (adx: [Double], plusDI: [Double], minusDI: [Double]) {
        guard !candles.isEmpty else { return ([], [], []) }

        var trueRanges = Array(repeating: 0.0, count: candles.count)
        var plusDM = Array(repeating: 0.0, count: candles.count)
        var minusDM = Array(repeating: 0.0, count: candles.count)

        for index in candles.indices {
            if index == 0 {
                trueRanges[index] = candles[index].high - candles[index].low
                continue
            }

            let upMove = candles[index].high - candles[index - 1].high
            let downMove = candles[index - 1].low - candles[index].low

            plusDM[index] = (upMove > downMove && upMove > 0) ? upMove : 0
            minusDM[index] = (downMove > upMove && downMove > 0) ? downMove : 0

            let previousClose = candles[index - 1].close
            trueRanges[index] = max(
                candles[index].high - candles[index].low,
                max(abs(candles[index].high - previousClose), abs(candles[index].low - previousClose))
            )
        }

        let atr = wilderAverage(trueRanges, period: period)
        let smoothPlus = wilderAverage(plusDM, period: period)
        let smoothMinus = wilderAverage(minusDM, period: period)

        var plusDI = Array(repeating: Double.nan, count: candles.count)
        var minusDI = Array(repeating: Double.nan, count: candles.count)
        var dx = Array(repeating: Double.nan, count: candles.count)

        for index in candles.indices {
            guard atr[index].isFinite, atr[index] > 0 else { continue }

            plusDI[index] = 100 * smoothPlus[index] / atr[index]
            minusDI[index] = 100 * smoothMinus[index] / atr[index]

            let sum = plusDI[index] + minusDI[index]
            if sum > 0 {
                dx[index] = 100 * abs(plusDI[index] - minusDI[index]) / sum
            }
        }

        let adx = wilderAverageIgnoringNaN(dx, period: period)
        return (adx, plusDI, minusDI)
    }

    private static func wilderAverage(_ values: [Double], period: Int) -> [Double] {
        var output = Array(repeating: Double.nan, count: values.count)
        guard values.count >= period, period > 0 else { return output }

        var average = values.prefix(period).reduce(0, +) / Double(period)
        output[period - 1] = average

        if values.count > period {
            for index in period..<values.count {
                average = ((average * Double(period - 1)) + values[index]) / Double(period)
                output[index] = average
            }
        }

        return output
    }

    private static func wilderAverageIgnoringNaN(_ values: [Double], period: Int) -> [Double] {
        var output = Array(repeating: Double.nan, count: values.count)
        var buffer: [Double] = []
        var average: Double?

        for index in values.indices {
            let value = values[index]
            guard value.isFinite else { continue }

            if average == nil {
                buffer.append(value)
                if buffer.count == period {
                    let initial = buffer.reduce(0, +) / Double(period)
                    average = initial
                    output[index] = initial
                }
            } else if let current = average {
                let next = ((current * Double(period - 1)) + value) / Double(period)
                average = next
                output[index] = next
            }
        }

        return output
    }

    private static func obvSeries(closes: [Double], volumes: [Double]) -> [Double] {
        guard !closes.isEmpty else { return [] }
        var output = Array(repeating: 0.0, count: closes.count)

        for index in 1..<closes.count {
            if closes[index] > closes[index - 1] {
                output[index] = output[index - 1] + volumes[index]
            } else if closes[index] < closes[index - 1] {
                output[index] = output[index - 1] - volumes[index]
            } else {
                output[index] = output[index - 1]
            }
        }

        return output
    }

    private static func rocSeries(_ closes: [Double], lookback: Int) -> [Double] {
        var output = Array(repeating: Double.nan, count: closes.count)
        guard closes.count > lookback else { return output }

        for index in lookback..<closes.count {
            let old = closes[index - lookback]
            if old != 0 {
                output[index] = (closes[index] - old) / old * 100
            }
        }

        return output
    }

    private static func mfiSeries(_ candles: [Candle], period: Int) -> [Double] {
        var output = Array(repeating: Double.nan, count: candles.count)
        guard candles.count > period else { return output }

        let typical = candles.map { ($0.high + $0.low + $0.close) / 3 }
        let rawFlow = zip(typical, candles.map(\.volume)).map { $0.0 * $0.1 }

        var positive = Array(repeating: 0.0, count: candles.count)
        var negative = Array(repeating: 0.0, count: candles.count)

        for index in 1..<candles.count {
            if typical[index] > typical[index - 1] {
                positive[index] = rawFlow[index]
            } else if typical[index] < typical[index - 1] {
                negative[index] = rawFlow[index]
            }
        }

        for index in period..<candles.count {
            let start = index - period + 1
            let positiveSum = positive[start...index].reduce(0, +)
            let negativeSum = negative[start...index].reduce(0, +)

            if negativeSum == 0 {
                output[index] = 100
            } else {
                let ratio = positiveSum / negativeSum
                output[index] = 100 - (100 / (1 + ratio))
            }
        }

        return output
    }

    private static func vwapSeries(_ candles: [Candle]) -> [Double] {
        guard !candles.isEmpty else { return [] }

        let calendar = Calendar.current
        var output = Array(repeating: Double.nan, count: candles.count)
        var currentDay: DateComponents?
        var cumulativePV = 0.0
        var cumulativeVolume = 0.0

        for index in candles.indices {
            let components = calendar.dateComponents([.year, .month, .day], from: candles[index].date)

            if currentDay != components {
                currentDay = components
                cumulativePV = 0
                cumulativeVolume = 0
            }

            let typical = (candles[index].high + candles[index].low + candles[index].close) / 3
            let volume = max(candles[index].volume, 0)
            cumulativePV += typical * volume
            cumulativeVolume += volume

            if cumulativeVolume > 0 {
                output[index] = cumulativePV / cumulativeVolume
            }
        }

        return output
    }

    private static func bollinger(
        _ closes: [Double],
        period: Int,
        deviations: Double
    ) -> (upper: [Double], lower: [Double]) {
        let sma = smaSeries(closes, period: period)
        var upper = Array(repeating: Double.nan, count: closes.count)
        var lower = Array(repeating: Double.nan, count: closes.count)

        guard closes.count >= period else { return (upper, lower) }

        for index in (period - 1)..<closes.count {
            let start = index - period + 1
            let window = Array(closes[start...index])
            let mean = sma[index]
            let variance = window.reduce(0) { $0 + pow($1 - mean, 2) } / Double(period)
            let standardDeviation = sqrt(variance)
            upper[index] = mean + deviations * standardDeviation
            lower[index] = mean - deviations * standardDeviation
        }

        return (upper, lower)
    }
}
