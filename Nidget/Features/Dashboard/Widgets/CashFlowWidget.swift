import SwiftUI

// MARK: - CashFlowWidget
//
// Income vs. spend for the last three months as mini bar pairs — pure shapes, deliberately not
// Swift Charts. Both sides are aggregated from one transactions query (on-budget accounts,
// transfers and split parents excluded) so the pair is always internally consistent. Tapping
// pushes Reports.

struct CashFlowWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct MonthFlow: Equatable, Identifiable {
        let month: BudgetMonth
        let income: Money
        /// Positive magnitude of the month's outflow.
        let spend: Money
        var id: Int { month.raw }
    }

    @State private var flows: [MonthFlow] = []
    @State private var hasLoaded = false

    var body: some View {
        WidgetCardButton(action: { router.push(.reports) }) {
            content
        }
        .accessibilityHint("Opens reports")
        .task(id: store.accounts) {
            await load()
        }
    }

    // MARK: Load

    private func load() async {
        let end = BudgetMonth.current
        let start = end.advanced(by: -2)
        let rows = await store.transactions(TransactionQuery(months: start...end, limit: 4000))
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
                income[month] = (income[month] ?? .zero) + transaction.amount
            } else {
                spend[month] = (spend[month] ?? .zero) + transaction.amount.magnitude
            }
        }
        flows = BudgetMonth.lastMonths(3, endingAt: end).map { month in
            MonthFlow(month: month,
                      income: income[month] ?? .zero,
                      spend: spend[month] ?? .zero)
        }
        hasLoaded = true
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if span == .s1x1 {
            compactBody
        } else {
            wideBody
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel("Cash Flow")
            Spacer(minLength: 0)
            if hasLoaded {
                AmountText(netThisMonth, style: .title, showSign: true)
                Text("in vs out this month")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                AmountText(.zero, style: .title, redacted: true)
                Text("Tallying the flow…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: flows)
    }

    private var netThisMonth: Money {
        guard let latest = flows.last else { return .zero }
        return latest.income - latest.spend
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            HStack {
                WidgetLabel("Cash Flow")
                Spacer(minLength: theme.layout.spacing * 0.5)
                legend
            }
            if !hasLoaded {
                VStack {
                    Spacer(minLength: 0)
                    ProgressView()
                        .tint(theme.palette.accent)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            } else if maxValue == 0 {
                Spacer(minLength: 0)
                Text("Three quiet months — nothing in, nothing out.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: 0)
            } else {
                bars
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: flows)
    }

    private var legend: some View {
        HStack(spacing: theme.layout.spacing * 0.5) {
            legendDot(color: theme.palette.positive, text: "In")
            legendDot(color: theme.palette.negative, text: "Out")
        }
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(theme.font(.label))
                .foregroundStyle(theme.palette.textTertiary)
        }
        .accessibilityHidden(true)
    }

    // MARK: Bars

    private var maxValue: Double {
        flows.reduce(0) { max($0, max($1.income.doubleValue, $1.spend.doubleValue)) }
    }

    private var bars: some View {
        GeometryReader { geo in
            let labelHeight: CGFloat = 18
            let barArea = max(geo.size.height - labelHeight, 8)
            let peak = max(maxValue, 0.01)
            HStack(alignment: .bottom, spacing: theme.layout.spacing) {
                ForEach(flows) { flow in
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 3) {
                            bar(height: barArea * flow.income.doubleValue / peak,
                                color: theme.palette.positive)
                            bar(height: barArea * flow.spend.doubleValue / peak,
                                color: theme.palette.negative)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        Text(flow.month.shortName)
                            .font(theme.font(.label))
                            .foregroundStyle(theme.palette.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Income versus spending bars for the last three months")
    }

    private func bar(height: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: theme.chart.barCornerRadius, style: .continuous)
            .fill(color)
            .frame(maxWidth: 22)
            .frame(height: max(height, 3))
    }
}
