import SwiftUI

// MARK: - ProgressRing
//
// Circular progress with round caps. The track sits at 15% opacity of the tint; the default
// tint is an angular gradient sweeping accent → accentSecondary → accent so the seam at 12
// o'clock is invisible. Progress beyond 1.0 draws a second, slimmer "overflow" lap in the
// palette's negative color (over-budget states). Changes animate with the theme spring, and
// themes that glow get a soft halo behind the arc.

struct ProgressRing: View {
    private let progress: Double
    private let lineWidth: CGFloat
    private let tint: Color?
    private let showsOverflow: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(progress: Double, lineWidth: CGFloat = 8, tint: Color? = nil, showsOverflow: Bool = true) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.tint = tint
        self.showsOverflow = showsOverflow
    }

    private var safeProgress: Double { progress.isFinite ? progress : 0 }
    private var mainFraction: Double { min(max(safeProgress, 0), 1) }
    private var overflowFraction: Double {
        showsOverflow ? min(max(safeProgress - 1, 0), 1) : 0
    }

    var body: some View {
        let ringTint = tint ?? theme.palette.accent
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        ZStack {
            Circle()
                .stroke(ringTint.opacity(0.15), style: stroke)
            Circle()
                .trim(from: 0, to: CGFloat(mainFraction))
                .stroke(arcStyle, style: stroke)
                .rotationEffect(.degrees(-90))
                .shadow(color: theme.effects.glowAccents ? ringTint.opacity(0.55) : .clear,
                        radius: theme.effects.glowAccents ? 6 : 0)
            if overflowFraction > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(overflowFraction))
                    .stroke(theme.palette.negative,
                            style: StrokeStyle(lineWidth: lineWidth * 0.72, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .aspectRatio(1, contentMode: .fit)
        .animation(reduceMotion ? nil : theme.motion.spring, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(Text(mainFraction.formatted(.percent.precision(.fractionLength(0)))))
    }

    private var arcStyle: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(AngularGradient(
            colors: [theme.palette.accent, theme.palette.accentSecondary, theme.palette.accent],
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(360)))
    }
}
