import SwiftUI

// MARK: - SavingsRateWidget
//
// A GaugeArc of (income − spend) ÷ income for the month in view — the slice of income that
// stayed put. Reads the published month snapshot; a negative rate keeps the gauge empty while
// the label stays honest. Tapping pushes Reports.

struct SavingsRateWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WidgetCardButton(action: { router.push(.reports) }) {
            content
        }
        .accessibilityHint("Opens reports")
    }

    // MARK: Data

    private var income: Money {
        store.monthSnapshot?.income ?? .zero
    }

    private var spent: Money {
        store.monthSnapshot?.totalSpent.magnitude ?? .zero
    }

    private var rate: Double {
        guard income.cents > 0 else { return 0 }
        return (income.doubleValue - spent.doubleValue) / income.doubleValue
    }

    private var gaugeProgress: Double {
        min(max(rate, 0), 1)
    }

    private var rateText: String {
        guard store.monthSnapshot != nil, income.cents > 0 else { return "—" }
        return rate.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if span == .s1x1 {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
                WidgetLabel("Savings Rate")
                gauge
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
                WidgetLabel("Savings Rate")
                HStack(spacing: theme.layout.spacing) {
                    gauge
                        .frame(maxHeight: .infinity)
                    detailColumn
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var gauge: some View {
        GaugeArc(progress: gaugeProgress, label: rateText, detail: "saved")
            .animation(reduceMotion ? nil : theme.motion.spring, value: gaugeProgress)
    }

    @ViewBuilder
    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.monthSnapshot == nil {
                AmountText(.zero, style: .body, redacted: true)
                Text("Doing the math…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
            } else if income.cents == 0 {
                Text("No income yet")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("Log income to track your rate.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    WidgetLabel("Income")
                    AmountText(income, style: .caption, colorized: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    WidgetLabel("Spent")
                    AmountText(spent.negated, style: .caption)
                }
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: income)
    }
}
