import SwiftUI

// MARK: - TransactionRow
//
// One transaction in a list: cleared indicator (tappable dot; lock when reconciled), payee name,
// category chip (warning-tinted when uncategorized), single-line notes, and the colorized amount.
// Purely presentational — swipe actions, navigation, and the actual `setCleared` write live in
// the parent (TransactionsView / AccountDetailView). The row only reports a dot tap upward so
// the parent can run its optimistic-edit sequence-token dance.

struct TransactionRow: View {
    private let transaction: Transaction
    private let onToggleCleared: (() -> Void)?

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(transaction: Transaction, onToggleCleared: (() -> Void)? = nil) {
        self.transaction = transaction
        self.onToggleCleared = onToggleCleared
    }

    var body: some View {
        HStack(spacing: theme.layout.spacing * 0.75) {
            statusIndicator
            VStack(alignment: .leading, spacing: 3) {
                Text(payeeDisplay)
                    .font(theme.font(.headline))
                    .foregroundStyle(hasPayee ? theme.palette.textPrimary : theme.palette.textTertiary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    categoryChip
                    if let notes = transaction.notes, !notes.isEmpty {
                        Text(notes)
                            .font(theme.font(.caption))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            AmountText(transaction.amount, style: .body)
        }
        .frame(minHeight: 44)
        .animation(reduceMotion ? nil : theme.motion.spring, value: transaction.cleared)
    }

    // MARK: Payee

    private var hasPayee: Bool {
        !store.payeeName(transaction.payeeID).isEmpty
    }

    private var payeeDisplay: String {
        let name = store.payeeName(transaction.payeeID)
        return name.isEmpty ? "No payee" : name
    }

    // MARK: Category chip

    @ViewBuilder
    private var categoryChip: some View {
        let name = store.categoryName(transaction.categoryID)
        if transaction.transferID != nil {
            chip(text: "Transfer", tint: theme.palette.textSecondary, fill: theme.palette.fill)
        } else if transaction.categoryID == nil || name.isEmpty {
            chip(text: "Uncategorized",
                 tint: theme.palette.warning,
                 fill: theme.palette.warning.opacity(0.16))
        } else {
            chip(text: name, tint: theme.palette.textSecondary, fill: theme.palette.fill)
        }
    }

    private func chip(text: String, tint: Color, fill: Color) -> some View {
        Text(text)
            .font(theme.font(.caption))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill))
    }

    // MARK: Cleared indicator

    @ViewBuilder
    private var statusIndicator: some View {
        if transaction.reconciled {
            Image(systemName: "lock")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 34, height: 44)
                .accessibilityLabel("Reconciled")
        } else {
            Button {
                onToggleCleared?()
            } label: {
                ZStack {
                    Circle()
                        .strokeBorder(transaction.cleared ? theme.palette.accent : theme.palette.textTertiary,
                                      lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(theme.palette.accent)
                        .frame(width: 10, height: 10)
                        .scaleEffect(transaction.cleared ? 1.0 : 0.01)
                        .opacity(transaction.cleared ? 1.0 : 0.0)
                }
                .frame(width: 34, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(onToggleCleared == nil)
            .accessibilityLabel(transaction.cleared ? "Cleared" : "Uncleared")
            .accessibilityHint(onToggleCleared == nil ? "" : "Double-tap to toggle cleared")
        }
    }
}
