import Foundation

// MARK: - MonthCarry

/// What one budget month hands to the next when chaining envelope math forward
/// (`BudgetCalculator.carry(from:)` → next month's `previous:` parameter).
struct MonthCarry: Sendable {
    /// Cumulative "To Budget" after leaving the month: the month's own To Budget minus the
    /// overspending of non-carryover categories (a negative adjustment).
    var toBudget: Money
    /// Category id → balance carried into the next month. Positive leftovers always carry;
    /// negative balances carry ONLY for categories whose cell had the carryover flag set.
    /// Categories with a zero (or dropped) balance are absent.
    var categoryBalances: [String: Money]
}

// MARK: - BudgetCalculator
//
// Pure envelope-budget math over one month, matching Actual's zero-based budgeting semantics
// (ARCHITECTURE §9; PROTOCOL §8.4 zero_budgets). AppStore chains months oldest-first — each
// month's snapshot feeds `carry(from:)`, whose result is the next month's `previous:`.
//
// Documented assumptions (implemented exactly as stated):
//
// 1. Category balance = carriedIn + budgeted + spent, where:
//    - carriedIn = `previous.categoryBalances[category]` (zero when absent / no previous).
//      Per Actual's default, a NEGATIVE balance does NOT carry into the next month unless the
//      overspent month's cell had its carryover ("rollover overspending") flag set; positive
//      balances always carry. That rule is applied by `carry(from:)`, on the month where the
//      overspend happened.
//    - budgeted = the month's `zero_budgets` amount for the category (zero when no cell).
//    - spent = the month's category outflow as NEGATIVE Money
//      (`BudgetDatabase.spentByCategory` convention).
// 2. To Budget (the number shown for the month) =
//        previous.toBudget + income(month) − totalBudgeted(month)
//    where income(month) is the month's income-category total (`BudgetDatabase.incomeTotal`)
//    and previous.toBudget already folds in ALL earlier months' income, budgeting, and
//    non-carryover overspending. Leaving the month, `carry(from:)` computes
//        carried.toBudget = toBudget(month) + Σ min(balance, 0) over non-carryover categories
//    (the negative overspent sum — overspending without carryover comes out of To Budget).
// 3. Income category rows are structural only (budgeted/spent/balance = zero) — Actual doesn't
//    budget income envelopes; per-income-category received amounts aren't part of the snapshot.
// 4. Spending recorded against a category that no longer exists in `groups` (deleted category)
//    is excluded from row and total math — mirroring reads that join on live categories.
// 5. `zero_budget_months.buffered` ("hold for next month") is not modeled.
// 6. Hidden categories/groups are included in the snapshot (with their flags available on the
//    domain models); filtering hidden rows is a presentation concern.

enum BudgetCalculator {

    /// Builds the month's snapshot. `cells` are the month's `zero_budgets` rows, `spent` is
    /// category id → NEGATIVE outflow, `income` the month's income total, `groups` the live
    /// category tree (rows come out grouped and ordered exactly like `groups`), `previous` the
    /// carry from the prior month (nil for the earliest month in the chain).
    static func snapshot(month: BudgetMonth,
                         cells: [BudgetCell],
                         spent: [String: Money],
                         income: Money,
                         groups: [CategoryGroup],
                         previous: MonthCarry?) -> MonthBudgetSnapshot {
        var cellsByCategory: [String: BudgetCell] = [:]
        for cell in cells {
            cellsByCategory[cell.categoryID] = cell
        }

        var rows: [BudgetRowSnapshot] = []
        var totalBudgeted = Money.zero
        var totalSpent = Money.zero

        for group in groups {
            for category in group.categories {
                if category.isIncome || group.isIncome {
                    rows.append(BudgetRowSnapshot(id: category.id,
                                                  name: category.name,
                                                  groupID: group.id,
                                                  budgeted: .zero,
                                                  spent: .zero,
                                                  balance: .zero,
                                                  carryover: false,
                                                  isIncome: true))
                    continue
                }
                let cell = cellsByCategory[category.id]
                let budgeted = cell?.budgeted ?? .zero
                let spentAmount = spent[category.id] ?? .zero
                let carriedIn = previous?.categoryBalances[category.id] ?? .zero
                let balance = carriedIn + budgeted + spentAmount

                totalBudgeted += budgeted
                totalSpent += spentAmount

                rows.append(BudgetRowSnapshot(id: category.id,
                                              name: category.name,
                                              groupID: group.id,
                                              budgeted: budgeted,
                                              spent: spentAmount,
                                              balance: balance,
                                              carryover: cell?.carryover ?? false,
                                              isIncome: false))
            }
        }

        let toBudget = (previous?.toBudget ?? .zero) + income - totalBudgeted
        return MonthBudgetSnapshot(month: month,
                                   toBudget: toBudget,
                                   income: income,
                                   totalBudgeted: totalBudgeted,
                                   totalSpent: totalSpent,
                                   rows: rows)
    }

    /// Computes what the month hands to its successor (assumptions 1–2 above):
    /// - positive balances always carry per category;
    /// - negative balances carry only when the row's carryover flag is set;
    /// - non-carryover negative balances are summed into the To Budget adjustment instead.
    static func carry(from snapshot: MonthBudgetSnapshot) -> MonthCarry {
        var balances: [String: Money] = [:]
        var overspent = Money.zero

        for row in snapshot.rows where !row.isIncome {
            if row.balance.cents > 0 {
                balances[row.id] = row.balance
            } else if row.balance.cents < 0 {
                if row.carryover {
                    balances[row.id] = row.balance
                } else {
                    overspent += row.balance
                }
            }
        }
        return MonthCarry(toBudget: snapshot.toBudget + overspent,
                          categoryBalances: balances)
    }
}
