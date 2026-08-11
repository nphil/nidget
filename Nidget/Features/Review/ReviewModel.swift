import Foundation

// MARK: - Review types
//
// The shapes behind the Review screen (docs/AI.md §7). The owner's Actual server imports from
// SimpleFIN on its own, so the daily job is not adding transactions, it is deciding what to do
// with the ones that arrived. Everything here describes a *proposal* waiting on that decision.
//
// Why the source matters enough to model it: the review queue has to be worth opening on a phone
// with no AI model on it at all. Most of what arrives is a payee the owner has filed before, and
// for those a plain count over past transactions is exact, instant, and needs nothing downloaded.
// The embedding kNN only earns its keep on payees with no history, and it is slow enough per
// lookup that AppStore caps how many one queue build may do. Keeping the source on every item
// lets the UI say where a guess came from and lets the cheap path stay the common path.
//
// `ReviewGroup` exists because the fastest way to clear a queue is to confirm a whole category at
// once ("these six are Groceries"), not to tap through one row at a time.

/// Where a proposed category came from.
enum ReviewSource: Sendable, Equatable {
    /// This payee has been filed before, so its most common category is the proposal. No AI.
    case payeeHistory
    /// On-device embedding kNN, for payees with no history.
    case ai
    /// Nidget already applied this one during a sync, and it is waiting on a spot check.
    case autoFiled
    /// No guess. Needs the owner to pick.
    case none
}

/// One transaction in the queue, with whatever guess Nidget has for it.
struct ReviewItem: Identifiable, Sendable, Equatable {
    /// Transaction id.
    var id: String
    var transaction: Transaction
    /// Resolved payee name; "" when the transaction has none.
    var payeeName: String
    /// The category being proposed, or already applied for `.autoFiled`. nil for `.none`.
    var proposedCategoryID: String?
    var source: ReviewSource
}

enum ReviewGroupKind: Sendable, Equatable {
    /// Everything here is proposed for one category, ready to confirm in a batch.
    case suggestion
    /// No guess at all.
    case needsCategory
    /// Already filed by Nidget, shown for a spot check.
    case autoFiled
}

/// A bucket of items the owner can act on together.
struct ReviewGroup: Identifiable, Sendable, Equatable {
    /// The category id for `.suggestion`; the fixed ids below otherwise.
    var id: String
    /// nil for `.needsCategory` (and for the mixed `.autoFiled` bucket).
    var categoryID: String?
    /// Category name, or the fixed titles below.
    var title: String
    var kind: ReviewGroupKind
    var items: [ReviewItem]

    /// Fixed group ids, so the UI can key on them without matching on titles.
    static let needsCategoryID = "__none__"
    static let autoFiledID = "__autofiled__"

    /// Fixed group titles (copy style: plain and warm, docs/ARCHITECTURE conventions).
    static let needsCategoryTitle = "Needs a category"
    static let autoFiledTitle = "Nidget filed these"
}
