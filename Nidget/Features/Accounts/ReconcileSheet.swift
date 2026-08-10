import SwiftUI

// MARK: - ReconcileSheet
//
// Presented as a sheet from AccountDetailView's toolbar. Enter a bank statement's ending balance
// on the shared `AmountKeypad`; the cleared balance for the account (loaded once, up to
// `fetchLimit` transactions) is compared live, with a "Not Yet Cleared" review list so the user
// can tap uncleared transactions into the cleared balance until the two numbers match — reusing
// `AppStore.setCleared`, the same optimistic + sequence-token dance as AccountDetailView, but
// settling with a full reload rather than a manual rollback (reconciliation is a deliberate,
// low-frequency flow, not a scroll hot path, so re-querying the account is cheap and simplest).
// When the diff hits zero, a "Balances!" state plays a `.bounce` symbol effect.
//
// IMPORTANT LIMIT (see this feature's final report): `AppStore` has no reconcile method, and
// `TransactionDraft` carries no `reconciled` field — there is no existing API that can persist
// `Transaction.reconciled = true`. Per instructions this gap is documented rather than invented
// around (no new AppStore method, and no misleading `setCleared`/`updateTransaction` loop that
// would silently fail to lock anything). Confirm therefore only finalizes the LOCAL reconciliation
// flow once the account is proven balanced — the cleared states the user set while reviewing here
// are already real, persisted `setCleared` writes; only the immutable "reconciled" lock is
// unavailable.

struct ReconcileSheet: View {
    let accountID: String

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var statementBalance: Money = .zero
    @State private var clearedBalance: Money = .zero
    @State private var hasLoaded = false
    @State private var reviewTransactions: [Transaction] = []
    @State private var clearedEditSeq: [String: Int] = [:]
    @State private var isConfirming = false

    private static let fetchLimit = 20_000

    init(accountID: String) {
        self.accountID = accountID
    }

    var body: some View {
        ScrollView {
            VStack(spacing: theme.layout.spacing) {
                header
                if hasLoaded {
                    statusCard
                    AmountKeypad(amount: $statementBalance, allowsSign: true)
                    if !reviewTransactions.isEmpty {
                        reviewSection
                    }
                    NidgetButton("Confirm Reconciliation", systemImage: "checkmark", role: .primary) {
                        confirm()
                    }
                    .disabled(!isBalanced || isConfirming)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(theme.palette.accent)
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .themedScreen()
        .task(id: accountID) { await load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reconcile")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                Text(accountName)
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

    private var accountName: String {
        let name = store.accounts.first(where: { $0.id == accountID })?.name ?? ""
        return name.isEmpty ? "Account" : name
    }

    // MARK: Status

    @ViewBuilder
    private var statusCard: some View {
        VStack(spacing: theme.layout.spacing * 0.6) {
            if isBalanced {
                Image(systemName: "checkmark.seal")
                    .font(theme.font(.hero))
                    .symbolRenderingMode(.hierarchical)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.positive)
                    .symbolEffect(.bounce, value: reduceMotion ? false : isBalanced)
                Text("Balances!")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
            } else {
                Text("Off by")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.warning)
                AmountText(diff.magnitude, style: .display, colorized: false)
                Text(diff.cents > 0
                     ? "The statement is ahead — clear more transactions."
                     : "Cleared transactions are ahead of the statement.")
                    .font(theme.font(.caption))
                    .foregroundStyle(theme.palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: theme.layout.spacing * 1.5) {
                statColumn("Cleared", clearedBalance)
                statColumn("Statement", statementBalance)
            }
        }
        .frame(maxWidth: .infinity)
        .themedCard()
        .animation(reduceMotion ? nil : theme.motion.spring, value: isBalanced)
    }

    private func statColumn(_ label: String, _ amount: Money) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            AmountText(amount, style: .body, colorized: false)
        }
    }

    // MARK: Review uncleared transactions

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.4) {
            SectionHeader("Not Yet Cleared")
            VStack(spacing: 0) {
                ForEach(reviewTransactions) { transaction in
                    ReconcileTransactionRow(transaction: transaction) {
                        toggleCleared(transaction)
                    }
                    if transaction.id != reviewTransactions.last?.id {
                        Divider()
                            .background(theme.palette.separator)
                    }
                }
            }
            .themedCard(padding: 10)
        }
    }

    // MARK: Data

    private var diff: Money { statementBalance - clearedBalance }
    private var isBalanced: Bool { hasLoaded && diff == .zero }

    private func load() async {
        let all = await store.transactions(TransactionQuery(accountID: accountID, limit: Self.fetchLimit))
        guard !Task.isCancelled else { return }
        clearedBalance = all.reduce(Money.zero) { $1.cleared ? $0 + $1.amount : $0 }
        reviewTransactions = all.filter { !$0.cleared }.sorted { $0.date > $1.date }
        hasLoaded = true
    }

    // MARK: Cleared toggle (optimistic + sequence token, settles via a fresh full reload —
    // LESSONS_FROM_STASHY §2 — rather than manual rollback math)

    private func toggleCleared(_ transaction: Transaction) {
        let newValue = !transaction.cleared
        let seq = (clearedEditSeq[transaction.id] ?? 0) + 1
        clearedEditSeq[transaction.id] = seq
        Haptics.tick()
        let delta = newValue ? transaction.amount : transaction.amount.negated
        let apply = {
            clearedBalance = clearedBalance + delta
            reviewTransactions.removeAll { $0.id == transaction.id }
        }
        if reduceMotion {
            apply()
        } else {
            withAnimation(theme.motion.spring, apply)
        }
        Task {
            await store.setCleared(id: transaction.id, cleared: newValue)
            guard clearedEditSeq[transaction.id] == seq else { return }
            await load()
        }
    }

    // MARK: Confirm

    private func confirm() {
        guard isBalanced, !isConfirming else { return }
        isConfirming = true
        Haptics.success()
        dismiss()
    }
}

// MARK: - ReconcileTransactionRow
//
// Compact tap-to-toggle row for the "Not Yet Cleared" review list — a private mirror of the
// cleared-toggle affordance built from shared DesignSystem components only, distinct from
// TransactionRow.swift and from AccountDetailView's own private row.

private struct ReconcileTransactionRow: View {
    private let transaction: Transaction
    private let onToggleCleared: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    init(transaction: Transaction, onToggleCleared: @escaping () -> Void) {
        self.transaction = transaction
        self.onToggleCleared = onToggleCleared
    }

    var body: some View {
        Button(action: onToggleCleared) {
            HStack(spacing: theme.layout.spacing * 0.6) {
                Image(systemName: "circle")
                    .font(theme.font(.body))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(payeeDisplay)
                        .font(theme.font(.subheadline))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    Text(transaction.date.shortDisplay)
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                Spacer(minLength: theme.layout.spacing * 0.5)
                AmountText(transaction.amount, style: .caption)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(payeeDisplay), uncleared")
        .accessibilityHint("Double-tap to mark cleared")
    }

    private var payeeDisplay: String {
        let name = store.payeeName(transaction.payeeID)
        return name.isEmpty ? "No payee" : name
    }
}
