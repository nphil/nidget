import Foundation

// MARK: - Domain models
//
// Value types mirroring Actual's budget-file schema (see docs/PROTOCOL.md §8). All Sendable; the
// UI never touches SQLite rows directly. IDs are Actual's string UUIDs.

struct Account: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var offBudget: Bool
    var closed: Bool
    var sortOrder: Double
    /// Populated by AppStore from `BudgetDatabase.accountBalances()`.
    var balance: Money = .zero
    /// Non-nil when this account is mapped to a SimpleFIN account (Preferences map).
    var simpleFINID: String? = nil
}

struct Payee: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Non-nil for the special transfer payee of an account.
    var transferAccountID: String?
}

struct CategoryGroup: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isIncome: Bool
    var sortOrder: Double
    var hidden: Bool
    var categories: [Category]
}

struct Category: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var groupID: String
    var isIncome: Bool
    var sortOrder: Double
    var hidden: Bool
}

struct Transaction: Identifiable, Hashable, Sendable {
    var id: String
    var accountID: String
    var date: BudgetDay
    /// Negative = outflow, positive = inflow.
    var amount: Money
    /// Payee id (Actual stores this in the `description` column).
    var payeeID: String?
    var categoryID: String?
    var notes: String?
    var cleared: Bool
    var reconciled: Bool
    /// Counterpart transaction id when this is one leg of a transfer.
    var transferID: String?
    /// Bank-provided id (`financial_id`) used for import dedupe.
    var importedID: String?
    /// Split support: children carry parentID/isChild; parents carry isParent.
    var parentID: String?
    var isParent: Bool = false
    var isChild: Bool = false
    var sortOrder: Double = 0
}

/// One cell of the budget grid: an allocation for (month, category).
struct BudgetCell: Hashable, Sendable {
    var month: BudgetMonth
    var categoryID: String
    var budgeted: Money
    var carryover: Bool
}

// MARK: - Server-side types

/// A budget file listed by the Actual server.
struct RemoteFile: Identifiable, Hashable, Sendable {
    var id: String { fileID }
    var fileID: String
    var groupID: String?
    var name: String
    var encryptKeyID: String?
    var deleted: Bool
}

/// End-to-end-encryption key parameters returned by the server for an encrypted file.
struct KeyInfo: Hashable, Sendable {
    var keyID: String
    var saltBase64: String
    /// Base64 test payload {iv, authTag, data} the client must decrypt to validate the password.
    var testContentJSON: String?
}

// MARK: - Errors surfaced to the UI

struct AppError: Identifiable, Equatable, Sendable {
    var id = UUID()
    var message: String
    var detail: String?

    static func == (lhs: AppError, rhs: AppError) -> Bool { lhs.id == rhs.id }
}
