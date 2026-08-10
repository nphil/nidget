import AppIntents
import Foundation
import os

// MARK: - Platform / App Intents (ARCHITECTURE §15)
//
// Siri/Shortcuts entry points. Intents stay thin: all state changes route through `AppStore`, the
// single UI-facing source of truth (ARCHITECTURE §9). Nothing here talks to SQLite, CRDT, or sync
// directly, and nothing here logs amounts/payees (ARCHITECTURE §4 — never log financial detail).

private enum ShortcutsLog {
    static let log = Logger(subsystem: "app.nidget", category: "shortcuts")
}

// MARK: - PendingActions
//
// `OpenQuickAddIntent` can launch Nidget cold (`openAppWhenRun = true`), before any SwiftUI scene
// — and therefore before `AppRouter` (owned by the shell agent, App/AppRouter.swift) exists — has
// been constructed. It has no way to reach `router.quickAddPresented` directly, so it drops a flag
// here instead. See this report's deviations: RootView/NidgetApp must consume
// `PendingActions.quickAddRequested` on `scenePhase == .active` (set `router.quickAddPresented =
// true` and clear the flag) for the intent to actually open Quick Add.
@MainActor
enum PendingActions {
    static var quickAddRequested = false
}

// MARK: - AddTransactionIntent

struct AddTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Transaction"
    static let description = IntentDescription(
        "Logs a transaction in Nidget without opening the app.")

    @Parameter(title: "Amount", description: "Amount spent. Use a negative number to log income.")
    var amount: Double

    @Parameter(title: "Payee")
    var payee: String

    @Parameter(title: "Category")
    var category: String?

    @Parameter(title: "Account")
    var account: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) at \(\.$payee)") {
            \.$category
            \.$account
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppStore.shared
        guard store.setup == .ready else {
            return .result(dialog: "Open Nidget to finish setting up your budget, then try again.")
        }

        let trimmedPayee = payee.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayee.isEmpty else {
            return .result(dialog: "Give the transaction a payee before logging it.")
        }
        guard let cents = Self.negatedCents(from: amount), cents != 0 else {
            return .result(dialog: "Give the transaction an amount before logging it.")
        }
        guard let accountID = Self.resolveAccountID(named: account, store: store) else {
            return .result(dialog: "Add an account in Nidget before logging transactions.")
        }

        var draft = TransactionDraft(accountID: accountID,
                                     amount: Money(cents: cents),
                                     date: .today,
                                     payeeID: nil,
                                     newPayeeName: nil,
                                     categoryID: nil,
                                     notes: nil,
                                     cleared: true)
        if let matched = Self.matchPayee(named: trimmedPayee, in: store.payees) {
            draft.payeeID = matched.id
        } else {
            draft.newPayeeName = trimmedPayee
        }
        if let category, let matched = Self.matchCategory(named: category, in: store.categoryGroups) {
            draft.categoryID = matched.id
        }

        await store.addTransaction(draft)
        ShortcutsLog.log.info("AddTransactionIntent: transaction logged via Shortcuts")

        let formatted = CurrencyFormatter.string(draft.amount.magnitude)
        return .result(dialog: "Logged \(formatted) at \(trimmedPayee).")
    }

    // MARK: Resolution helpers

    /// Spend is entered positive by the user/Siri but stored as a negative outflow (`Money`'s
    /// convention — ARCHITECTURE §9/Models.swift). Clamps to a sane magnitude before the
    /// `Double → Int64` conversion: `isFinite` alone doesn't guard a trap on an extreme value
    /// (LESSONS_FROM_STASHY §2).
    private static func negatedCents(from amount: Double) -> Int64? {
        guard amount.isFinite else { return nil }
        let clamped = min(max(amount, -1_000_000_000), 1_000_000_000)
        return -Int64((clamped * 100).rounded())
    }

    /// Reads `AppStore`/`Preferences` state, so it must run on the main actor like `perform()`.
    @MainActor
    private static func resolveAccountID(named name: String?, store: AppStore) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, let matched = matchAccount(named: trimmed, in: store.accounts) {
            return matched.id
        }
        if let defaultID = Preferences.shared.defaultAccountID,
           store.accounts.contains(where: { $0.id == defaultID && !$0.closed }) {
            return defaultID
        }
        return store.accounts.first(where: { !$0.closed && !$0.offBudget })?.id
            ?? store.accounts.first(where: { !$0.closed })?.id
    }

    /// Exact case/diacritic-insensitive name match — mirrors `AppStore`'s own payee dedupe
    /// (`existingPayee(named:)`) so a Shortcuts-created transaction never mints a near-duplicate
    /// payee; transfer payees are never a valid match for a hand-entered transaction.
    private static func matchPayee(named name: String, in payees: [Payee]) -> Payee? {
        payees.first { $0.transferAccountID == nil &&
            $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    /// Fuzzy match: prefix first, then substring — same shape as `AppStore.suggestions(for:)`.
    private static func matchCategory(named name: String, in groups: [CategoryGroup]) -> Category? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let categories = groups.flatMap(\.categories)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let prefixMatch = categories.first(where: {
            $0.name.range(of: trimmed, options: options.union(.anchored)) != nil
        }) {
            return prefixMatch
        }
        return categories.first { $0.name.range(of: trimmed, options: options) != nil }
    }

    /// Fuzzy match over open accounts only: prefix first, then substring.
    private static func matchAccount(named name: String, in accounts: [Account]) -> Account? {
        let open = accounts.filter { !$0.closed }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let prefixMatch = open.first(where: {
            $0.name.range(of: name, options: options.union(.anchored)) != nil
        }) {
            return prefixMatch
        }
        return open.first { $0.name.range(of: name, options: options) != nil }
    }
}

// MARK: - OpenQuickAddIntent

struct OpenQuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quick Add"
    static let description = IntentDescription(
        "Jumps straight into Nidget's Quick Add screen.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        PendingActions.quickAddRequested = true
        ShortcutsLog.log.info("OpenQuickAddIntent: pending Quick Add flag set")
        return .result()
    }
}

// MARK: - NidgetShortcuts

struct NidgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTransactionIntent(),
            phrases: [
                "Log a transaction in \(.applicationName)",
                "Add a transaction in \(.applicationName)",
                "Log an expense in \(.applicationName)"
            ],
            shortTitle: "Add Transaction",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: OpenQuickAddIntent(),
            phrases: [
                "Quick add in \(.applicationName)",
                "Open Quick Add in \(.applicationName)"
            ],
            shortTitle: "Quick Add",
            systemImageName: "bolt"
        )
    }
}
