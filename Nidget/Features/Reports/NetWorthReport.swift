import SwiftUI
import Charts

// MARK: - NetWorthReport
//
// Net worth over the selected range as a LineMark + optional AreaMark (gradient fill / smoothed
// curve gated on `theme.chart.filledAreas` / `theme.chart.smoothLines`), with tap-or-drag
// selection (`chartXSelection`) showing a RuleMark + annotation callout for the nearest month.

struct NetWorthReport: View {
    let monthsBack: Int

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.privacyMode) private var privacyMode

    private struct NetWorthPoint: Identifiable, Equatable {
        let month: BudgetMonth
        let amount: Money
        var id: Int { month.raw }
        var date: Date { month.date }
    }

    @State private var points: [NetWorthPoint] = []
    @State private var hasLoaded = false
    @State private var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            ReportCardHeader(title: "Net Worth",
                             statAmount: current,
                             statLabel: "Current",
                             colorized: false)
            if hasLoaded && points.count > 1 {
                deltaChip
            }
            if !hasLoaded {
                loadingBody
            } else if points.count < 2 {
                EmptyStateView(systemImage: "chart.line.uptrend.xyaxis",
                               title: "Not enough data",
                               message: "Net worth needs at least two months of activity to chart a trend.")
                    .frame(maxWidth: .infinity)
            } else {
                chart
            }
        }
        .themedCard()
        .task(id: monthsBack) {
            hasLoaded = false
            selectedDate = nil
            await load()
        }
    }

    // MARK: Stats

    private var current: Money { points.last?.amount ?? .zero }
    private var delta: Money { current - (points.first?.amount ?? .zero) }

    private var deltaChip: some View {
        let rising = delta.cents >= 0
        let chipColor = rising ? theme.palette.positive : theme.palette.negative
        return HStack(spacing: 3) {
            Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(chipColor)
            AmountText(delta, style: .caption, showSign: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background { Capsule().fill(chipColor.opacity(0.14)) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rising ? "Up over the selected range" : "Down over the selected range")
    }

    // MARK: Loading

    private var loadingBody: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Adding it all up…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                if theme.chart.filledAreas {
                    AreaMark(x: .value("Month", point.date), y: .value("Net Worth", point.amount.doubleValue))
                        .interpolationMethod(theme.chart.smoothLines ? .catmullRom : .linear)
                        .foregroundStyle(areaGradient)
                }
                LineMark(x: .value("Month", point.date), y: .value("Net Worth", point.amount.doubleValue))
                    .interpolationMethod(theme.chart.smoothLines ? .catmullRom : .linear)
                    .foregroundStyle(theme.palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let nearest = nearestPoint {
                PointMark(x: .value("Month", nearest.date), y: .value("Net Worth", nearest.amount.doubleValue))
                    .foregroundStyle(theme.palette.accent)
                    .symbolSize(90)
                RuleMark(x: .value("Month", nearest.date))
                    .foregroundStyle(theme.palette.textTertiary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 6) {
                        callout(nearest)
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXAxis {
            AxisMarks { _ in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel()
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                if theme.chart.gridLines { AxisGridLine() }
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(compactMoney(dollars))
                    }
                }
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .frame(height: 220)
        .animation(reduceMotion ? nil : theme.motion.spring, value: points)
        .privacySensitive()
        .blur(radius: privacyMode ? 8 : 0)
        .accessibilityHidden(true)
        .onChange(of: selectedDate) { oldValue, newValue in
            if oldValue == nil, newValue != nil { Haptics.tick() }
        }
    }

    private var areaGradient: LinearGradient {
        LinearGradient(colors: [theme.palette.accent.opacity(0.35), theme.palette.accent.opacity(0.02)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var nearestPoint: NetWorthPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private func callout(_ point: NetWorthPoint) -> some View {
        VStack(spacing: 2) {
            Text(point.month.compactName)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textSecondary)
            AmountText(point.amount, style: .caption, colorized: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background { Capsule().fill(theme.palette.surfaceElevated) }
    }

    private func compactMoney(_ dollars: Double) -> String {
        CurrencyFormatter.string(Money(cents: Int64((dollars * 100).rounded())), format: .compact)
    }

    // MARK: Load

    private func load() async {
        let series = await store.netWorthSeries(monthsBack: monthsBack)
        guard !Task.isCancelled else { return }
        points = series.map { NetWorthPoint(month: $0.0, amount: $0.1) }
        hasLoaded = true
    }
}
