import SwiftUI
import Charts

// MARK: - CashFlowReport
//
// Grouped income-vs-spending bars per month with a net line overlay. `AppStore` has no
// range-native income series (`incomeTotal` lives on `BudgetDatabase`, not exposed on the
// store), so both sides are aggregated from one `transactions(_:)` query across the range —
// the same technique `CashFlowWidget` already uses (on-budget accounts, transfers and split
// parents excluded) — rather than N+1 per-month round trips.

struct CashFlowReport: View {
    let monthsBack: Int

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.privacyMode) private var privacyMode

    private struct FlowPoint: Identifiable, Equatable {
        let month: BudgetMonth
        let income: Money
        /// Positive magnitude of the month's outflow.
        let spend: Money
        var net: Money { income - spend }
        var id: Int { month.raw }
    }

    @State private var points: [FlowPoint] = []
    @State private var hasLoaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing) {
            ReportCardHeader(title: "Cash Flow",
                             statAmount: totalNet,
                             statLabel: "\(monthsBack)-month net",
                             colorized: true,
                             showSign: true)
            if !hasLoaded {
                loadingBody
            } else if maxValue == 0 {
                EmptyStateView(systemImage: "arrow.left.arrow.right",
                               title: "Nothing moved",
                               message: "No income or spending recorded across the selected range.")
                    .frame(maxWidth: .infinity)
            } else {
                legend
                chart
            }
        }
        .themedCard()
        .task(id: monthsBack) {
            hasLoaded = false
            await load()
        }
    }

    // MARK: Stats

    private var totalNet: Money {
        points.reduce(Money.zero) { $0 + $1.net }
    }

    private var maxValue: Double {
        points.reduce(0) { max($0, max($1.income.doubleValue, $1.spend.doubleValue)) }
    }

    // MARK: Loading

    private var loadingBody: some View {
        VStack(spacing: theme.layout.spacing) {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
            Text("Tallying the flow…")
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: Legend

    private var legend: some View {
        HStack(spacing: theme.layout.spacing) {
            legendDot(color: theme.palette.positive, text: "Income")
            legendDot(color: theme.palette.negative, text: "Spending")
            legendDot(color: theme.palette.accent, text: "Net")
        }
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .accessibilityHidden(true)
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                BarMark(x: .value("Month", point.month.shortName), y: .value("Amount", point.income.doubleValue))
                    .foregroundStyle(theme.palette.positive)
                    .position(by: .value("Type", "Income"))
                    .cornerRadius(theme.chart.barCornerRadius)
                BarMark(x: .value("Month", point.month.shortName), y: .value("Amount", point.spend.doubleValue))
                    .foregroundStyle(theme.palette.negative)
                    .position(by: .value("Type", "Spending"))
                    .cornerRadius(theme.chart.barCornerRadius)
            }
            ForEach(points) { point in
                LineMark(x: .value("Month", point.month.shortName), y: .value("Net", point.net.doubleValue))
                    .foregroundStyle(theme.palette.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(theme.chart.smoothLines ? .catmullRom : .linear)
                    .symbol {
                        Circle()
                            .fill(theme.palette.accent)
                            .frame(width: 6, height: 6)
                    }
            }
        }
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
    }

    private func compactMoney(_ dollars: Double) -> String {
        // Clamp well inside Int64 before converting (LESSONS_FROM_STASHY §2: `isFinite` alone
        // doesn't make a Double→Int conversion safe).
        let cents = (dollars * 100).rounded()
        let clamped = cents.isFinite ? min(max(cents, -9e17), 9e17) : 0
        return CurrencyFormatter.string(Money(cents: Int64(clamped)), format: .compact)
    }

    // MARK: Load

    private func load() async {
        let months = BudgetMonth.lastMonths(monthsBack)
        guard let start = months.first, let end = months.last else {
            points = []
            hasLoaded = true
            return
        }
        let rows = await store.transactions(TransactionQuery(months: start...end, limit: monthsBack * 1500))
        guard !Task.isCancelled else { return }

        let onBudgetIDs = Set(store.accounts.filter { !$0.offBudget }.map(\.id))
        var income: [BudgetMonth: Money] = [:]
        var spend: [BudgetMonth: Money] = [:]
        for transaction in rows where transaction.transferID == nil
            && !transaction.isParent
            && onBudgetIDs.contains(transaction.accountID) {
            let month = transaction.date.month
            guard month >= start, month <= end else { continue }
            if transaction.amount.cents > 0 {
                income[month, default: .zero] += transaction.amount
            } else {
                spend[month, default: .zero] += transaction.amount.magnitude
            }
        }
        points = months.map { FlowPoint(month: $0, income: income[$0] ?? .zero, spend: spend[$0] ?? .zero) }
        hasLoaded = true
    }
}
