import SwiftUI

// MARK: - BudgetAmountEditor
//
// Sheet for setting one category's budgeted amount for a month (ARCHITECTURE §14): category
// name, a live amount display, the shared AmountKeypad, a row of quick actions, and Save.
// Presented by BudgetView as `.sheet(item:)` with a ~420pt detent.
//
// Quick actions are deliberately limited to what `AppStore`'s public surface can actually
// compute: "Spent last month" comes from `spendingByCategory(month:)`; "Zero" is trivial;
// "Balance to zero" is pure arithmetic on the row snapshot captured at open time
// (`newBudgeted = budgeted − balance`, since `balance = carriedIn + budgeted + spent`). There is
// no AppStore API for a prior month's BUDGETED amount (only the current month's snapshot plus
// spend-by-category), so "Budgeted last month" is intentionally omitted rather than guessed.

struct BudgetAmountEditor: View {
    private let categoryID: String
    private let categoryName: String
    private let month: BudgetMonth
    private let initialBudgeted: Money
    private let openingBalance: Money

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var amount: Money
    @State private var isSaving = false
    @State private var lastMonthSpent: Money?

    init(row: BudgetRowSnapshot, month: BudgetMonth) {
        self.categoryID = row.id
        self.categoryName = row.name
        self.month = month
        self.initialBudgeted = row.budgeted
        self.openingBalance = row.balance
        self._amount = State(initialValue: row.budgeted)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: theme.layout.spacing) {
                header
                amountDisplay
                AmountKeypad(amount: $amount)
                quickActionsRow
                NidgetButton("Save", systemImage: "checkmark", role: .primary) {
                    save()
                }
                .disabled(isSaving)
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScreen()
        .task { await loadLastMonthSpent() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(categoryName)
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(month.displayName)
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            Spacer(minLength: theme.layout.spacing)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(theme.font(.title))
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.palette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: Amount display

    private var amountDisplay: some View {
        AmountText(amount, style: .display, colorized: false)
            .frame(maxWidth: .infinity)
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : theme.motion.snappy, value: amount)
    }

    // MARK: Quick actions

    private var quickActionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                quickActionChip("Spent Last Month", amount: lastMonthSpent, isLoading: lastMonthSpent == nil)
                quickActionChip("Zero", amount: .zero)
                quickActionChip("Balance to Zero", amount: balanceToZeroAmount)
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func quickActionChip(_ title: String, amount value: Money?, isLoading: Bool = false) -> some View {
        Button {
            guard let value else { return }
            Haptics.tick()
            amount = value
        } label: {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(theme.font(.subheadline))
            .foregroundStyle(theme.palette.textSecondary)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Capsule().fill(theme.palette.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(value == nil)
    }

    private var balanceToZeroAmount: Money {
        initialBudgeted - openingBalance
    }

    // MARK: Save

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            await store.setBudgetAmount(month: month, categoryID: categoryID, amount: amount)
            Haptics.success()
            dismiss()
        }
    }

    // MARK: Data

    private func loadLastMonthSpent() async {
        let results = await store.spendingByCategory(month: month.previous)
        guard !Task.isCancelled else { return }
        lastMonthSpent = results.first(where: { $0.categoryID == categoryID })?.amount ?? .zero
    }
}
