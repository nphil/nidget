import SwiftUI
import Charts

// MARK: - RetirementChartCard
//
// The personal projection chart, framed around AGE (x axis is age in years, not calendar year)
// so the question "when can I stop?" reads straight off the picture:
//
// - single accent area + line for the deterministic path (Simple mode, the default; the owner
//   found the Monte Carlo bands confusing);
// - Detailed mode layers the p10-p90 and p25-p75 bands back in plus a success-probability row;
// - a dashed "Enough to retire" line with a chip label and a dot where the path crosses it;
// - a soft background tint after the planned retirement age (the withdrawal phase);
// - drag to scrub via the shared ChartScrubCallout: age, projected value, and what that value
//   safely provides per month (value x withdrawal rate / 12), all via AmountText so privacy
//   mode holds.
//
// The y domain is the same in both modes (the padded max always includes the bands), so the
// Simple/Detailed toggle never rescales the path; only the band opacity animates.

struct RetirementChartCard: View {
    let snapshot: RetirementSnapshot
    let config: RetirementConfig
    let isRecomputing: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.privacyMode) private var privacyMode

    @State private var mode: Mode = .simple
    @State private var selectedAge: Double?

    private enum Mode: String, CaseIterable, Hashable {
        case simple, detailed

        var label: String {
            switch self {
            case .simple: return "Simple"
            case .detailed: return "Detailed"
            }
        }
    }

    /// One vertical slice of a Monte Carlo percentile band, keyed by age. `low` is clamped to
    /// zero at construction; the chart never draws negative wealth.
    private struct BandSlice: Identifiable {
        var age: Double
        var low: Double
        var high: Double
        var id: Double { age }
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            if isRecomputing {
                SectionHeader("Your Path", trailing: {
                    AnyView(ProgressView()
                        .controlSize(.small)
                        .tint(theme.palette.accent))
                })
            } else {
                SectionHeader("Your Path")
            }
            ChipPicker(items: Mode.allCases, selection: $mode, label: { $0.label })
            if snapshot.deterministic.count > 1 {
                chart
                if mode == .detailed {
                    successRow
                }
                Text(caption)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not enough years between now and the end of your plan to draw a path. Check the ages in your assumptions.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .themedCard()
        .onChange(of: mode) { _, _ in
            // A stale selection would resolve the callout against the other mode's marks.
            selectedAge = nil
        }
        .onChange(of: selectedAge) { oldValue, newValue in
            if oldValue == nil, newValue != nil { Haptics.tick() }
        }
    }

    // MARK: Chart

    private var chart: some View {
        let points = snapshot.deterministic
        let minAge = points.first?.age ?? 0
        let maxAge = points.last?.age ?? 1
        let outer = Self.bandSlices(points: points,
                                    low: snapshot.percentileBands.p10,
                                    high: snapshot.percentileBands.p90)
        let inner = Self.bandSlices(points: points,
                                    low: snapshot.percentileBands.p25,
                                    high: snapshot.percentileBands.p75)
        let lineMax = points.map { $0.value.doubleValue }.max() ?? 0
        // Constant across modes: the bands count toward the max even in Simple, so the
        // Simple/Detailed toggle rescales nothing at all.
        let dataMax = max(lineMax, outer.map(\.high).max() ?? 0)
        let fiValue = snapshot.fiNumber.doubleValue
        // A degenerate FI number (e.g. a 0% withdrawal rate caps it at $10T) would flatten the
        // chart if the y-scale stretched to include it; only draw the line when it's in the
        // same neighborhood as the data.
        let fiVisible = fiValue > 0 && fiValue <= max(dataMax, 1) * 2
        // 1.15 headroom guarantees room for the FI chip at large Dynamic Type.
        let yMax = max(max(dataMax, fiVisible ? fiValue : 0) * 1.15, 1)
        let retireStart = Double(config.retireAge)
        let interpolation: InterpolationMethod = theme.chart.smoothLines ? .catmullRom : .linear
        let nearest = nearestPoint

        return Chart {
            if retireStart < maxAge {
                RectangleMark(xStart: .value("Age", max(retireStart, minAge)),
                              xEnd: .value("Age", maxAge))
                    .foregroundStyle(theme.palette.fill)
            }
            ForEach(outer) { slice in
                AreaMark(x: .value("Age", slice.age),
                         yStart: .value("10th percentile", slice.low),
                         yEnd: .value("90th percentile", slice.high))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent.opacity(0.10))
                    .opacity(mode == .detailed ? 1 : 0)
            }
            ForEach(inner) { slice in
                AreaMark(x: .value("Age", slice.age),
                         yStart: .value("25th percentile", slice.low),
                         yEnd: .value("75th percentile", slice.high))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent.opacity(0.18))
                    .opacity(mode == .detailed ? 1 : 0)
            }
            if theme.chart.filledAreas {
                ForEach(points) { point in
                    AreaMark(x: .value("Age", point.age),
                             y: .value("Projected", point.value.doubleValue))
                        .interpolationMethod(interpolation)
                        .foregroundStyle(areaGradient)
                        .opacity(mode == .simple ? 1 : 0)
                }
            }
            ForEach(points) { point in
                LineMark(x: .value("Age", point.age),
                         y: .value("Projected", point.value.doubleValue))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(theme.palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if fiVisible {
                RuleMark(y: .value("Enough to retire", fiValue))
                    .foregroundStyle(theme.palette.positive)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .annotation(position: .topLeading, alignment: .leading, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .plot),
                                                          y: .fit(to: .plot))) {
                        // The chip hides while a scrub is active so it can never collide with
                        // the callout; fit-to-plot alone is not trusted near the plot edges.
                        if nearest == nil {
                            fiChip
                        }
                    }
            }
            if let nearest {
                ChartScrubCallout(theme: theme, x: nearest.age,
                                  title: "Age \(clampedAge(nearest.age))",
                                  lines: calloutLines(nearest))
                PointMark(x: .value("Age", nearest.age),
                          y: .value("Projected", nearest.value.doubleValue))
                    .foregroundStyle(theme.palette.accent)
                    .symbolSize(90)
            } else if fiVisible, let projected = snapshot.projectedRetireAge, projected > minAge {
                PointMark(x: .value("Age", projected),
                          y: .value("Enough to retire", fiValue))
                    .foregroundStyle(theme.palette.positive)
                    .symbolSize(90)
                    .annotation(position: .bottom, alignment: .center, spacing: 4) {
                        Text("~\(clampedAge(projected))")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
            }
        }
        .chartXScale(domain: minAge...maxAge)
        .chartYScale(domain: 0...yMax)
        .chartXSelection(value: $selectedAge)
        .chartXAxis {
            AxisMarks(values: roundAgeTicks(min: minAge, max: maxAge)) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let age = value.as(Double.self) {
                        Text(String(clampedAge(age)))
                    }
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(Self.compactMoney(dollars))
                    }
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .frame(height: 240)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
    }

    private var fiChip: some View {
        Text("Enough to retire")
            .font(theme.font(.caption))
            .foregroundStyle(theme.palette.positive)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background { theme.controlShape.fill(theme.palette.surfaceElevated) }
    }

    private var areaGradient: LinearGradient {
        LinearGradient(colors: [theme.palette.accent.opacity(0.35), theme.palette.accent.opacity(0.02)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: Scrub callout

    private var nearestPoint: YearPoint? {
        guard let selectedAge else { return nil }
        return snapshot.deterministic.min {
            abs($0.age - selectedAge) < abs($1.age - selectedAge)
        }
    }

    private func calloutLines(_ point: YearPoint) -> [ChartCalloutLine] {
        let monthly = point.value * (config.withdrawalRatePct / 100.0 / 12.0)
        return [ChartCalloutLine(point.value),
                ChartCalloutLine(monthly, caption: "a month")]
    }

    // MARK: Success row (Detailed only)

    /// True when the plotted p10 edge reaches zero after the starting point: in at least a tenth
    /// of the simulated futures the money ran out. The success row says so, because that flat
    /// bottom edge is an honest floor, not a rendering artifact. The first sample is skipped
    /// because starting from nothing is not a failed future.
    private var p10WasClamped: Bool {
        let count = min(snapshot.deterministic.count, snapshot.percentileBands.p10.count)
        guard count > 1 else { return false }
        return snapshot.successProbability < 1
            && snapshot.percentileBands.p10.prefix(count).dropFirst().contains { $0.cents <= 0 }
    }

    private var successRow: some View {
        let probability = snapshot.successProbability
        let percentText = probability.formatted(.percent.precision(.fractionLength(0)))
        return VStack(alignment: .leading, spacing: 2) {
            if p10WasClamped {
                Text("Some futures run out early. That is what the number below counts.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Chance your money lasts")
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: theme.layout.spacing)
                Text(percentText)
                    .font(theme.font(.headline))
                    .foregroundStyle(successColor(probability))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: percentText)
            }
            Text(successInterpretation(probability))
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func successColor(_ probability: Double) -> Color {
        if probability >= 0.85 { return theme.palette.positive }
        if probability >= 0.60 { return theme.palette.warning }
        return theme.palette.negative
    }

    private func successInterpretation(_ probability: Double) -> String {
        if probability >= 0.85 {
            return "Your money outlives you in nearly every simulated future."
        }
        if probability >= 0.60 {
            return "Decent odds, but a rough market decade could knock this plan off course."
        }
        return "Most simulated futures run dry. More savings or a later date would help."
    }

    // MARK: Caption

    private var caption: String {
        var text: String
        if let projected = snapshot.projectedRetireAge {
            text = "Steady growth reaches enough to retire around age \(clampedAge(projected)). Drag on the chart to look around."
        } else {
            text = "Steady growth does not reach enough to retire within this plan. Drag on the chart to look around."
        }
        if mode == .detailed {
            text += " The shaded bands cover the middle 50% and 80% of 1,000 simulated futures."
        }
        return text
    }

    // MARK: Helpers

    private static func bandSlices(points: [YearPoint], low: [Money], high: [Money]) -> [BandSlice] {
        let count = min(points.count, min(low.count, high.count))
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            BandSlice(age: points[index].age,
                      low: max(0, low[index].doubleValue),
                      high: high[index].doubleValue)
        }
    }

    private static func compactMoney(_ dollars: Double) -> String {
        // Clamp well inside Int64 before converting (LESSONS_FROM_STASHY §2: `isFinite` alone
        // doesn't make a Double to Int conversion safe).
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }
}
