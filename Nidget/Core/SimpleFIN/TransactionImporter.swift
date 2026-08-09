import Foundation

// MARK: - Transaction import pipeline
//
// Pure planning logic that turns SimpleFIN account payloads into `TransactionDraft`s ready for
// AppStore to insert. No I/O, no state — trivially testable. Dedupe is keyed on the bank-provided
// transaction id, which Actual stores in `transactions.financial_id` (the raw CRDT column behind
// the public `imported_id` name — PROTOCOL §8.4 / caution 5).
//
// `TransactionDraft` deliberately has no importedID field — drafts are also built by Quick Add and
// manual editing, where no bank id exists. `PlannedImport` carries the imported id alongside the
// draft so AppStore can thread it into the CRDT insert (`financial_id` column) for future dedupe.

/// Outcome counters for one import run, surfaced in Settings after "Import now".
struct ImportSummary: Sendable {
    /// Transactions planned for insertion.
    var imported: Int
    /// Transactions dropped because their id was already imported into the mapped account
    /// (or repeated within this batch). Disjoint from `pendingSkipped`.
    var skipped: Int
    /// Pending transactions dropped because pending imports are disabled.
    var pendingSkipped: Int
    /// SimpleFIN accounts with no entry in the SF→Actual account map; the Settings mapping UI
    /// lists these so the user can link them.
    var unmapped: [SFAccount]
    /// Per mapped account: display name and how many new transactions this run added.
    var perAccount: [(name: String, added: Int)]
}

/// One transaction ready to insert: the target Actual account, the draft itself, and the
/// bank-provided id. The id rides alongside the draft (not inside it — see file header) so the
/// insert can persist it to `financial_id` for dedupe on subsequent imports.
struct PlannedImport: Sendable {
    var accountID: String
    var draft: TransactionDraft
    var importedID: String
}

/// Everything AppStore needs to execute an import: the drafts to insert plus the summary to show.
struct ImportPlan: Sendable {
    var drafts: [PlannedImport]
    var summary: ImportSummary
}

struct TransactionImporter {

    init() {}

    /// Plans an import without touching the database or network.
    ///
    /// - Parameters:
    ///   - sfAccounts: accounts as fetched by `SimpleFINClient.accounts(startDate:includePending:)`.
    ///   - accountMap: SimpleFIN account id → Actual account id (from
    ///     `Preferences.simplefinAccountMapJSON`). SF accounts absent from the map are reported in
    ///     `ImportSummary.unmapped` and contribute nothing else.
    ///   - existingImportedIDs: Actual account id → set of already-imported `financial_id`s
    ///     (from `BudgetDatabase.existingImportedIDs(accountID:)`), used for dedupe.
    ///   - includePending: when false, pending transactions are dropped and counted in
    ///     `pendingSkipped` (defensive — the client normally omits `pending=1` in that case).
    ///   - defaultCleared: cleared flag for imported drafts. Pending transactions are never
    ///     marked cleared regardless — they have not posted yet.
    func plan(sfAccounts: [SFAccount],
              accountMap: [String: String],
              existingImportedIDs: [String: Set<String>],
              includePending: Bool,
              defaultCleared: Bool) -> ImportPlan {
        var drafts: [PlannedImport] = []
        var imported = 0
        var skipped = 0
        var pendingSkipped = 0
        var unmapped: [SFAccount] = []
        var perAccount: [(name: String, added: Int)] = []

        for sfAccount in sfAccounts {
            guard let accountID = accountMap[sfAccount.id] else {
                unmapped.append(sfAccount)
                continue
            }

            // Seed with what's already in the ledger, then grow so a duplicate id appearing
            // twice in one payload is only planned once.
            var seenIDs = existingImportedIDs[accountID] ?? []
            var added = 0

            for transaction in sfAccount.transactions {
                if transaction.pending && !includePending {
                    pendingSkipped += 1
                    continue
                }
                if seenIDs.contains(transaction.id) {
                    skipped += 1
                    continue
                }
                seenIDs.insert(transaction.id)

                // Payee name: prefer the (non-standard) payee field, else the description;
                // both trimmed with internal whitespace collapsed.
                let payee = Self.collapsed(transaction.payee ?? "")
                let description = Self.collapsed(transaction.description)
                let payeeName = payee.isEmpty ? description : payee

                // Notes: the memo, plus the description when the payee field supplied the name
                // and the description says something different (so no bank detail is lost).
                var noteParts: [String] = []
                let memo = Self.collapsed(transaction.memo ?? "")
                if !memo.isEmpty {
                    noteParts.append(memo)
                }
                if !payee.isEmpty, !description.isEmpty, description != payee {
                    noteParts.append(description)
                }

                let draft = TransactionDraft(
                    accountID: accountID,
                    amount: transaction.amount,   // SimpleFIN sign convention matches Actual
                    date: BudgetDay(date: transaction.posted),
                    payeeID: nil,                 // AppStore resolves/creates the payee by name
                    newPayeeName: payeeName.isEmpty ? nil : payeeName,
                    categoryID: nil,
                    notes: noteParts.isEmpty ? nil : noteParts.joined(separator: " — "),
                    cleared: defaultCleared && !transaction.pending
                )
                drafts.append(PlannedImport(accountID: accountID,
                                            draft: draft,
                                            importedID: transaction.id))
                imported += 1
                added += 1
            }

            perAccount.append((name: sfAccount.name, added: added))
        }

        let summary = ImportSummary(imported: imported,
                                    skipped: skipped,
                                    pendingSkipped: pendingSkipped,
                                    unmapped: unmapped,
                                    perAccount: perAccount)
        return ImportPlan(drafts: drafts, summary: summary)
    }

    /// Trims and collapses all runs of whitespace/newlines to single spaces.
    private static func collapsed(_ string: String) -> String {
        string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
