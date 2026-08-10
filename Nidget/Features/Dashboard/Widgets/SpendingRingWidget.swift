import SwiftUI

// MARK: - SpendingRingWidget
//
// A ProgressRing of month-to-date spending against total budgeted, with the amounts alongside
// at 2x1. The ring's overflow lap (built into ProgressRing) shows over-budget months honestly.
// Tapping opens the Budget tab.

struct SpendingRingWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        WidgetCardButton(action: { router.tab = .budget }) {
            content
        }
        .accessibilityHint("Opens the budget")
    }

    // MARK: Data

    private var spent: Money {
        store.monthSnapshot?.totalSpent.magnitude ?? .zero
    }

    private var budgeted: Money {
        store.monthSnapshot?.totalBudgeted ?? .zero
    }

    private var progress: Double {
        guard budgeted.cents > 0 else { return 0 }
        return spent.doubleValue / budgeted.doubleValue
    }

    private var percentText: String {
        progress.formatted(.percent.precision(.fractionLength(0)))
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
            WidgetLabel("Spending")
            ring
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var wideBody: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel("Spending")
            HStack(spacing: theme.layout.spacing) {
                ring
                    .frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 3) {
                    if store.monthSnapshot == nil {
                        AmountText(.zero, style: .title, redacted: true)
                        Text("Adding it all up…")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textTertiary)
                    } else if budgeted.cents == 0 && spent.cents == 0 {
                        Text("Nothing budgeted yet")
                            .font(theme.font(.headline))
                            .foregroundStyle(theme.palette.textPrimary)
                        Text("Give this month a plan")
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                    } else {
                        AmountText(spent.negated, style: .title)
                        HStack(spacing: 4) {
                            Text("of")
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.palette.textSecondary)
                            AmountText(budgeted, style: .caption, colorized: false)
                            Text("budgeted")
                                .font(theme.font(.caption))
                                .foregroundStyle(theme.palette.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var ring: some View {
        ProgressRing(progress: progress, lineWidth: 9)
            .overlay {
                Text(percentText)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(14)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : theme.motion.snappy, value: percentText)
            }
            .animation(reduceMotion ? nil : theme.motion.spring, value: progress)
    }
}
