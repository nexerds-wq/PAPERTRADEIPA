import SwiftUI

struct CandlestickChartView: View {
    let candles: [Candle]
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard !candles.isEmpty else { return }
                let visible = Array(candles.suffix(60))
                guard let minV = visible.map(\.low).min(), let maxV = visible.map(\.high).max(), maxV > minV else { return }
                let step = size.width / CGFloat(visible.count)
                func y(_ value: Double) -> CGFloat { size.height - CGFloat((value - minV) / (maxV - minV)) * size.height }
                for (i,c) in visible.enumerated() {
                    let x = CGFloat(i) * step + step/2
                    let up = c.close >= c.open
                    let color = up ? Color.green : Color.red
                    var wick = Path(); wick.move(to: CGPoint(x: x, y: y(c.high))); wick.addLine(to: CGPoint(x: x, y: y(c.low)))
                    ctx.stroke(wick, with: .color(color.opacity(0.8)), lineWidth: 1)
                    let top = min(y(c.open), y(c.close)); let bottom = max(y(c.open), y(c.close))
                    let rect = CGRect(x: x-step*0.32, y: top, width: step*0.64, height: max(bottom-top, 1.5))
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
