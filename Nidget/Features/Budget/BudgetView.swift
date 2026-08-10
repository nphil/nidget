import SwiftUI
import Foundation

// MARK: - BudgetView
//
// The Budget tab root (ARCHITECTURE §14): a month header (chevron nav + a tappable month title
// that opens MonthPickerSheet), a To Budget hero card, and grouped envelope rows. Everything reads
// `store.monthSnapshot`/`store.categoryGroups` live — never a locally mirrored copy — so an
// in-place edit (BudgetAmountEditor / MoveMoneySheet save) is reflected immediately and
// correctly even though it doesn't change the selected month. The hero card's slide transition
// is keyed off `store.currentMonth` (synchronous on chevron tap) rather than the async
// `monthSnapshot`, so the animation fires exactly on user intent; the numbers underneath simply
// settle in place a moment later as the (typically sub-100ms local SQLite) recompute lands —
// never stale, never fabricated. Category rows animate their own amount/progress-bar changes
// independently via per-field `.animation(value:)` (CategoryRow), so both month navigation and
// same-month edits animate smoothly without a single big subtree rebuild
// (LESSONS_FROM_STASHY §1).

struct BudgetView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var incomeExpanded = false
    @State private var incomeReceivedByCategory: [String: Money] = [:]
    @State private var navDirection: MonthNavDirection = .forward
    @State private var showingMonthPicker = false

    @State private var editingRow: BudgetRowSnapshot?
    @State private var moveMoneyTarget: MoveMoneyTarget?
    @State private var categoryEditor: CategoryEditorMode?
    @State private var categoryDeleteTarget: Category?

    init() {}

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.budgetPath) {
            screenContent
                .withRouteDestinations()
        }
    }

    // MARK: Screen

    private var screenContent: some View {
        VStack(spacing: 0) {
            monthHeader
            content
        }
        .themedScreen()
        .navigationTitle("Budget")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tick()
                    router.push(.manageCategories)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .fontWeight(theme.icons.weight)
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                }
                .accessibilityLabel("Manage Categories")
            }
        }
        .task(id: store.currentMonth) { await loadIncomeReceived() }
        .sheet(item: $editingRow) { row in
            BudgetAmountEditor(row: row, month: store.currentMonth)
                .presentationDetents([.height(420)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $categoryEditor) { mode in
            CategoryEditorSheet(mode: mode)
        }
        .sheet(item: $moveMoneyTarget) { target in
            MoveMoneySheet(month: store.currentMonth, initialFromCategoryID: target.categoryID)
                .presentationDetents([.height(480), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $categoryDeleteTarget) { category in
            DeleteCategorySheet(category: category)
                .presentationDetents([.height(420), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingMonthPicker) {
            MonthPickerSheet(currentMonth: store.currentMonth) { month in
                selectMonth(month)
            }
            // Header + year stepper + a 4-row month grid need ~390pt even in the default
            // theme, and several catalog themes run wider spacing/cardPadding than that
            // (up to spacing: 16 / cardPadding: 20) — a plain .height(360) clipped the bottom
            // month row under those themes and at larger Dynamic Type sizes. .large lets a
            // drag up cover whatever a fixed height doesn't.
            .presentationDetents([.height(420), .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.monthSnapshot == nil {
            loadingView
        } else if visibleGroups.isEmpty {
            emptyView
        } else {
            budgetList
        }
    }

    private var loadingView: some View {
        ProgressView()
            .controlSize(.large)
            .tint(theme.palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        EmptyStateView(systemImage: "envelope",
                       title: "No categories yet",
                       message: "Add categories to this budget in Actual and they'll show up here.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Month header

    private var monthHeader: some View {
        VStack(spacing: theme.layout.spacing * 0.6) {
            HStack {
                navButton(systemImage: "chevron.left", label: "Previous month") { navigate(.backward) }
                Spacer()
                monthTitleButton
                Spacer()
                navButton(systemImage: "chevron.right", label: "Next month") { navigate(.forward) }
            }
        }
        .padding(.horizontal, theme.layout.cardPadding)
        .padding(.top, theme.layout.spacing * 0.5)
        .animation(reduceMotion ? nil : theme.motion.snappy, value: store.currentMonth)
    }

    private var monthTitleButton: some View {
        Button {
            Haptics.tick()
            showingMonthPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(store.currentMonth.displayName)
                    .font(theme.font(.headline))
                    .foregroundStyle(theme.palette.textPrimary)
                Image(systemName: "chevron.down")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .foregroundStyle(theme.palette.textTertiary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(store.currentMonth)
        .transition(.opacity)
        .accessibilityLabel("\(store.currentMonth.displayName). Double tap to choose a month.")
    }

    private func navButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(theme.font(.headline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private enum MonthNavDirection { case forward, backward }

    private func navigate(_ direction: MonthNavDirection) {
        Haptics.tick()
        navDirection = direction
        let newMonth = direction == .forward ? store.currentMonth.next : store.currentMonth.previous
        if reduceMotion {
            store.currentMonth = newMonth
        } else {
            withAnimation(theme.motion.spring) {
                store.currentMonth = newMonth
            }
        }
    }

    /// MonthPickerSheet reports an arbitrary target month (any year jump, not just next/previous),
    /// so this mirrors `navigate(_:)`'s animation but derives direction from a plain comparison.
    private func selectMonth(_ month: BudgetMonth) {
        guard month != store.currentMonth else { return }
        navDirection = month > store.currentMonth ? .forward : .backward
        if reduceMotion {
            store.currentMonth = month
        } else {
            withAnimation(theme.motion.spring) {
                store.currentMonth = month
            }
        }
    }

    // MARK: Hero card

    @ViewBuilder
    private var heroCard: some View {
        if let snapshot = store.monthSnapshot {
            heroContent(snapshot)
                .id(store.currentMonth)
                .transition(heroTransition)
        }
    }

    private var heroTransition: AnyTransition {
        let insertEdge: Edge = navDirection == .forward ? .trailing : .leading
        let removeEdge: Edge = navDirection == .forward ? .leading : .trailing
        return .asymmetric(insertion: .move(edge: insertEdge).combined(with: .opacity),
                           removal: .move(edge: removeEdge).combined(with: .opacity))
    }

    private func heroContent(_ snapshot: MonthBudgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            SectionHeader("To Budget")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AmountText(snapshot.toBudget, style: .display)
                if snapshot.toBudget.cents < 0 {
                    Image(systemName: "exclamationmark.triangle")
                        .font(theme.font(.headline))
                        .fontWeight(theme.icons.weight)
                        .symbolVariant(theme.icons.fill ? .fill : .none)
                        .foregroundStyle(theme.palette.warning)
                        .accessibilityLabel("Over budgeted")
                }
            }
            HStack(spacing: theme.layout.spacing * 1.5) {
                statColumn("Income", snapshot.income)
                statColumn("Budgeted", snapshot.totalBudgeted)
                statColumn("Spent", snapshot.totalSpent.magnitude)
            }
        }
        .themedCard()
    }

    private func statColumn(_ label: String, _ amount: Money) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(theme.font(.caption))
                .foregroundStyle(theme.palette.textTertiary)
            AmountText(amount, style: .caption, colorized: false)
        }
    }

    // MARK: List

    private var budgetList: some View {
        List {
            heroRow
            ForEach(nonIncomeGroups) { group in
                groupHeader(group)
                ForEach(rows(for: group)) { row in
                    categoryRowItem(row)
                }
            }
            ForEach(incomeGroups) { group in
                incomeSectionHeader(group)
                if incomeExpanded {
                    ForEach(visibleCategories(in: group)) { category in
                        incomeCategoryRow(category)
                    }
                }
            }
            newGroupRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable {
            await store.syncNow()
        }
    }

    private var rowInsets: EdgeInsets {
        EdgeInsets(top: 6, leading: theme.layout.cardPadding, bottom: 6, trailing: theme.layout.cardPadding)
    }

    private var heroRow: some View {
        heroCard
            .padding(.top, theme.layout.spacing * 0.5)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(rowInsets)
    }

    /// Tail row of the budget list: create a whole new group (categories live inside groups, so
    /// this is the other half of the "+" on each group header).
    private var newGroupRow: some View {
        Button {
            Haptics.tap()
            categoryEditor = .newGroup(isIncome: false)
        } label: {
            HStack(spacing: theme.layout.spacing * 0.75) {
                Image(systemName: "folder.badge.plus")
                    .font(theme.font(.body))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                Text("New Group")
                    .font(theme.font(.body))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.palette.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
        .padding(.top, theme.layout.spacing)
    }

    /// Trailing "+" on every group header — the discoverable place to add a category, right where
    /// that group's categories are listed.
    private func groupHeader(_ group: CategoryGroup) -> some View {
        SectionHeader(group.name, trailing: {
            AnyView(
                HStack(spacing: theme.layout.spacing * 0.75) {
                    AmountText(groupBudgetedTotal(group), style: .caption, colorized: false)
                    Button {
                        Haptics.tap()
                        categoryEditor = .newCategory(groupID: group.id)
                    } label: {
                        Image(systemName: "plus")
                            .font(theme.font(.caption))
                            .fontWeight(theme.icons.weight)
                            .foregroundStyle(theme.palette.accent)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a category to \(group.name)")
                }
            )
        })
        .padding(.top, theme.layout.spacing * 0.75)
        .animation(reduceMotion ? nil : theme.motion.spring, value: groupBudgetedTotal(group))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
    }

    private func categoryRowItem(_ row: BudgetRowSnapshot) -> some View {
        CategoryRow(row: row,
                   onEditBudgeted: { editingRow = row },
                   onTapSpent: { openSpentTransactions(row) })
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(theme.palette.separator)
            .listRowInsets(rowInsets)
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    Haptics.tick()
                    moveMoneyTarget = MoveMoneyTarget(categoryID: row.id)
                } label: {
                    Label("Move", systemImage: "arrow.left.arrow.right")
                }
                .tint(theme.palette.accent)
            }
            .contextMenu {
                categoryRowContextMenu(row)
            }
    }

    private func openSpentTransactions(_ row: BudgetRowSnapshot) {
        Haptics.tick()
        let month = store.currentMonth
        router.openTransactions(filter: TransactionQuery(categoryID: row.id, months: month...month))
    }

    // MARK: Category management shortcuts
    //
    // A fast path for the three most common edits without leaving Budget — CategoryRow is
    // cleanly extensible via this `categoryRowItem` wrapper, so the context menu lives here
    // rather than inside CategoryRow.swift itself (owned elsewhere). ManageCategoriesView remains
    // the full surface (reordering, viewing/un-hiding hidden categories and groups). Every row
    // shown here is already non-hidden (`rows(for:)` filters through `visibleCategories`), so
    // "Hide" never needs an "Unhide" counterpart in this menu.

    @ViewBuilder
    private func categoryRowContextMenu(_ row: BudgetRowSnapshot) -> some View {
        Button {
            Haptics.tap()
            categoryEditor = .rename(id: row.id, currentName: row.name, isGroup: false)
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            Haptics.tick()
            Task { await store.setCategoryHidden(id: row.id, hidden: true, isGroup: false) }
        } label: {
            Label("Hide", systemImage: "eye.slash")
        }
        let targets = otherGroups(for: row)
        if !targets.isEmpty {
            Menu {
                ForEach(targets) { group in
                    Button(group.name) {
                        Haptics.tick()
                        Task { await store.moveCategory(id: row.id, toGroup: group.id) }
                    }
                }
            } label: {
                Label("Move to Group…", systemImage: "folder")
            }
        }
        Button(role: .destructive) {
            Haptics.tap()
            categoryDeleteTarget = store.categoryGroups
                .flatMap(\.categories)
                .first(where: { $0.id == row.id })
        } label: {
            Label("Delete…", systemImage: "trash")
        }
    }

    /// Other groups sharing `row`'s income-ness — the only legal `moveCategory` targets.
    private func otherGroups(for row: BudgetRowSnapshot) -> [CategoryGroup] {
        store.categoryGroups.filter { $0.isIncome == row.isIncome && $0.id != row.groupID }
    }

    // MARK: Income section

    private func incomeSectionHeader(_ group: CategoryGroup) -> some View {
        Button {
            Haptics.tick()
            if reduceMotion {
                incomeExpanded.toggle()
            } else {
                withAnimation(theme.motion.snappy) { incomeExpanded.toggle() }
            }
        } label: {
            SectionHeader(group.name, trailing: {
                AnyView(
                    HStack(spacing: 6) {
                        AmountText(incomeGroupTotal(group), style: .caption, colorized: false)
                        Image(systemName: "chevron.right")
                            .font(theme.font(.caption))
                            .fontWeight(theme.icons.weight)
                            .rotationEffect(.degrees(incomeExpanded ? 90 : 0))
                            .foregroundStyle(theme.palette.textTertiary)
                    }
                )
            })
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, theme.layout.spacing * 0.75)
        .animation(reduceMotion ? nil : theme.motion.snappy, value: incomeExpanded)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(rowInsets)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(incomeExpanded ? "Double-tap to collapse" : "Double-tap to expand")
    }

    private func incomeCategoryRow(_ category: Category) -> some View {
        HStack {
            Text(category.name)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer()
            AmountText(incomeReceivedByCategory[category.id] ?? .zero, style: .body)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tick()
            let month = store.currentMonth
            router.openTransactions(filter: TransactionQuery(categoryID: category.id, months: month...month))
        }
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(theme.palette.separator)
        .listRowInsets(rowInsets)
    }

    // MARK: Grouping & totals

    private var visibleGroups: [CategoryGroup] {
        store.categoryGroups.filter { !$0.hidden }
    }

    private var nonIncomeGroups: [CategoryGroup] {
        visibleGroups.filter { !$0.isIncome }
    }

    private var incomeGroups: [CategoryGroup] {
        visibleGroups.filter { $0.isIncome }
    }

    private func visibleCategories(in group: CategoryGroup) -> [Category] {
        group.categories.filter { !$0.hidden }
    }

    private func rows(for group: CategoryGroup) -> [BudgetRowSnapshot] {
        guard let snapshot = store.monthSnapshot else { return [] }
        var byID: [String: BudgetRowSnapshot] = [:]
        for row in snapshot.rows { byID[row.id] = row }
        return visibleCategories(in: group).compactMap { byID[$0.id] }
    }

    private func groupBudgetedTotal(_ group: CategoryGroup) -> Money {
        rows(for: group).reduce(Money.zero) { $0 + $1.budgeted }
    }

    private func incomeGroupTotal(_ group: CategoryGroup) -> Money {
        visibleCategories(in: group).reduce(Money.zero) { partial, category in
            partial + (incomeReceivedByCategory[category.id] ?? .zero)
        }
    }

    // MARK: Income received (no per-category figure lives in MonthBudgetSnapshot — income rows
    // are structural-only there per BudgetCalculator's contract — so this aggregates the
    // month's transactions once per month change through the existing `transactions(_:)` API.)

    private func loadIncomeReceived() async {
        let incomeCategoryIDs = Set(incomeGroups.flatMap { visibleCategories(in: $0).map(\.id) })
        guard !incomeCategoryIDs.isEmpty else {
            incomeReceivedByCategory = [:]
            return
        }
        let month = store.currentMonth
        let query = TransactionQuery(months: month...month, limit: 1000)
        let transactions = await store.transactions(query)
        guard !Task.isCancelled, store.currentMonth == month else { return }
        var totals: [String: Money] = [:]
        for transaction in transactions {
            guard let categoryID = transaction.categoryID,
                  incomeCategoryIDs.contains(categoryID),
                  transaction.transferID == nil else { continue }
            totals[categoryID, default: .zero] += transaction.amount
        }
        incomeReceivedByCategory = totals
    }
}

// MARK: - MoveMoneyTarget

/// Sheet-routing token for `MoveMoneySheet` (ARCHITECTURE §16 pattern: `.sheet(item:)` over
/// `.sheet(isPresented:)` when the state represents a selection). `categoryID` is the swiped
/// row's category, preloaded as the move's `from` side.
private struct MoveMoneyTarget: Identifiable {
    let id = UUID()
    let categoryID: String?
}
