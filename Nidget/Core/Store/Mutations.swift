import Foundation

// MARK: - Mutations
//
// Pure builders turning domain operations into CRDT cell writes (ARCHITECTURE §9). No I/O, no
// state, no clocks: timestamps are minted by SyncEngine (`nextTimestamps(count:)`) and applied by
// the caller via `messages(_:timestamps:)` — one timestamp per write, in order.
//
// Every dataset/column below is the RAW SQLite identifier from docs/PROTOCOL.md §8.4 — never the
// public AQL name (§10 trap 5). Verified mapping:
//
//   transactions:  acct (NOT "account"), amount (integer cents), description (the PAYEE id —
//                  free text lives in imported_description), category, notes, date (integer
//                  yyyymmdd), cleared / reconciled / tombstone (integer 0/1),
//                  sort_order (REAL, epoch-millis at creation),
//                  financial_id (NOT "imported_id"), imported_description (NOT "imported_payee")
//   payees:        name; plus a payee_mapping self-row (id → targetId) because Actual's
//                  transaction views resolve `transactions.description` THROUGH payee_mapping
//                  (§8.4 appendix view: `LEFT JOIN payee_mapping pm ON pm.id = t.description` →
//                  `pm.targetId AS payee`) — without the self-mapping, other Actual clients show
//                  no payee at all.
//   zero_budgets:  row id "<yyyy-mm>-<categoryID>" (month in DASH form in the id, §8.4), with
//                  month (integer yyyymm — NUMERIC form in the column), category (id string),
//                  amount (integer cents), carryover (0/1).
//
// Value encoding: numbers ride as `.number` (integer-valued Doubles encode as "N:123" with no
// decimal point — see CRDTValue), booleans as 1/0 numbers, SQL NULL as `.null` ("0:").

enum Mutations {

    // MARK: - CellWrite

    /// One cell write awaiting its HLC timestamp. Zipped with timestamps by
    /// `messages(_:timestamps:)` to become `CRDTMessage`s.
    struct CellWrite: Sendable, Equatable {
        var dataset: String
        var row: String
        var column: String
        var value: CRDTValue
    }

    /// New row id in Actual's format: lowercased UUID string.
    static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Stamps writes into wire-ready messages. `timestamps` must contain exactly one HLC string
    /// per write, in order (mint them with `SyncEngine.nextTimestamps(count: writes.count)`);
    /// zip truncates to the shorter side rather than trapping.
    static func messages(_ writes: [CellWrite], timestamps: [String]) -> [CRDTMessage] {
        zip(writes, timestamps).map { write, timestamp in
            CRDTMessage(timestamp: timestamp,
                        dataset: write.dataset,
                        row: write.row,
                        column: write.column,
                        value: write.value)
        }
    }

    // MARK: - Transactions

    /// Cell writes creating a new transaction. A brand-new row is many messages — one per field
    /// (PROTOCOL §6.2); columns whose value would be NULL on a fresh row are simply omitted.
    ///
    /// - `id` defaults to a freshly generated lowercased UUID (evaluated per call).
    /// - `draft.payeeID` must already be resolved (AppStore turns `newPayeeName` into a payee id
    ///   before building writes).
    /// - `importedID` → `financial_id` (bank dedupe id); `importedPayee` → `imported_description`
    ///   (the raw bank payee string, which Actual's payee-learning consumes).
    static func addTransaction(id: String = Mutations.newID(),
                               draft: TransactionDraft,
                               importedID: String? = nil,
                               importedPayee: String? = nil) -> [CellWrite] {
        var writes: [CellWrite] = []
        func put(_ column: String, _ value: CRDTValue) {
            writes.append(CellWrite(dataset: "transactions", row: id, column: column, value: value))
        }
        put("acct", .string(draft.accountID))
        put("amount", .number(Double(draft.amount.cents)))
        put("date", .number(Double(draft.date.raw)))
        // PROTOCOL §8.4: sort_order defaults to Date.now() (epoch millis) at CREATION in
        // Actual's app layer — the raw SQLite column has no default, so without this write the
        // row gets NULL and sinks/interleaves unstably in every client's same-day ordering.
        put("sort_order", .number((Date().timeIntervalSince1970 * 1000).rounded()))
        if let payeeID = draft.payeeID, !payeeID.isEmpty {
            put("description", .string(payeeID))
        }
        if let categoryID = draft.categoryID, !categoryID.isEmpty {
            put("category", .string(categoryID))
        }
        if let notes = draft.notes, !notes.isEmpty {
            put("notes", .string(notes))
        }
        put("cleared", bool(draft.cleared))
        if let importedID, !importedID.isEmpty {
            put("financial_id", .string(importedID))
        }
        if let importedPayee, !importedPayee.isEmpty {
            put("imported_description", .string(importedPayee))
        }
        return writes
    }

    /// Full-state update of an existing transaction from a draft: every editable field is
    /// written, with explicit NULLs for cleared-out optionals (so removing a note/category/payee
    /// actually syncs). Import fields (`financial_id`, `imported_description`) are untouched.
    static func updateTransaction(id: String, draft: TransactionDraft) -> [CellWrite] {
        updateFields(dataset: "transactions", id: id, fields: [
            (column: "acct", value: .string(draft.accountID)),
            (column: "amount", value: .number(Double(draft.amount.cents))),
            (column: "date", value: .number(Double(draft.date.raw))),
            (column: "description", value: optionalString(draft.payeeID)),
            (column: "category", value: optionalString(draft.categoryID)),
            (column: "notes", value: optionalString(draft.notes)),
            (column: "cleared", value: bool(draft.cleared)),
        ])
    }

    /// Single-cell cleared toggle.
    static func setCleared(id: String, cleared: Bool) -> [CellWrite] {
        [CellWrite(dataset: "transactions", row: id, column: "cleared", value: bool(cleared))]
    }

    /// Single-cell reconciled toggle — the lock applied when an account reconciles.
    static func setReconciled(id: String, reconciled: Bool) -> [CellWrite] {
        [CellWrite(dataset: "transactions", row: id, column: "reconciled", value: bool(reconciled))]
    }

    /// Generic field update on any dataset — the raw building block behind the typed helpers.
    static func updateFields(dataset: String, id: String,
                             fields: [(column: String, value: CRDTValue)]) -> [CellWrite] {
        fields.map { CellWrite(dataset: dataset, row: id, column: $0.column, value: $0.value) }
    }

    /// Soft delete: Actual never hard-deletes rows, it sets `tombstone = 1` (PROTOCOL §8.4).
    static func softDelete(dataset: String, id: String) -> [CellWrite] {
        [CellWrite(dataset: dataset, row: id, column: "tombstone", value: .number(1))]
    }

    /// Convenience for the most common soft delete.
    static func deleteTransaction(id: String) -> [CellWrite] {
        softDelete(dataset: "transactions", id: id)
    }

    // MARK: - Budget

    /// Budget-cell allocation for (month, category). Row id follows PROTOCOL §8.4's composite
    /// convention: `"<yyyy-mm>-<categoryID>"` (the id's month component is DASHED even though
    /// the `month` column is the plain yyyymm integer). `month` and `category` are re-written on
    /// every set — idempotent for an existing row, and required for a fresh row to be queryable.
    static func setBudget(month: BudgetMonth, categoryID: String, amount: Money) -> [CellWrite] {
        let row = budgetRowID(month: month, categoryID: categoryID)
        return [
            CellWrite(dataset: "zero_budgets", row: row, column: "month",
                      value: .number(Double(month.raw))),
            CellWrite(dataset: "zero_budgets", row: row, column: "category",
                      value: .string(categoryID)),
            CellWrite(dataset: "zero_budgets", row: row, column: "amount",
                      value: .number(Double(amount.cents))),
        ]
    }

    /// Toggles a budget cell's carryover flag ("rollover overspending" in Actual). Same row-id
    /// convention as `setBudget`; month/category are included so the row exists even when no
    /// amount was ever budgeted.
    static func setBudgetCarryover(month: BudgetMonth, categoryID: String,
                                   carryover: Bool) -> [CellWrite] {
        let row = budgetRowID(month: month, categoryID: categoryID)
        return [
            CellWrite(dataset: "zero_budgets", row: row, column: "month",
                      value: .number(Double(month.raw))),
            CellWrite(dataset: "zero_budgets", row: row, column: "category",
                      value: .string(categoryID)),
            CellWrite(dataset: "zero_budgets", row: row, column: "carryover",
                      value: bool(carryover)),
        ]
    }

    private static func budgetRowID(month: BudgetMonth, categoryID: String) -> String {
        "\(month.dashString)-\(categoryID)"
    }

    // MARK: - Payees

    /// Creates a payee plus its `payee_mapping` self-row (id → targetId), matching what Actual
    /// writes on payee creation so `transactions.description` resolves in every client (see the
    /// file-header note on the §8.4 view join).
    static func createPayee(id: String, name: String) -> [CellWrite] {
        [
            CellWrite(dataset: "payees", row: id, column: "name", value: .string(name)),
            CellWrite(dataset: "payee_mapping", row: id, column: "targetId", value: .string(id)),
        ]
    }

    // MARK: - Value helpers

    private static func bool(_ value: Bool) -> CRDTValue {
        .number(value ? 1 : 0)
    }

    private static func optionalString(_ value: String?) -> CRDTValue {
        guard let value, !value.isEmpty else { return .null }
        return .string(value)
    }
}
