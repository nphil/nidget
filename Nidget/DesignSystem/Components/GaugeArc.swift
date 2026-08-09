import SwiftUI

// MARK: - GaugeArc
//
// A 270° gauge for savings rate / FI progress. The arc is a circle trimmed to 0…0.75 and
// rotated 135° so the opening faces straight down; the fill sweeps the theme's accent gradient.
// The centered label uses the display font (with numeric content transitions so live "what if"
// sliders tick smoothly) with an optional caption beneath it.

struct GaugeArc: View {
    private let progress: Double
    private let label: String
    private let detail: String?

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let lineWidth: CGFloat = 14

    init(progress: Double, label: String, detail: String? = nil) {
        self.progress = progress
        self.label = label
        self.detail = detail
    }

    private var fraction: Double {
        let safe = progress.isFinite ? progress : 0
        return min(max(safe, 0), 1)
    }

    var body: some View {
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(theme.palette.accent.opacity(0.15), style: stroke)
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: 0, to: 0.75 * CGFloat(fraction))
                .stroke(theme.accentGradient, style: stroke)
                .rotationEffect(.degrees(135))
                .shadow(color: theme.effects.glowAccents ? theme.palette.accent.opacity(0.5) : .clear,
                        radius: theme.effects.glowAccents ? 8 : 0)
            VStack(spacing: 2) {
                Text(label)
                    .font(theme.font(.display))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.spring, value: label)
                if let detail {
                    Text(detail)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, lineWidth + 8)
        }
        .padding(lineWidth / 2)
        .aspectRatio(1, contentMode: .fit)
        .animation(reduceMotion ? nil : theme.motion.spring, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(detail.map { "\(label), \($0)" } ?? label))
        .accessibilityValue(Text(fraction.formatted(.percent.precision(.fractionLength(0)))))
    }
}
