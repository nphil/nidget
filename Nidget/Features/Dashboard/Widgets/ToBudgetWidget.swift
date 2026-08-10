import SwiftUI

// MARK: - ToBudgetWidget
//
// The envelope-budget headline: how much money is still waiting for a job this month.
// Reads the published month snapshot (no async work needed); AmountText colorizes green when
// positive, red when overassigned, and redacts under privacy mode. Tapping opens the Budget tab.

struct ToBudgetWidget: View {
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

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel(labelText)
            Spacer(minLength: 0)
            if let snapshot = store.monthSnapshot {
                AmountText(snapshot.toBudget, style: .display)
                Text(snapshot.toBudget.cents < 0 ? "Overassigned — rebalance" : "Ready to assign")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if span != .s1x1 {
                    statsRow(snapshot)
                        .padding(.top, theme.layout.spacing * 0.4)
                }
            } else {
                AmountText(.zero, style: .display, redacted: true)
                Text("Warming up the envelopes…")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: store.monthSnapshot?.toBudget)
    }

    private var labelText: String {
        store.currentMonth == .current ? "To Budget" : "To Budget · \(store.currentMonth.shortName)"
    }

    private func statsRow(_ snapshot: MonthBudgetSnapshot) -> some View {
        HStack(spacing: theme.layout.spacing) {
            VStack(alignment: .leading, spacing: 2) {
                WidgetLabel("Budgeted")
                AmountText(snapshot.totalBudgeted, style: .caption, colorized: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                WidgetLabel("Spent")
                AmountText(snapshot.totalSpent, style: .caption)
            }
            Spacer(minLength: 0)
        }
    }
}
