import SwiftUI

// MARK: - Sparkline
//
// Tiny pure-Path line chart for dashboard widgets and heroes — deliberately not Swift Charts.
// Values are normalized into the view's bounds over their min…max range; a flat series draws a
// centered horizontal line. Lines are 2pt with round caps, smoothed with quad curves when the
// theme asks for smooth chart lines, and optionally filled to the baseline with a vertical
// fade of the tint.

struct Sparkline: View {
    private let values: [Double]
    private let tint: Color?
    private let fillGradient: Bool

    @Environment(\.theme) private var theme

    init(values: [Double], tint: Color? = nil, fillGradient: Bool = true) {
        self.values = values
        self.tint = tint
        self.fillGradient = fillGradient
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let points = normalizedPoints(in: size)
            if points.count > 1 {
                let lineColor = tint ?? theme.palette.accent
                ZStack {
                    if fillGradient {
                        areaPath(points: points, in: size)
                            .fill(LinearGradient(
                                colors: [lineColor.opacity(0.35), lineColor.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom))
                    }
                    linePath(points: points)
                        .stroke(lineColor,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Geometry

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        let series = values.filter { $0.isFinite }
        guard series.count > 1, size.width > 0, size.height > 0 else { return [] }
        let minValue = series.min() ?? 0
        let maxValue = series.max() ?? 0
        let range = maxValue - minValue
        let inset: CGFloat = 2 // keep round caps inside the bounds
        let drawableHeight = max(size.height - inset * 2, 1)
        let stepX = size.width / CGFloat(series.count - 1)
        return series.enumerated().map { index, value in
            let normalized = range > 0 ? (value - minValue) / range : 0.5
            return CGPoint(x: CGFloat(index) * stepX,
                           y: inset + drawableHeight * CGFloat(1 - normalized))
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        if theme.chart.smoothLines, points.count > 2 {
            // Midpoint quad-curve smoothing: curve to each segment midpoint using the previous
            // sample as control, then finish with a straight run into the final sample.
            for index in 1..<points.count {
                let previous = points[index - 1]
                let current = points[index]
                let midpoint = CGPoint(x: (previous.x + current.x) / 2,
                                       y: (previous.y + current.y) / 2)
                path.addQuadCurve(to: midpoint, control: previous)
            }
            path.addLine(to: last)
        } else {
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func areaPath(points: [CGPoint], in size: CGSize) -> Path {
        var path = linePath(points: points)
        guard let first = points.first, let last = points.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }
}
