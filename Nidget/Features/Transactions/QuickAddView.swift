import SwiftUI

// MARK: - QuickAddView
//
// The daily-driver capture sheet (ARCHITECTURE §14): opens straight on the amount keypad with a
// hero amount that ticks as digits land, an expense/income sign toggle, a payee field with live
// suggestions that auto-fill the category, a top-6 category chip row, a tap-to-cycle account
// row, and Today/Yesterday/calendar date chips. Save is one full-width primary button that
// celebrates with a bouncing checkmark and dismisses itself. Presented by RootView as a sheet
// at the 560pt detent; everything actionable sits in thumb reach above the keypad.

struct QuickAddView: View {
    @Environment(AppStore.self) private var store
    @Environment(Preferences.self) private var preferences
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    // Entry state
    @State private var magnitude: Money = .zero
    @State private var isExpense = true
    @State private var payeeText = ""
    @State private var payeeID: String?
    @State private var categoryID: String?
    @State private var userPickedCategory = false
    @State private var selectedAccountID: String?
    @State private var date: BudgetDay = .today

    // Presentation state
    @State private var topCategoryIDs: [String] = []
    @State private var preSheetCategoryID: String?
    @State private var showCategorySheet = false
    @State private var showDatePicker = false
    @State private var isSaving = false
    @State private var showSaved = false

    init() {}

    var body: some View {
        ZStack {
            if hasUsableAccounts {
                content
            } else {
                noAccountsState
            }
        }
        .themedScreen()
        .overlay { savedOverlay }
        .sheet(isPresented: $showCategorySheet, onDismiss: {
            if categoryID != preSheetCategoryID {
                userPickedCategory = true
            }
        }) {
            CategoryPickerSheet(categoryID: $categoryID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDatePicker) {
            TransactionDatePickerSheet(day: $date)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Layout

    private var content: some View {
        VStack(spacing: theme.layout.spacing) {
            heroRow
            middleScroll
            AmountKeypad(amount: $magnitude, allowsSign: false)
            saveButton
        }
        .padding(.horizontal, theme.layout.cardPadding)
        .padding(.top, theme.layout.spacing)
        .padding(.bottom, theme.layout.spacing * 0.75)
        .task {
            configureDefaultAccount()
            await loadTopCategories()
        }
    }

    private var heroRow: some View {
        HStack(alignment: .center, spacing: theme.layout.spacing) {
            AmountText(signedAmount, style: .hero, colorized: true, showSign: true)
            Spacer(minLength: theme.layout.spacing * 0.5)
            SignToggle(isExpense: $isExpense)
                .fixedSize()
        }
    }

    private var middleScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                PayeeField(text: $payeeText, payeeID: $payeeID,
                           onSuggestionPicked: handleSuggestion)
                categoryChipRow
                accountRow
                dateChipRow
            }
            .padding(.bottom, 2)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .frame(maxHeight: .infinity)
    }

    private var signedAmount: Money {
        isExpense ? magnitude.negated : magnitude
    }

    // MARK: Category chips

    private var categoryChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(displayCategoryIDs, id: \.self) { id in
                    categoryChip(id)
                }
                allCategoriesChip
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    /// Top-6 usage chips, with an out-of-band selection (from a suggestion or the sheet)
    /// surfaced as an extra leading chip so the active category is always visible.
    private var displayCategoryIDs: [String] {
        guard let selected = categoryID,
              !topCategoryIDs.contains(selected),
              !store.categoryName(selected).isEmpty else {
            return topCategoryIDs
        }
        return [selected] + topCategoryIDs
    }

    private func categoryChip(_ id: String) -> some View {
        let isSelected = categoryID == id
        return Button {
            Haptics.tick()
            userPickedCategory = true
            if reduceMotion {
                categoryID = isSelected ? nil : id
            } else {
                withAnimation(theme.motion.snappy) {
                    categoryID = isSelected ? nil : id
                }
            }
        } label: {
            Text(store.categoryName(id))
                .font(theme.font(.subheadline))
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? theme.palette.onAccent : theme.palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? theme.palette.accent : theme.palette.fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var allCategoriesChip: some View {
        Button {
            preSheetCategoryID = categoryID
            showCategorySheet = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                Text("All")
            }
            .font(theme.font(.subheadline))
            .foregroundStyle(theme.palette.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(theme.palette.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("All categories")
    }

    private func handleSuggestion(_ suggestion: PayeeSuggestion) {
        guard !userPickedCategory,
              let auto = suggestion.categoryID,
              !store.categoryName(auto).isEmpty else { return }
        if reduceMotion {
            categoryID = auto
        } else {
            withAnimation(theme.motion.snappy) { categoryID = auto }
        }
    }

    // MARK: Account row

    private var accountRow: some View {
        Button {
            cycleAccount()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "building.columns")
                    .font(theme.font(.body))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                    .foregroundStyle(theme.palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Account")
                        .font(theme.font(.label))
                        .foregroundStyle(theme.palette.textTertiary)
                        .textCase(theme.typography.labelCase)
                        .tracking(theme.typography.labelTracking)
                    Text(selectedAccountName)
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                }
                Spacer()
                if cycleAccountsList.count > 1 {
                    Image(systemName: "arrow.2.squarepath")
                        .font(theme.font(.caption))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: 52)
            .background(theme.controlShape.fill(theme.palette.fill))
            .contentShape(theme.controlShape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account: \(selectedAccountName)")
        .accessibilityHint(cycleAccountsList.count > 1 ? "Double-tap to switch accounts" : "")
    }

    private var selectedAccountName: String {
        guard let id = selectedAccountID,
              let account = store.accounts.first(where: { $0.id == id }) else {
            return "Pick an account"
        }
        return account.name
    }

    /// Open on-budget accounts; falls back to any open account when none are on-budget.
    private var cycleAccountsList: [Account] {
        let open = store.accounts.filter { !$0.closed }
        let onBudget = open.filter { !$0.offBudget }
        return onBudget.isEmpty ? open : onBudget
    }

    private var hasUsableAccounts: Bool {
        store.accounts.contains { !$0.closed }
    }

    private func cycleAccount() {
        let list = cycleAccountsList
        guard !list.isEmpty else { return }
        Haptics.tick()
        guard let current = selectedAccountID,
              let index = list.firstIndex(where: { $0.id == current }) else {
            selectedAccountID = list.first?.id
            return
        }
        let next = list[(index + 1) % list.count]
        if reduceMotion {
            selectedAccountID = next.id
        } else {
            withAnimation(theme.motion.snappy) { selectedAccountID = next.id }
        }
    }

    private func configureDefaultAccount() {
        guard selectedAccountID == nil else { return }
        let open = store.accounts.filter { !$0.closed }
        if let preferred = preferences.defaultAccountID,
           open.contains(where: { $0.id == preferred }) {
            selectedAccountID = preferred
        } else {
            selectedAccountID = (open.first(where: { !$0.offBudget }) ?? open.first)?.id
        }
    }

    // MARK: Date chips

    private var dateChipRow: some View {
        HStack(spacing: 8) {
            dateChip("Today", day: .today)
            dateChip("Yesterday", day: BudgetDay.today.addingDays(-1))
            calendarChip
            Spacer(minLength: 0)
        }
    }

    private func dateChip(_ title: String, day: BudgetDay) -> some View {
        let isSelected = date == day
        return Button {
            Haptics.tick()
            if reduceMotion {
                date = day
            } else {
                withAnimation(theme.motion.snappy) { date = day }
            }
        } label: {
            Text(title)
                .font(theme.font(.subheadline))
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? theme.palette.onAccent : theme.palette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(isSelected ? theme.palette.accent : theme.palette.fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var calendarChip: some View {
        let isCustom = date != .today && date != BudgetDay.today.addingDays(-1)
        return Button {
            showDatePicker = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(theme.font(.caption))
                    .fontWeight(theme.icons.weight)
                    .symbolVariant(theme.icons.fill ? .fill : .none)
                Text(isCustom ? date.shortDisplay : "Pick")
            }
            .font(theme.font(.subheadline))
            .fontWeight(isCustom ? .semibold : .regular)
            .foregroundStyle(isCustom ? theme.palette.onAccent : theme.palette.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(isCustom ? theme.palette.accent : theme.palette.fill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCustom ? "Date: \(date.relativeDisplay)" : "Pick a date")
    }

    // MARK: Save

    private var canSave: Bool {
        magnitude != .zero && selectedAccountID != nil && !isSaving
    }

    private var saveButton: some View {
        NidgetButton("Save Transaction", systemImage: "checkmark", role: .primary) {
            save()
        }
        .disabled(!canSave)
        .opacity(canSave ? 1 : 0.55)
        .animation(reduceMotion ? nil : theme.motion.snappy, value: canSave)
        .accessibilityHint(canSave ? "Saves the transaction" : "Enter an amount first")
    }

    private func save() {
        guard canSave, let accountID = selectedAccountID else { return }
        isSaving = true
        let trimmedPayee = payeeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = TransactionDraft(accountID: accountID,
                                     amount: signedAmount,
                                     date: date,
                                     payeeID: payeeID,
                                     newPayeeName: (payeeID == nil && !trimmedPayee.isEmpty) ? trimmedPayee : nil,
                                     categoryID: categoryID,
                                     notes: nil,
                                     cleared: true)
        Task {
            await store.addTransaction(draft)
            Haptics.success()
            if reduceMotion {
                showSaved = true
            } else {
                withAnimation(theme.motion.emphasis) { showSaved = true }
            }
            try? await Task.sleep(for: .milliseconds(450))
            dismiss()
        }
    }

    // MARK: Saved overlay

    @ViewBuilder
    private var savedOverlay: some View {
        ZStack {
            if showSaved {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                VStack(spacing: theme.layout.spacing * 0.75) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(theme.font(.hero))
                        .fontWeight(theme.icons.weight)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(theme.palette.positive)
                        .symbolEffect(.bounce, options: .nonRepeating,
                                      value: reduceMotion ? false : showSaved)
                    Text("Saved")
                        .font(theme.font(.title))
                        .foregroundStyle(theme.palette.textPrimary)
                }
                .transition(reduceMotion
                            ? .opacity
                            : .scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .allowsHitTesting(showSaved)
        .accessibilityHidden(!showSaved)
    }

    // MARK: Empty state

    private var noAccountsState: some View {
        EmptyStateView(systemImage: "building.columns",
                       title: "No accounts yet",
                       message: "Quick Add needs an account to land in. Add one in Actual, sync, and come right back.",
                       actionTitle: "Close",
                       action: { dismiss() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Top categories

    /// Top 6 categories by recent usage, topped up with the budget's first visible
    /// spending categories when history is thin.
    private func loadTopCategories() async {
        guard topCategoryIDs.isEmpty else { return }
        let orderedValidIDs: [String] = store.categoryGroups
            .filter { !$0.hidden && !$0.isIncome }
            .flatMap { $0.categories.filter { !$0.hidden }.map(\.id) }
        let validSet = Set(orderedValidIDs)
        let recents = await store.recentTransactions(limit: 250)
        guard !Task.isCancelled else { return }

        var counts: [String: Int] = [:]
        for transaction in recents {
            if let id = transaction.categoryID, validSet.contains(id) {
                counts[id, default: 0] += 1
            }
        }
        var top = counts
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
            }
            .map(\.key)
        if top.count < 6 {
            for id in orderedValidIDs where !top.contains(id) {
                top.append(id)
                if top.count >= 6 { break }
            }
        }
        topCategoryIDs = Array(top.prefix(6))
    }
}

// MARK: - SignToggle

/// Expense/income segmented toggle. Two fixed capsule segments; the accent selection slides
/// between them (matchedGeometryEffect), instant under Reduce Motion.
private struct SignToggle: View {
    @Binding var isExpense: Bool

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var toggleNamespace

    var body: some View {
        HStack(spacing: 4) {
            segment("Expense", active: isExpense) { set(expense: true) }
            segment("Income", active: !isExpense) { set(expense: false) }
        }
        .padding(4)
        .background(Capsule().fill(theme.palette.fill))
        .accessibilityElement(children: .contain)
    }

    private func set(expense: Bool) {
        guard expense != isExpense else { return }
        Haptics.tick()
        if reduceMotion {
            isExpense = expense
        } else {
            withAnimation(theme.motion.snappy) { isExpense = expense }
        }
    }

    private func segment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.font(.subheadline))
                .fontWeight(active ? .semibold : .regular)
                .foregroundStyle(active ? theme.palette.onAccent : theme.palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if active {
                        Capsule()
                            .fill(theme.palette.accent)
                            .matchedGeometryEffect(id: "sign.selection", in: toggleNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

// MARK: - TransactionDatePickerSheet

/// Graphical calendar sheet shared by Quick Add and the transaction editor. Picking a day
/// writes the binding and dismisses; the Done button covers the "keep the shown day" case.
struct TransactionDatePickerSheet: View {
    @Binding private var day: BudgetDay

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDate: Date

    init(day: Binding<BudgetDay>) {
        self._day = day
        self._selectedDate = State(initialValue: day.wrappedValue.date)
    }

    var body: some View {
        VStack(spacing: theme.layout.spacing * 0.5) {
            HStack {
                Text("Date")
                    .font(theme.font(.title))
                    .foregroundStyle(theme.palette.textPrimary)
                Spacer()
                Button {
                    commit()
                } label: {
                    Text("Done")
                        .font(theme.font(.headline))
                        .foregroundStyle(theme.palette.accent)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            DatePicker("Transaction date", selection: $selectedDate, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(theme.palette.accent)
            Spacer(minLength: 0)
        }
        .padding(theme.layout.cardPadding)
        .themedScreen()
        .onChange(of: selectedDate) { _, newValue in
            Haptics.tick()
            day = BudgetDay(date: newValue)
            dismiss()
        }
    }

    private func commit() {
        day = BudgetDay(date: selectedDate)
        dismiss()
    }
}
