import SwiftUI

// MARK: - RecentActivityWidget
//
// The ledger's pulse: the last few transactions with payee, relative day, and amount. Rows are
// collapsed (day shown inline per row rather than as section headers) to fit the tile. Loads
// via `.task(id: store.accounts)` so every mutation/sync refresh re-pulls; tapping the card
// jumps to the Transactions tab.

struct RecentActivityWidget: View {
    let span: WidgetSpan

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var transactions: [Transaction] = []
    @State private var hasLoaded = false

    var body: some View {
        WidgetCardButton(action: { router.tab = .transactions }) {
            content
        }
        .accessibilityHint("Opens your transactions")
        .task(id: store.accounts) {
            let rows = await store.recentTransactions(limit: 6)
            guard !Task.isCancelled else { return }
            transactions = rows
            hasLoaded = true
        }
    }

    private var rowLimit: Int {
        span == .s2x2 ? 6 : 3
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            WidgetLabel("Recent Activity")
            if !hasLoaded {
                loadingBody
            } else if transactions.isEmpty {
                emptyBody
            } else {
                VStack(spacing: 2) {
                    ForEach(transactions.prefix(rowLimit)) { transaction in
                        row(transaction)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .animation(reduceMotion ? nil : theme.motion.spring, value: transactions)
    }

    private var loadingBody: some View {
        VStack {
            Spacer(minLength: 0)
            ProgressView()
                .tint(theme.palette.accent)
                .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var emptyBody: some View {
        if span == .s2x2 {
            EmptyStateView(systemImage: "sparkles",
                           title: "No activity yet",
                           message: "Transactions you add will land here, freshest first.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                Text("All quiet so far")
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("New transactions will land here.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Row

    private func row(_ transaction: Transaction) -> some View {
        HStack(spacing: theme.layout.spacing * 0.5) {
            VStack(alignment: .leading, spacing: 1) {
                Text(payeeDisplay(transaction))
                    .font(theme.font(.subheadline))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(transaction.date.relativeDisplay)
                    .font(theme.font(.label))
                    .foregroundStyle(theme.palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: theme.layout.spacing * 0.5)
            AmountText(transaction.amount, style: .caption)
        }
        .frame(minHeight: 34, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func payeeDisplay(_ transaction: Transaction) -> String {
        let name = store.payeeName(transaction.payeeID)
        return name.isEmpty ? "No payee" : name
    }
}
