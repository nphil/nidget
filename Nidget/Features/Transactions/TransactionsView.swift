import SwiftUI

// MARK: - TransactionsView
//
// The Transactions tab root (ARCHITECTURE §14): a searchable list grouped by day, 100-per-batch
// infinite paging with a sentinel on the last row, pull-to-refresh through `syncNow`, and
// leading/trailing swipe actions. Search binds into `TransactionQuery.search` after a 300ms
// `.task(id:)` debounce; deep links land through `router.pendingTransactionFilter`. Cleared
// toggles are optimistic with a per-id sequence token (LESSONS §2) so rapid taps and racing
// reloads can't snap the dot back.
//
// Account and Uncategorized filters live in one toolbar menu, not in a row above the list: a long
// account list scrolls inside a native menu instead of sideways off the screen, and with nothing
// between the navigation bar and the List the rows scroll up under the bar and fade there, the
// same as Budget, Retire and Settings. The menu icon fills and turns accent while any filter is on.

struct TransactionsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Filters
    @State private var searchText = ""
    @State private var debouncedSearch = ""
    @State private var accountFilter = ""          // "" = All
    @State private var uncategorizedOnly = false
    @State private var categoryFilter: String?     // deep-link only (Budget "spent" taps)
    @State private var payeeFilter: String?        // deep-link only
    @State private var monthsFilter: ClosedRange<BudgetMonth>?  // deep-link only

    // Data
    @State private var transactions: [Transaction] = []
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var hasMore = true
    @State private var hasLoadedOnce = false
    @State private var loadGeneration = 0
    @State private var loadedFilterKey: TransactionFilterKey?

    // Edits
    @State private var clearedEditSeq: [String: Int] = [:]
    @State private var pendingDelete: Transaction?
    @State private var showDeleteConfirm = false

    // Semantic search (docs/AI.md §3) — strong index matches shown after the substring
    // results. Always empty when AI is off or no embedding model is installed.
    @State private var relatedTransactions: [Transaction] = []
    @State private var isLoadingRelated = false

    private static let batchSize = 100

    init() {}

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.transactionsPath) {
            screenContent
                .withRouteDestinations()
        }
    }

    // MARK: Screen

    private var screenContent: some View {
        listWithDeepLinkFilter
            .themedScreen()
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    filterMenu
                }
            }
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Payee or notes")
            .task(id: searchText) { await debounceSearch() }
            .task(id: router.pendingTransactionFilter != nil) { consumePendingFilter() }
            .task(id: filterKey) {
                let preserve = loadedFilterKey == filterKey
                await reload(preservingDepth: preserve)
            }
            .task(id: semanticKey) { await refreshRelated() }
            .onChange(of: router.quickAddPresented) { _, presented in
                if !presented {
                    Task { await reload(preservingDepth: true) }
                }
            }
            .onChange(of: router.transactionsPath.count) { oldCount, newCount in
                if newCount < oldCount {
                    Task { await reload(preservingDepth: true) }
                }
            }
            .confirmationDialog("Delete this transaction?",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible,
                                presenting: pendingDelete) { transaction in
                Button("Delete Transaction", role: .destructive) { performDelete(transaction) }
                Button("Keep It", role: .cancel) { }
            } message: { transaction in
                Text(deleteMessage(for: transaction))
            }
    }

    // MARK: Filters
    //
    // Account and Uncategorized used to be a horizontal row of chips above the List (UX_ROUND2
    // §4). Two things were wrong with that: the account chips grew into a long sideways list that
    // hid most accounts off-screen, and the row itself sat between the navigation bar and the
    // List, so nothing ever scrolled under the bar and the screen never got the scroll edge fade.
    // Both filters now live in one toolbar menu. Menu rows are native and built lazily, so any
    // number of accounts is fine, they read top to bottom like every other iOS filter, and the
    // List is free to be the whole screen.
    //
    // The menu writes exactly the state the chips wrote, so `filterKey` and the `.task(id:)`
    // reload path are untouched.

    private var filterMenu: some View {
        Menu {
            Picker("Account", selection: accountFilterBinding) {
                Text("All Accounts").tag("")
                ForEach(openAccounts) { account in
                    Text(account.name).tag(account.id)
                }
            }
            .pickerStyle(.inline)
            Toggle(isOn: uncategorizedOnlyBinding) {
                Label("Uncategorized only", systemImage: "questionmark.circle")
            }
            .tint(theme.palette.warning)
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .fontWeight(theme.icons.weight)
                .symbolVariant(hasActiveFilter ? .fill : (theme.icons.fill ? .fill : .none))
                .foregroundStyle(hasActiveFilter ? theme.palette.accent : theme.palette.textSecondary)
        }
        .accessibilityLabel(filterMenuLabel)
    }

    private var filterMenuLabel: String {
        hasActiveFilter ? "Filters, on" : "Filters"
    }

    private var openAccounts: [Account] {
        store.accounts.filter { !$0.closed }
    }

    /// True when anything the menu or the deep-link chip represents is narrowing the list. Drives
    /// the toolbar icon's filled/accent state; search has its own visible field, so it stays out.
    private var hasActiveFilter: Bool {
        !accountFilter.isEmpty || uncategorizedOnly || hasExternalFilter
    }

    private var accountFilterBinding: Binding<String> {
        Binding(get: { accountFilter },
                set: { newValue in
                    guard newValue != accountFilter else { return }
                    Haptics.tick()
                    accountFilter = newValue
                })
    }

    private var uncategorizedOnlyBinding: Binding<Bool> {
        Binding(get: { uncategorizedOnly },
                set: { newValue in
                    guard newValue != uncategorizedOnly else { return }
                    Haptics.tick()
                    uncategorizedOnly = newValue
                })
    }

    /// A deep link (Budget "spent" tap, a payee, a month) can filter by things the menu has no
    /// control for. Only then does the clearable chip appear.
    private var hasExternalFilter: Bool {
        categoryFilter != nil || payeeFilter != nil || monthsFilter != nil
    }

    private var externalFilterChip: some View {
        Button {
            Haptics.tick()
            if reduceMotion {
                clearExternalFilter()
            } else {
                withAnimation(theme.motion.snappy) { clearExternalFilter() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                Text(externalFilterLabel)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
            }
            .font(theme.font(.subheadline))
            .foregroundStyle(theme.palette.onAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.palette.accent))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear filter: \(externalFilterLabel)")
    }

    private var externalFilterLabel: String {
        var parts: [String] = []
        if let categoryFilter {
            let name = store.categoryName(categoryFilter)
            parts.append(name.isEmpty ? "Category" : name)
        }
        if let payeeFilter {
            let name = store.payeeName(payeeFilter)
            parts.append(name.isEmpty ? "Payee" : name)
        }
        if let monthsFilter {
            if monthsFilter.lowerBound == monthsFilter.upperBound {
                parts.append(monthsFilter.lowerBound.displayName)
            } else {
                parts.append("\(monthsFilter.lowerBound.compactName) – \(monthsFilter.upperBound.compactName)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func clearExternalFilter() {
        categoryFilter = nil
        payeeFilter = nil
        monthsFilter = nil
    }

    // MARK: List

    /// The List is the screen. The deep-link chip is the one thing that can still sit above it,
    /// and only while such a filter is on — the branch, rather than an always-present container,
    /// keeps the plain case a bare List hanging straight off the navigation bar. Switching
    /// branches costs nothing: arriving at or clearing a deep-link filter reloads the run anyway.
    @ViewBuilder
    private var listWithDeepLinkFilter: some View {
        if hasExternalFilter {
            VStack(spacing: 0) {
                externalFilterBar
                transactionList
            }
        } else {
            transactionList
        }
    }

    private var externalFilterBar: some View {
        externalFilterChip
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, theme.layout.cardPadding)
            .padding(.vertical, theme.layout.spacing * 0.5)
    }

    private var transactionList: some View {
        List {
            if transactions.isEmpty && !isLoading && hasLoadedOnce {
                emptyRow
                relatedRows   // semantic hits can exist even when substring search found nothing
            } else {
                ForEach(daySections) { section in
                    dayHeaderRow(section.day)
                    ForEach(section.items) { transaction in
                        row(transaction)
                    }
                }
                if isLoadingMore {
                    loadingMoreRow
                }
                relatedRows
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.syncNow()
            await reload(preservingDepth: true)
        }
        .overlay { initialLoadingOverlay }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 6, leading: theme.layout.cardPadding,
                   bottom: 6, trailing: theme.layout.cardPadding)
    }

    private func dayHeaderRow(_ day: BudgetDay) -> some View {
        SectionHeader(day.relativeDisplay)
            .padding(.top, theme.layout.spacing * 0.5)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(rowInsets)
    }

    private func row(_ transaction: Transaction) -> some View {
        TransactionRow(transaction: transaction,
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
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    pendingDelete = transaction
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(theme.palette.negative)
                Button {
                    router.push(.transactionDetail(transaction.id))
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(theme.palette.accentSecondary)
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
        Group {
            if isFiltered {
                EmptyStateView(systemImage: "magnifyingglass",
                               title: "Nothing matches",
                               message: "No transactions fit that filter. Loosen the net and cast again.",
                               actionTitle: "Clear Filters",
                               action: clearAllFilters)
            } else {
                EmptyStateView(systemImage: "sparkles",
                               title: "A fresh ledger",
                               message: "Nothing logged yet. Tap the plus button and give this budget its first heartbeat.",
                               actionTitle: "Add Transaction",
                               action: { router.quickAddPresented = true })
            }
        }
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

    // MARK: Related (semantic) matches — docs/AI.md §3

    /// Non-empty exactly when hybrid semantic search should run: the preference is on, an
    /// embedding model is ready, and there is settled search text. Empty key = the list is
    /// exactly the stock substring experience.
    private var semanticKey: String {
        guard preferences.aiSemanticSearch,
              CategorySuggestionService.shared.embeddingReady,
              !debouncedSearch.isEmpty else { return "" }
        return debouncedSearch
    }

    /// Embed the query, pull strong neighbours (similarity ≥ 0.55) from the index, and
    /// resolve them to full rows. Substring results are untouched; overlap is filtered out
    /// at render time so paging can never duplicate a row.
    private func refreshRelated() async {
        guard !semanticKey.isEmpty else {
            isLoadingRelated = false
            if !relatedTransactions.isEmpty { relatedTransactions = [] }
            return
        }
        isLoadingRelated = true
        let hits = await EmbeddingIndex.shared.nearest(to: semanticKey, limit: 40)
        guard !Task.isCancelled else { return }
        let strongIDs = hits.filter { $0.similarity >= 0.55 }.map { $0.txID }
        guard !strongIDs.isEmpty else {
            isLoadingRelated = false
            relatedTransactions = []
            return
        }
        let rows = await CategorySuggestionService.shared.transactions(matching: strongIDs)
        guard !Task.isCancelled else { return }
        isLoadingRelated = false
        relatedTransactions = rows
    }

    /// Related rows actually shown: semantic hits minus anything the substring list already
    /// shows, still honoring the visible filter bar so the section never contradicts it.
    private var visibleRelated: [Transaction] {
        guard !relatedTransactions.isEmpty else { return [] }
        let shownIDs = Set(transactions.map(\.id))
        return relatedTransactions.filter { transaction in
            if shownIDs.contains(transaction.id) { return false }
            if !accountFilter.isEmpty && transaction.accountID != accountFilter { return false }
            if uncategorizedOnly && transaction.categoryID != nil { return false }
            if let categoryFilter, transaction.categoryID != categoryFilter { return false }
            if let payeeFilter, transaction.payeeID != payeeFilter { return false }
            if let monthsFilter, !monthsFilter.contains(transaction.date.month) { return false }
            return true
        }
    }

    @ViewBuilder
    private var relatedRows: some View {
        if isLoadingRelated {
            relatedLoadingRow
        } else if !visibleRelated.isEmpty {
            relatedHeaderRow
            ForEach(visibleRelated) { transaction in
                row(transaction)
            }
        }
    }

    private var relatedHeaderRow: some View {
        SectionHeader("Related", trailing: {
            AnyView(
                Image(systemName: "sparkles")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accent)
            )
        })
        .padding(.top, theme.layout.spacing * 0.5)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
    }

    /// Tiny inline spinner shown while the query embeds and the index is searched.
    private var relatedLoadingRow: some View {
        HStack {
            Spacer()
            ProgressView()
                .controlSize(.mini)
                .tint(theme.palette.accent)
            Spacer()
        }
        .frame(minHeight: 28)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: Day grouping

    private struct DaySection: Identifiable {
        let day: BudgetDay
        var items: [Transaction]
        var id: Int { day.raw }
    }

    /// Groups the loaded page run by day, preserving the query's newest-first order.
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

    // MARK: Filters & query

    private var filterKey: TransactionFilterKey {
        TransactionFilterKey(search: debouncedSearch,
                             accountID: accountFilter,
                             uncategorized: uncategorizedOnly,
                             categoryID: categoryFilter,
                             payeeID: payeeFilter,
                             months: monthsFilter)
    }

    private var isFiltered: Bool {
        !debouncedSearch.isEmpty || !accountFilter.isEmpty || uncategorizedOnly || hasExternalFilter
    }

    private func query(limit: Int, offset: Int) -> TransactionQuery {
        TransactionQuery(accountID: accountFilter.isEmpty ? nil : accountFilter,
                         categoryID: categoryFilter,
                         payeeID: payeeFilter,
                         search: debouncedSearch.isEmpty ? nil : debouncedSearch,
                         months: monthsFilter,
                         onlyUncategorized: uncategorizedOnly,
                         limit: limit,
                         offset: offset)
    }

    /// 300ms debounce from the live search field into the query term (LESSONS §1).
    private func debounceSearch() async {
        guard searchText != debouncedSearch else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        debouncedSearch = searchText
    }

    /// Applies a deep-linked filter from `router.openTransactions(filter:)`, then clears it.
    /// Pops to the root list first — the filter lands on this screen, which may be sitting
    /// under previously pushed detail views.
    private func consumePendingFilter() {
        guard let pending = router.pendingTransactionFilter else { return }
        if !router.transactionsPath.isEmpty {
            router.transactionsPath = NavigationPath()
        }
        searchText = pending.search ?? ""
        debouncedSearch = searchText
        accountFilter = pending.accountID ?? ""
        uncategorizedOnly = pending.onlyUncategorized
        categoryFilter = pending.categoryID
        payeeFilter = pending.payeeID
        monthsFilter = pending.months
        router.pendingTransactionFilter = nil
    }

    private func clearAllFilters() {
        Haptics.tick()
        let apply = {
            searchText = ""
            debouncedSearch = ""
            accountFilter = ""
            uncategorizedOnly = false
            clearExternalFilter()
        }
        if reduceMotion {
            apply()
        } else {
            withAnimation(theme.motion.snappy) { apply() }
        }
    }

    // MARK: Loading

    /// Replaces the loaded run for the current filter. `preservingDepth` re-queries as many
    /// rows as were already showing (refresh/sync paths) instead of resetting to one batch.
    /// A generation token discards results a newer load has superseded (LESSONS §1).
    private func reload(preservingDepth: Bool) async {
        let key = filterKey
        loadGeneration += 1
        let generation = loadGeneration
        let limit = preservingDepth ? max(Self.batchSize, transactions.count) : Self.batchSize
        if transactions.isEmpty {
            isLoading = true
        }
        let result = await store.transactions(query(limit: limit, offset: 0))
        guard !Task.isCancelled, generation == loadGeneration else { return }
        isLoading = false
        hasLoadedOnce = true
        loadedFilterKey = key
        hasMore = result.count >= limit
        transactions = result
    }

    private func loadMore() async {
        guard hasMore, !isLoadingMore, !transactions.isEmpty else { return }
        isLoadingMore = true
        let generation = loadGeneration
        let result = await store.transactions(query(limit: Self.batchSize,
                                                    offset: transactions.count))
        isLoadingMore = false
        guard !Task.isCancelled, generation == loadGeneration else { return }
        hasMore = result.count >= Self.batchSize
        let existing = Set(transactions.map(\.id))
        transactions.append(contentsOf: result.filter { !existing.contains($0.id) })
    }

    // MARK: Cleared toggle (optimistic, sequence-token guarded)

    private func toggleCleared(_ transaction: Transaction) {
        guard !transaction.reconciled else { return }
        let newValue = !transaction.cleared
        let seq = (clearedEditSeq[transaction.id] ?? 0) + 1
        clearedEditSeq[transaction.id] = seq
        Haptics.tick()
        if reduceMotion {
            applyClearedLocally(id: transaction.id, cleared: newValue)
        } else {
            withAnimation(theme.motion.spring) {
                applyClearedLocally(id: transaction.id, cleared: newValue)
            }
        }
        Task {
            await store.setCleared(id: transaction.id, cleared: newValue)
            // Only the latest edit for this id may touch state afterward — an older,
            // slower write must not clobber a newer toggle (LESSONS §2).
            guard clearedEditSeq[transaction.id] == seq else { return }
            applyClearedLocally(id: transaction.id, cleared: newValue)
        }
    }

    /// Writes a cleared value into every local copy of the row (the substring run AND the
    /// semantic Related section, which hold separate value snapshots of the same id).
    private func applyClearedLocally(id: String, cleared: Bool) {
        if let index = transactions.firstIndex(where: { $0.id == id }),
           transactions[index].cleared != cleared {
            transactions[index].cleared = cleared
        }
        if let index = relatedTransactions.firstIndex(where: { $0.id == id }),
           relatedTransactions[index].cleared != cleared {
            relatedTransactions[index].cleared = cleared
        }
    }

    // MARK: Delete

    private func deleteMessage(for transaction: Transaction) -> String {
        let payee = store.payeeName(transaction.payeeID)
        let subject = payee.isEmpty ? "This transaction" : "The \(payee) transaction"
        return "\(subject) disappears from every synced device. There's no undo."
    }

    private func performDelete(_ transaction: Transaction) {
        Haptics.warning()
        if reduceMotion {
            transactions.removeAll { $0.id == transaction.id }
            relatedTransactions.removeAll { $0.id == transaction.id }
        } else {
            withAnimation(theme.motion.spring) {
                transactions.removeAll { $0.id == transaction.id }
                relatedTransactions.removeAll { $0.id == transaction.id }
            }
        }
        pendingDelete = nil
        Task {
            await store.deleteTransaction(id: transaction.id)
        }
    }
}

// MARK: - TransactionFilterKey

/// Equatable snapshot of every list-affecting filter — the `.task(id:)` key that drives
/// reloads, and the marker for "this run already matches the current filter".
private struct TransactionFilterKey: Hashable {
    var search: String
    var accountID: String
    var uncategorized: Bool
    var categoryID: String?
    var payeeID: String?
    var months: ClosedRange<BudgetMonth>?
}
