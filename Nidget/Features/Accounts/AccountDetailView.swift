import SwiftUI

// MARK: - AccountDetailView
//
// Pushed via `Route.account(id)` (ARCHITECTURE §14/§16) — no NavigationStack of its own. Balance
// hero (total + cleared/uncleared breakdown chips + a SimpleFIN badge when linked), then this
// account's transactions paged 100-at-a-time exactly like TransactionsView (LESSONS_FROM_STASHY
// §1: generation-token reload, `.task(id:)` cancellation guards, a per-id optimistic-edit
// sequence token for the cleared toggle). The row is a private `AccountTransactionRow` that
// mirrors TransactionRow's visual language through shared DesignSystem components only — it does
// not import or modify TransactionRow.swift (owned by the Transactions feature agent). A toolbar
// toggle reveals a running balance per row (ARCHITECTURE §14's "running-balance toggle"), and a
// reconcile toolbar button opens `ReconcileSheet`.
//
// `BudgetDatabase.accountBalances()` only exposes a combined cleared+pending total (see its doc
// comment) — there is no store API for a cleared-only balance — so the cleared/uncleared
// breakdown here is derived client-side from a bounded full-account transaction fetch
// (`balanceFetchLimit`), refreshed whenever `store.accounts` changes and explicitly after every
// cleared toggle (toggling cleared status doesn't change `Account.balance`, so `store.accounts`
// wouldn't otherwise re-trigger the `.task(id:)`).

struct AccountDetailView: View {
    let accountID: String

    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Transaction list (paged)
    @State private var transactions: [Transaction] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var hasLoadedOnce = false
    @State private var loadGeneration = 0

    // Cleared / uncleared breakdown
    @State private var clearedBalance: Money = .zero
    @State private var hasLoadedBalances = false
    @State private var balanceGeneration = 0

    // Edits & chrome
    @State private var clearedEditSeq: [String: Int] = [:]
    @State private var showReconcile = false
    @State private var showRunningBalance = false

    private static let batchSize = 100
    private static let balanceFetchLimit = 20_000

    init(accountID: String) {
        self.accountID = accountID
    }

    var body: some View {
        content
            .themedScreen()
            .navigationTitle(account?.name ?? "Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task(id: accountID) { await reload(preservingDepth: false) }
            .task(id: store.accounts) { await loadBalances() }
            .sheet(isPresented: $showReconcile) {
                ReconcileSheet(accountID: accountID)
                    .presentationDetents([.height(560), .large])
                    .presentationDragIndicator(.visible)
            }
    }

    // MARK: Screen

    @ViewBuilder
    private var content: some View {
        if let account {
            VStack(spacing: 0) {
                balanceHero(account)
                transactionList
            }
        } else {
            EmptyStateView(systemImage: "questionmark.folder",
                           title: "Account not found",
                           message: "This account may have been removed or is still syncing.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var account: Account? {
        store.accounts.first(where: { $0.id == accountID })
    }

    private var unclearedBalance: Money {
        (account?.balance ?? .zero) - clearedBalance
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                Haptics.tick()
                if reduceMotion {
                    showRunningBalance.toggle()
                } else {
                    withAnimation(theme.motion.snappy) { showRunningBalance.toggle() }
                }
            } label: {
                Image(systemName: "number.circle")
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(showRunningBalance ? theme.palette.accent : theme.palette.textSecondary)
            }
            .accessibilityLabel(showRunningBalance ? "Hide running balance" : "Show running balance")

            Button {
                Haptics.tick()
                showReconcile = true
            } label: {
                Image(systemName: "checkmark.seal")
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
            }
            .accessibilityLabel("Reconcile account")
            .disabled(account == nil)
        }
    }

    // MARK: Balance hero

    private func balanceHero(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(account.offBudget ? "Off Budget" : "For Budget")
                Spacer(minLength: theme.layout.spacing)
                if account.simpleFINID != nil {
                    simpleFINBadge
                }
            }
            AmountText(account.balance, style: .display, colorized: false)
            HStack(spacing: theme.layout.spacing * 0.6) {
                breakdownChip(title: "Cleared", amount: clearedBalance, systemImage: "checkmark.circle")
                breakdownChip(title: "Uncleared", amount: unclearedBalance, systemImage: "circle.dotted")
            }
        }
        .themedCard()
        .padding(.horizontal, theme.layout.cardPadding)
        .padding(.top, theme.layout.spacing * 0.5)
        .animation(reduceMotion ? nil : theme.motion.spring, value: account.balance)
    }

    private var simpleFINBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "link")
                .fontWeight(theme.icons.weight)
            Text("SimpleFIN")
        }
        .font(theme.font(.caption))
        .foregroundStyle(theme.palette.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.palette.accent.opacity(0.14)))
    }

    private func breakdownChip(title: String, amount: Money, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(theme.font(.label))
                    .foregroundStyle(theme.palette.textTertiary)
                if hasLoadedBalances {
                    AmountText(amount, style: .caption)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .background(Capsule().fill(theme.palette.fill))
        .animation(reduceMotion ? nil : theme.motion.spring, value: clearedBalance)
    }

    private func loadBalances() async {
        balanceGeneration += 1
        let generation = balanceGeneration
        let all = await store.transactions(TransactionQuery(accountID: accountID, limit: Self.balanceFetchLimit))
        guard !Task.isCancelled, generation == balanceGeneration else { return }
        clearedBalance = all.reduce(Money.zero) { $1.cleared ? $0 + $1.amount : $0 }
        hasLoadedBalances = true
    }

    // MARK: Transaction list

    private var transactionList: some View {
        // Computed once per list render (not per row) — O(n) over the loaded page, never
        // recomputed per cell (LESSONS_FROM_STASHY §1).
        let balances = runningBalances
        return List {
            if transactions.isEmpty && !isLoading && hasLoadedOnce {
                emptyRow
            } else {
                ForEach(daySections) { section in
                    dayHeaderRow(section.day)
                    ForEach(section.items) { transaction in
                        row(transaction, runningBalance: balances[transaction.id])
                    }
                }
                if isLoadingMore {
                    loadingMoreRow
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.syncNow()
            await reload(preservingDepth: true)
            await loadBalances()
        }
        .overlay { initialLoadingOverlay }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 6, leading: theme.layout.cardPadding, bottom: 6, trailing: theme.layout.cardPadding)
    }

    private func dayHeaderRow(_ day: BudgetDay) -> some View {
        SectionHeader(day.relativeDisplay)
            .padding(.top, theme.layout.spacing * 0.5)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(rowInsets)
    }

    private func row(_ transaction: Transaction, runningBalance: Money?) -> some View {
        AccountTransactionRow(transaction: transaction,
                              runningBalance: runningBalance,
                              onToggleCleared: { toggleCleared(transaction) })
            .contentShape(Rectangle())
            .onTapGesture {
                router.push(.transactionDetail(transaction.id))
            }
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(theme.palette.separator)
            .listRowInsets(rowInsets)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !transaction.reconciled {
                    Button {
                        toggleCleared(transaction)
                    } label: {
                        Label(transaction.cleared ? "Uncleared" : "Cleared",
                              systemImage: transaction.cleared ? "circle" : "checkmark.circle")
                    }
                    .tint(theme.palette.accent)
                }
            }
            .onAppear {
                if transaction.id == transactions.last?.id {
                    Task { await loadMore() }
                }
            }
            .accessibilityHint("Opens transaction details")
    }

    private var loadingMoreRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .tint(theme.palette.accent)
            Spacer()
        }
        .frame(minHeight: 44)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var emptyRow: some View {
        EmptyStateView(systemImage: "tray",
                       title: "No transactions",
                       message: "Transactions on this account will show up here.")
            .padding(.top, theme.layout.spacing * 4)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var initialLoadingOverlay: some View {
        ZStack {
            if transactions.isEmpty && (isLoading || !hasLoadedOnce) {
                ProgressView()
                    .controlSize(.large)
                    .tint(theme.palette.accent)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Day grouping

    private struct DaySection: Identifiable {
        let day: BudgetDay
        var items: [Transaction]
        var id: Int { day.raw }
    }

    private var daySections: [DaySection] {
        var sections: [DaySection] = []
        var indexByDay: [Int: Int] = [:]
        for transaction in transactions {
            if let index = indexByDay[transaction.date.raw] {
                sections[index].items.append(transaction)
            } else {
                indexByDay[transaction.date.raw] = sections.count
                sections.append(DaySection(day: transaction.date, items: [transaction]))
            }
        }
        return sections
    }

    // MARK: Running balance
    //
    // `transactions` is a contiguous, newest-first run starting at offset 0, so the balance
    // "after" the newest loaded transaction is simply the account's current total; walking older
    // transactions just undoes each newer one's amount in turn. Assumes no transaction newer than
    // the loaded run landed between the last reload and now — a client-side display aid, not an
    // authoritative ledger figure.
    private var runningBalances: [String: Money] {
        guard showRunningBalance, let account, !transactions.isEmpty else { return [:] }
        var result: [String: Money] = [:]
        var balance = account.balance
        for transaction in transactions {
            result[transaction.id] = balance
            balance = balance - transaction.amount
        }
        return result
    }

    // MARK: Loading

    private func reload(preservingDepth: Bool) async {
        loadGeneration += 1
        let generation = loadGeneration
        let limit = preservingDepth ? max(Self.batchSize, transactions.count) : Self.batchSize
        if transactions.isEmpty {
            isLoading = true
        }
        let result = await store.transactions(TransactionQuery(accountID: accountID, limit: limit, offset: 0))
        guard !Task.isCancelled, generation == loadGeneration else { return }
        isLoading = false
        hasLoadedOnce = true
        hasMore = result.count >= limit
        transactions = result
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, !transactions.isEmpty else { return }
        isLoadingMore = true
        let generation = loadGeneration
        let result = await store.transactions(TransactionQuery(accountID: accountID,
                                                               limit: Self.batchSize,
                                                               offset: transactions.count))
        isLoadingMore = false
        guard !Task.isCancelled, generation == loadGeneration else { return }
        hasMore = result.count >= Self.batchSize
        let existing = Set(transactions.map(\.id))
        transactions.append(contentsOf: result.filter { !existing.contains($0.id) })
    }

    // MARK: Cleared toggle (optimistic, sequence-token guarded — LESSONS_FROM_STASHY §2)

    private func toggleCleared(_ transaction: Transaction) {
        guard !transaction.reconciled else { return }
        let newValue = !transaction.cleared
        let seq = (clearedEditSeq[transaction.id] ?? 0) + 1
        clearedEditSeq[transaction.id] = seq
        Haptics.tick()
        if let index = transactions.firstIndex(where: { $0.id == transaction.id }) {
            if reduceMotion {
                transactions[index].cleared = newValue
            } else {
                withAnimation(theme.motion.spring) {
                    transactions[index].cleared = newValue
                }
            }
        }
        Task {
            await store.setCleared(id: transaction.id, cleared: newValue)
            guard clearedEditSeq[transaction.id] == seq else { return }
            if let index = transactions.firstIndex(where: { $0.id == transaction.id }),
               transactions[index].cleared != newValue {
                transactions[index].cleared = newValue
            }
            await loadBalances()
        }
    }
}

// MARK: - AccountTransactionRow
//
// A private, file-scoped mirror of TransactionRow's visual language (cleared/reconciled
// indicator, payee, category chip, notes, colorized amount) built only from shared DesignSystem
// components — not a reuse of TransactionRow.swift, which belongs to the Transactions feature
// agent. Adds an optional trailing running-balance line under the amount.

private struct AccountTransactionRow: View {
    private let transaction: Transaction
    private let runningBalance: Money?
    private let onToggleCleared: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(transaction: Transaction, runningBalance: Money?, onToggleCleared: @escaping () -> Void) {
        self.transaction = transaction
        self.runningBalance = runningBalance
        self.onToggleCleared = onToggleCleared
    }

    var body: some View {
        HStack(spacing: theme.layout.spacing * 0.75) {
            clearedIndicator
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
            VStack(alignment: .trailing, spacing: 1) {
                AmountText(transaction.amount, style: .body)
                if let runningBalance {
                    AmountText(runningBalance, style: .caption, colorized: false)
                }
            }
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
    private var clearedIndicator: some View {
        if transaction.reconciled {
            Image(systemName: "lock")
                .font(theme.font(.caption))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textTertiary)
                .frame(width: 34, height: 44)
                .accessibilityLabel("Reconciled")
        } else {
            Button(action: onToggleCleared) {
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
            .accessibilityLabel(transaction.cleared ? "Cleared" : "Uncleared")
            .accessibilityHint("Double-tap to toggle cleared")
        }
    }
}
