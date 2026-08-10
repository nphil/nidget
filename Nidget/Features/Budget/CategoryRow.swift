import SwiftUI

// MARK: - CategoryRow
//
// One category's line in the Budget list (ARCHITECTURE §14): name (+ a small badge when the
// category carries its balance into next month), then three tap targets — budgeted (opens
// BudgetAmountEditor), spent (opens the filtered Transactions list), and a colorized balance
// pill — with a thin spent/budgeted progress bar underneath that switches to the negative color
// on overspend. Purely presentational: navigation and sheet presentation live in the parent
// (BudgetView); this view only reports taps upward, matching TransactionRow's shape.

struct CategoryRow: View {
    private let row: BudgetRowSnapshot
    private let onEditBudgeted: () -> Void
    private let onTapSpent: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(row: BudgetRowSnapshot, onEditBudgeted: @escaping () -> Void, onTapSpent: @escaping () -> Void) {
        self.row = row
        self.onEditBudgeted = onEditBudgeted
        self.onTapSpent = onTapSpent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: theme.layout.spacing * 0.5) {
                nameColumn
                Spacer(minLength: 4)
                budgetedButton
                spentButton
                balancePill
            }
            progressBar
        }
        .padding(.vertical, 2)
        .animation(reduceMotion ? nil : theme.motion.spring, value: row.spent)
        .animation(reduceMotion ? nil : theme.motion.spring, value: row.budgeted)
        .animation(reduceMotion ? nil : theme.motion.spring, value: row.balance)
    }

    // MARK: Name

    private var nameColumn: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            if row.carryover {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accentSecondary)
                    .accessibilityLabel("Carries over")
            }
        }
        .frame(minHeight: 44, alignment: .leading)
    }

    // MARK: Amounts

    private var budgetedButton: some View {
        Button(action: onEditBudgeted) {
            AmountText(row.budgeted, style: .body, colorized: false)
                .frame(minWidth: 66, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Budgeted \(CurrencyFormatter.string(row.budgeted))")
        .accessibilityHint("Double-tap to edit")
    }

    private var spentButton: some View {
        Button(action: onTapSpent) {
            AmountText(row.spent, style: .body)
                .frame(minWidth: 66, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Spent \(CurrencyFormatter.string(row.spent))")
        .accessibilityHint("Double-tap to see transactions")
    }

    private var balancePill: some View {
        let isPositive = row.balance.cents >= 0
        return AmountText(row.balance, style: .caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule().fill((isPositive ? theme.palette.positive : theme.palette.negative).opacity(0.16))
            }
            .frame(minWidth: 74, minHeight: 44)
    }

    // MARK: Progress bar

    private var spentMagnitude: Money { row.spent.magnitude }

    private var isOverspent: Bool {
        row.budgeted.cents > 0 ? spentMagnitude.cents > row.budgeted.cents : spentMagnitude.cents > 0
    }

    private var progressFraction: Double {
        guard row.budgeted.cents > 0 else { return spentMagnitude.cents > 0 ? 1.0 : 0.0 }
        return min(Double(spentMagnitude.cents) / Double(row.budgeted.cents), 1.0)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.palette.fill)
                Capsule()
                    .fill(isOverspent ? AnyShapeStyle(theme.palette.negative) : AnyShapeStyle(theme.accentGradient))
                    .frame(width: max(0, width * progressFraction))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
