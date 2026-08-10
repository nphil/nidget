import SwiftUI
import Charts

// MARK: - CategoryTrendsReport
//
// Small-multiples of the top 6 categories over the selected range: a tiny per-month bar chart
// plus a trend chip (comparing the first-half vs. second-half monthly average) in a 2-column
// grid. Aggregated the same way `SpendingReport` is — one `spendingByCategory(month:)` call per
// month in range — but kept as an independent load since the two reports render simultaneously
// different data shapes (a total-by-category snapshot vs. a per-category series).

struct CategoryTrendsReport: View {
    let monthsBack: Int

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.privacyMode) private var privacyMode

    private struct MonthAmount: Identifiable, Equatable {
        let month: BudgetMonth
        let amount: Money
        var id: Int { month.raw }
    }

    private struct CategoryTrend: Identifiable, Equatable {
        let id: String
        let name: String
        let series: [MonthAmount]
        let total: Money
        /// Fractional change of the second-half average vs. the first-half average; positive
        /// means spending is rising. `nil` when there isn't enough history to compare.
        let trendPct: Double?
    }

    @State private var trends: [CategoryTrend] = []
    @State private var hasLoaded = false

    private static let topCount = 6
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            ReportCardHeader(title: "Category Trends",
                             statAmount: (trends.first?.total ?? .zero).negated,
                             statLabel: "Top category, \(monthsBack)mo",
                             colorized: false)
            if !hasLoaded {
                loadingBody
            } else if trends.isEmpty {
                EmptyStateView(systemImage: "chart.bar.xaxis",
                               title: "Nothing to trend",
                               message: "No categorized spending across the selected range.")
                    .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: columns, spacing: theme.layout.spacing) {
                    ForEach(Array(trends.enumerated()), id: \.element.id) { index, trend in
                        trendCell(trend, index: index)
                    }
                }
                .animation(reduceMotion ? nil : theme.motion.spring, value: trends)
            }
        }
        .themedCard()
        .task(id: monthsBack) {
            hasLoaded = false
            await load()
        }
    }

    // MARK: Loading

    private var loadingBody: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Spotting the patterns…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: Cell

    private func trendCell(_ trend: CategoryTrend, index: Int) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            HStack(alignment: .top) {
                Text(trend.name)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                trendChip(trend)
            }
            Chart(trend.series) { point in
                BarMark(x: .value("Month", point.month.shortName), y: .value("Amount", point.amount.doubleValue))
                    .foregroundStyle(theme.palette.chart[index % theme.palette.chart.count])
                    .cornerRadius(theme.chart.barCornerRadius)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 60)
            .accessibilityHidden(true)
            AmountText(trend.total.negated, style: .caption, colorized: false)
        }
        .padding(theme.layout.spacing * 0.6)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: theme.shape.controlRadius, style: .continuous)
                .fill(theme.palette.fill)
        }
        .privacySensitive()
        .blur(radius: privacyMode ? 6 : 0)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tick()
            router.openTransactions(filter: TransactionQuery(categoryID: trend.id, months: monthRange))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(trend.name), \(CurrencyFormatter.string(trend.total))\(trendAccessibilitySuffix(trend))")
        .accessibilityHint("Opens transactions for this category")
    }

    private func trendChip(_ trend: CategoryTrend) -> some View {
        let pct = trend.trendPct
        let rising = (pct ?? 0) > 0.02
        let falling = (pct ?? 0) < -0.02
        let color = rising ? theme.palette.negative : (falling ? theme.palette.positive : theme.palette.textTertiary)
        let icon = rising ? "arrow.up.right" : (falling ? "arrow.down.right" : "arrow.right")
        return HStack(spacing: 2) {
            Image(systemName: icon)
                .font(theme.font(.label))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(color)
            if let pct {
                Text(abs(pct).formatted(.percent.precision(.fractionLength(0))))
                    .font(theme.font(.label))
                    .foregroundStyle(color)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background { Capsule().fill(color.opacity(0.14)) }
    }

    private func trendAccessibilitySuffix(_ trend: CategoryTrend) -> String {
        guard let pct = trend.trendPct else { return "" }
        let direction = pct > 0.02 ? "up" : (pct < -0.02 ? "down" : "flat")
        return ", trending \(direction)"
    }

    private var monthRange: ClosedRange<BudgetMonth> {
        let months = BudgetMonth.lastMonths(monthsBack)
        let first = months.first ?? .current
        let last = months.last ?? .current
        return first...last
    }

    // MARK: Load

    private func load() async {
        let months = BudgetMonth.lastMonths(monthsBack)
        var perMonth: [BudgetMonth: [String: (name: String, amount: Money)]] = [:]
        for month in months {
            guard !Task.isCancelled else { return }
            let rows = await store.spendingByCategory(month: month)
            var dict: [String: (name: String, amount: Money)] = [:]
            for row in rows { dict[row.categoryID] = (row.name, row.amount) }
            perMonth[month] = dict
        }
        guard !Task.isCancelled else { return }

        var totals: [String: (name: String, amount: Money)] = [:]
        for dict in perMonth.values {
            for (id, entry) in dict {
                let existing = totals[id]?.amount ?? .zero
                totals[id] = (entry.name, existing + entry.amount)
            }
        }

        let topIDs = totals
            .sorted { $0.value.amount.cents > $1.value.amount.cents }
            .prefix(Self.topCount)
            .map(\.key)

        trends = topIDs.map { id in
            let name = totals[id]?.name ?? "Uncategorized"
            let series = months.map { month in
                MonthAmount(month: month, amount: perMonth[month]?[id]?.amount ?? .zero)
            }
            return CategoryTrend(id: id,
                                 name: name,
                                 series: series,
                                 total: totals[id]?.amount ?? .zero,
                                 trendPct: Self.trendPercent(series))
        }
        hasLoaded = true
    }

    private static func trendPercent(_ series: [MonthAmount]) -> Double? {
        guard series.count >= 2 else { return nil }
        let half = series.count / 2
        guard half > 0 else { return nil }
        let firstHalf = series.prefix(half)
        let secondHalf = series.suffix(series.count - half)
        let firstAvg = firstHalf.reduce(0.0) { $0 + $1.amount.doubleValue } / Double(firstHalf.count)
        let secondAvg = secondHalf.reduce(0.0) { $0 + $1.amount.doubleValue } / Double(secondHalf.count)
        guard firstAvg > 0 else { return secondAvg > 0 ? 1.0 : nil }
        return (secondAvg - firstAvg) / firstAvg
    }
}
