import SwiftUI

// MARK: - TransactionDetailView
//
// Editable form for one transaction, pushed via `Route.transactionDetail(id)`. There is no
// single-id fetch on AppStore, so the transaction is located by paging broad
// `TransactionQuery` batches (newest first) until the id turns up — bounded, and instant for
// anything recent. Fields reuse the Quick Add pieces: AmountKeypad in an expanding section,
// PayeeField with suggestions, CategoryPickerSheet, an account menu, the shared graphical
// date sheet, notes, and a cleared toggle (reconciled rows show a lock instead).

struct TransactionDetailView: View {
    private let transactionID: String

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    private enum LoadPhase {
        case loading, missing, ready
    }

    @State private var phase: LoadPhase = .loading
    @State private var original: Transaction?

    // Editable fields
    @State private var amount: Money = .zero
    @State private var payeeText = ""
    @State private var payeeID: String?
    @State private var categoryID: String?
    @State private var accountID = ""
    @State private var date: BudgetDay = .today
    @State private var notes = ""
    @State private var cleared = true
    @State private var isReconciled = false

    // Presentation state
    @State private var showKeypad = false
    @State private var showCategorySheet = false
    @State private var showDatePicker = false
    @State private var showDeleteConfirm = false
    @State private var isSaving = false

    init(transactionID: String) {
        self.transactionID = transactionID
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                loadingView
            case .missing:
                missingView
            case .ready:
                form
            }
        }
        .themedScreen()
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: transactionID) { await loadIfNeeded() }
        .sheet(isPresented: $showCategorySheet) {
            CategoryPickerSheet(categoryID: $categoryID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDatePicker) {
            TransactionDatePickerSheet(day: $date)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Delete this transaction?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete Transaction", role: .destructive) { performDelete() }
            Button("Keep It", role: .cancel) { }
        } message: {
            Text("It disappears from every synced device. There's no undo.")
        }
    }

    // MARK: Loading & missing states

    private var loadingView: some View {
        VStack {
            ProgressView()
                .controlSize(.large)
                .tint(theme.palette.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingView: some View {
        EmptyStateView(systemImage: "questionmark.folder",
                       title: "Transaction not found",
                       message: "It may have been deleted on another device since this list loaded.",
                       actionTitle: "Go Back",
                       action: { dismiss() })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.layout.spacing) {
                SectionHeader("Amount")
                amountCard
                SectionHeader("Details")
                    .padding(.top, theme.layout.spacing * 0.5)
                detailsCard
                SectionHeader("Status")
                    .padding(.top, theme.layout.spacing * 0.5)
                statusCard
                NidgetButton(isSaving ? "Saving…" : "Save Changes",
                             systemImage: "checkmark", role: .primary) {
                    saveChanges()
                }
                .disabled(isSaving)
                .padding(.top, theme.layout.spacing * 0.5)
                NidgetButton("Delete Transaction", systemImage: "trash", role: .destructive) {
                    showDeleteConfirm = true
                }
                .disabled(isSaving)
            }
            .padding(theme.layout.cardPadding)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Amount card

    private var amountCard: some View {
        VStack(spacing: theme.layout.spacing * 0.75) {
            Button {
                if reduceMotion {
                    showKeypad.toggle()
                } else {
                    withAnimation(theme.motion.spring) { showKeypad.toggle() }
                }
            } label: {
                HStack {
                    AmountText(amount, style: .display, colorized: true, showSign: true)
                    Spacer()
                    Image(systemName: showKeypad ? "chevron.up" : "chevron.down")
                        .font(theme.font(.subheadline))
                        .fontWeight(theme.icons.weight)
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(showKeypad ? "Hides the keypad" : "Shows the amount keypad")
            if showKeypad {
                AmountKeypad(amount: $amount, allowsSign: true)
                    .transition(reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .themedCard()
    }

    // MARK: Details card

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: theme.layout.spacing * 0.75) {
            PayeeField(text: $payeeText, payeeID: $payeeID, onSuggestionPicked: { suggestion in
                if categoryID == nil, let auto = suggestion.categoryID {
                    categoryID = auto
                }
            })
            separator
            categoryRow
            separator
            accountRowPicker
            separator
            dateRow
            separator
            notesRow
        }
        .themedCard()
    }

    private var separator: some View {
        Rectangle()
            .fill(theme.palette.separator)
            .frame(height: 1)
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(theme.font(.subheadline))
                .fontWeight(theme.icons.weight)
                .symbolVariant(theme.icons.fill ? .fill : .none)
                .foregroundStyle(theme.palette.accent)
                .frame(width: 22)
            Text(title)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textSecondary)
        }
    }

    private var chevronRight: some View {
        Image(systemName: "chevron.right")
            .font(theme.font(.caption))
            .fontWeight(theme.icons.weight)
            .foregroundStyle(theme.palette.textTertiary)
    }

    private var categoryRow: some View {
        Button {
            showCategorySheet = true
        } label: {
            HStack(spacing: 8) {
                rowLabel("Category", systemImage: "tag")
                Spacer()
                Text(categoryDisplayName)
                    .font(theme.font(.body))
                    .foregroundStyle(categoryID == nil ? theme.palette.warning : theme.palette.textPrimary)
                    .lineLimit(1)
                chevronRight
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Category: \(categoryDisplayName)")
    }

    private var categoryDisplayName: String {
        guard let categoryID else { return "Uncategorized" }
        let name = store.categoryName(categoryID)
        return name.isEmpty ? "Uncategorized" : name
    }

    private var accountRowPicker: some View {
        HStack(spacing: 8) {
            rowLabel("Account", systemImage: "building.columns")
            Spacer()
            Picker("Account", selection: $accountID) {
                ForEach(accountChoices) { account in
                    Text(account.name).tag(account.id)
                }
            }
            .pickerStyle(.menu)
            .tint(theme.palette.accent)
            .labelsHidden()
        }
        .frame(minHeight: 44)
    }

    /// Open accounts, plus the transaction's current account even if it has been closed.
    private var accountChoices: [Account] {
        var choices = store.accounts.filter { !$0.closed }
        if !choices.contains(where: { $0.id == accountID }),
           let current = store.accounts.first(where: { $0.id == accountID }) {
            choices.append(current)
        }
        return choices
    }

    private var dateRow: some View {
        Button {
            showDatePicker = true
        } label: {
            HStack(spacing: 8) {
                rowLabel("Date", systemImage: "calendar")
                Spacer()
                Text(dateDisplay)
                    .font(theme.font(.body))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                chevronRight
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Date: \(dateDisplay)")
    }

    private var dateDisplay: String {
        date.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    private var notesRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            rowLabel("Notes", systemImage: "text.alignleft")
            TextField("Add a note", text: $notes, axis: .vertical)
                .font(theme.font(.body))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1...3)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 44)
    }

    // MARK: Status card

    private var statusCard: some View {
        Group {
            if isReconciled {
                HStack(spacing: 8) {
                    rowLabel("Reconciled", systemImage: "lock")
                    Spacer()
                    Text("Locked by a reconciliation")
                        .font(theme.font(.caption))
                        .foregroundStyle(theme.palette.textTertiary)
                }
                .frame(minHeight: 44)
            } else {
                Toggle(isOn: $cleared) {
                    rowLabel("Cleared", systemImage: "checkmark.circle")
                }
                .tint(theme.palette.accent)
                .frame(minHeight: 44)
            }
        }
        .themedCard()
    }

    // MARK: Load

    private func loadIfNeeded() async {
        guard original == nil else { return }
        phase = .loading
        guard let found = await fetchTransaction() else {
            if !Task.isCancelled {
                phase = .missing
            }
            return
        }
        guard !Task.isCancelled else { return }
        original = found
        amount = found.amount
        payeeID = found.payeeID
        payeeText = store.payeeName(found.payeeID)
        categoryID = found.categoryID
        accountID = found.accountID
        date = found.date
        notes = found.notes ?? ""
        cleared = found.cleared
        isReconciled = found.reconciled
        phase = .ready
    }

    /// Pages newest-first batches until the id shows up (AppStore has no fetch-by-id; the
    /// scan is bounded so a truly-missing id degrades to the "not found" state, not a hang).
    private func fetchTransaction() async -> Transaction? {
        let pageSize = 500
        var offset = 0
        while offset < 20_000 {
            let batch = await store.transactions(TransactionQuery(limit: pageSize, offset: offset))
            if Task.isCancelled { return nil }
            if let match = batch.first(where: { $0.id == transactionID }) {
                return match
            }
            if batch.count < pageSize {
                return nil
            }
            offset += pageSize
        }
        return nil
    }

    // MARK: Save & delete

    private func saveChanges() {
        guard !isSaving, original != nil else { return }
        isSaving = true
        let trimmedPayee = payeeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = TransactionDraft(accountID: accountID,
                                     amount: amount,
                                     date: date,
                                     payeeID: payeeID,
                                     newPayeeName: (payeeID == nil && !trimmedPayee.isEmpty) ? trimmedPayee : nil,
                                     categoryID: categoryID,
                                     notes: trimmedNotes.isEmpty ? nil : trimmedNotes,
                                     cleared: cleared)
        Task {
            await store.updateTransaction(id: transactionID, draft)
            Haptics.success()
            dismiss()
        }
    }

    private func performDelete() {
        guard !isSaving else { return }
        isSaving = true
        Haptics.warning()
        Task {
            await store.deleteTransaction(id: transactionID)
            dismiss()
        }
    }
}
