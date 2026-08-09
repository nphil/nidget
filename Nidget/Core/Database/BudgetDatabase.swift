import Foundation
import os

// MARK: - TransactionQuery

/// Filter/paging descriptor for `BudgetDatabase.transactions(_:)` / `transactionCount(_:)`.
struct TransactionQuery: Sendable {
    var accountID: String? = nil
    var categoryID: String? = nil
    var payeeID: String? = nil
    /// Case-insensitive substring match against notes OR payee name.
    var search: String? = nil
    /// Inclusive month range; expands to lowerBound.firstDay ... upperBound.lastDay.
    var months: ClosedRange<BudgetMonth>? = nil
    var onlyUncategorized = false
    var limit = 100
    var offset = 0
}

// MARK: - BudgetDatabase
//
// Typed access to an Actual budget SQLite file (docs/PROTOCOL.md §8). NOT an actor — must only
// be touched from the `DatabaseQueue` actor owned by AppStore.
//
// Schema conventions honored throughout (PROTOCOL §8.4 raw column names, §10 trap 5/6):
// - `transactions.description` holds a payee_mapping id; the real payee id is resolved via
//   `payee_mapping.targetId`. Categories resolve the same way via `category_mapping.transferId`.
//   COALESCE falls back to the raw id when no mapping row exists (identical result for the
//   normal self-mapped case).
// - Amounts are INTEGER cents; dates are INTEGER yyyymmdd; `tombstone = 1` rows are deleted and
//   excluded everywhere.
// - Split transactions: parent rows (`isParent = 1`) are excluded from every read/aggregate so
//   splits appear (and sum) as their child parts; child rows are included.
// - Spending aggregates (`spentByCategory`, `monthlySpendSeries`, `dailySpend`) sum NEGATIVE
//   amounts only and return them as negative Money (outflow = negative, matching `Money`'s
//   convention). Callers wanting magnitudes use `.magnitude`.
final class BudgetDatabase {
    private let db: SQLiteDB
    private static let log = Logger(subsystem: "app.nidget", category: "database")

    /// Table name → set of column names discovered from the opened file. Serves as the
    /// whitelist that CRDT `dataset`/`column` strings are validated against before being
    /// interpolated into SQL (they arrive over the network — never trust them raw).
    private let tableColumns: [String: Set<String>]

    init(fileURL: URL) throws {
        db = try SQLiteDB(path: fileURL.path(percentEncoded: false))
        try Schema.ensureLocalTables(db)
        // WAL + NORMAL is durable across app crashes and much faster for message batches.
        try db.exec("PRAGMA synchronous=NORMAL")
        tableColumns = try Self.discoverTables(db)
    }

    func close() {
        db.close()
    }

    // MARK: - Accounts

    func accounts(includeClosed: Bool) throws -> [Account] {
        var sql = """
            SELECT id, name, offbudget, closed, COALESCE(sort_order, 0) AS sort_order
            FROM accounts
            WHERE tombstone = 0
            """
        if !includeClosed {
            sql += " AND closed = 0"
        }
        sql += " ORDER BY offbudget ASC, sort_order ASC, name COLLATE NOCASE ASC"
        return try db.query(sql, []).compactMap { row in
            guard let id = row.string("id") else { return nil }
            return Account(
                id: id,
                name: row.string("name") ?? "",
                offBudget: (row.int("offbudget") ?? 0) != 0,
                closed: (row.int("closed") ?? 0) != 0,
                sortOrder: row.double("sort_order") ?? 0
            )
        }
    }

    /// Account id → balance (sum of ALL non-tombstoned, non-parent transactions — cleared and
    /// pending alike). Accounts with no transactions are absent from the result.
    func accountBalances() throws -> [String: Money] {
        let rows = try db.query("""
            SELECT t.acct AS id, SUM(t.amount) AS balance
            FROM transactions t
            WHERE t.tombstone = 0 AND t.isParent = 0 AND t.acct IS NOT NULL
            GROUP BY t.acct
            """, [])
        var balances: [String: Money] = [:]
        for row in rows {
            guard let id = row.string("id") else { continue }
            balances[id] = Money(cents: row.int("balance") ?? 0)
        }
        return balances
    }

    // MARK: - Categories & payees

    /// Groups ordered expense-first then by sort_order, each with its categories nested and sorted.
    func categoryGroups() throws -> [CategoryGroup] {
        let groupRows = try db.query("""
            SELECT id, name, is_income, COALESCE(sort_order, 0) AS sort_order,
                   COALESCE(hidden, 0) AS hidden
            FROM category_groups
            WHERE tombstone = 0
            ORDER BY is_income ASC, sort_order ASC, name COLLATE NOCASE ASC
            """, [])
        let categoryRows = try db.query("""
            SELECT id, name, cat_group, is_income, COALESCE(sort_order, 0) AS sort_order,
                   COALESCE(hidden, 0) AS hidden
            FROM categories
            WHERE tombstone = 0
            ORDER BY sort_order ASC, name COLLATE NOCASE ASC
            """, [])

        var categoriesByGroup: [String: [Category]] = [:]
        for row in categoryRows {
            guard let id = row.string("id"), let groupID = row.string("cat_group") else { continue }
            let category = Category(
                id: id,
                name: row.string("name") ?? "",
                groupID: groupID,
                isIncome: (row.int("is_income") ?? 0) != 0,
                sortOrder: row.double("sort_order") ?? 0,
                hidden: (row.int("hidden") ?? 0) != 0
            )
            categoriesByGroup[groupID, default: []].append(category)
        }

        return groupRows.compactMap { row in
            guard let id = row.string("id") else { return nil }
            return CategoryGroup(
                id: id,
                name: row.string("name") ?? "",
                isIncome: (row.int("is_income") ?? 0) != 0,
                sortOrder: row.double("sort_order") ?? 0,
                hidden: (row.int("hidden") ?? 0) != 0,
                categories: categoriesByGroup[id] ?? []
            )
        }
    }

    func payees() throws -> [Payee] {
        try db.query("""
            SELECT id, name, transfer_acct
            FROM payees
            WHERE tombstone = 0
            ORDER BY name COLLATE NOCASE ASC
            """, []).compactMap { row in
            guard let id = row.string("id") else { return nil }
            return Payee(
                id: id,
                name: row.string("name") ?? "",
                transferAccountID: row.string("transfer_acct")
            )
        }
    }

    /// id → display name. Includes merged-away payee ids (resolved through `payee_mapping`) so
    /// any payee id ever stored on a transaction resolves to the surviving payee's name.
    func payeeNames() throws -> [String: String] {
        var names: [String: String] = [:]
        let mapped = try db.query("""
            SELECT pm.id AS id, p.name AS name
            FROM payee_mapping pm
            JOIN payees p ON p.id = pm.targetId
            WHERE p.tombstone = 0
            """, [])
        for row in mapped {
            guard let id = row.string("id"), let name = row.string("name") else { continue }
            names[id] = name
        }
        let direct = try db.query("SELECT id, name FROM payees WHERE tombstone = 0", [])
        for row in direct {
            guard let id = row.string("id"), let name = row.string("name") else { continue }
            if names[id] == nil { names[id] = name }
        }
        return names
    }

    // MARK: - Transactions

    func transactions(_ q: TransactionQuery) throws -> [Transaction] {
        let parts = filterParts(q)
        let sql = """
            SELECT t.id, t.acct, t.date, t.amount,
                   COALESCE(pm.targetId, t.description) AS payee,
                   COALESCE(cm.transferId, t.category) AS category,
                   t.notes, t.cleared, t.reconciled, t.transferred_id, t.financial_id,
                   t.parent_id, t.isParent, t.isChild, t.sort_order
            FROM transactions t
            \(parts.joins)
            WHERE \(parts.whereClause)
            ORDER BY t.date DESC, t.sort_order DESC, t.id ASC
            LIMIT ? OFFSET ?
            """
        var params = parts.params
        params.append(.int(Int64(max(0, q.limit))))
        params.append(.int(Int64(max(0, q.offset))))

        return try db.query(sql, params).compactMap { row in
            guard let id = row.string("id"),
                  let accountID = row.string("acct"),
                  let date = row.int("date") else { return nil }
            return Transaction(
                id: id,
                accountID: accountID,
                date: BudgetDay(raw: Int(date)),
                amount: Money(cents: row.int("amount") ?? 0),
                payeeID: row.string("payee"),
                categoryID: row.string("category"),
                notes: row.string("notes"),
                cleared: (row.int("cleared") ?? 1) != 0,
                reconciled: (row.int("reconciled") ?? 0) != 0,
                transferID: row.string("transferred_id"),
                importedID: row.string("financial_id"),
                parentID: row.string("parent_id"),
                isParent: (row.int("isParent") ?? 0) != 0,
                isChild: (row.int("isChild") ?? 0) != 0,
                sortOrder: row.double("sort_order") ?? 0
            )
        }
    }

    /// Count of ALL rows matching the query's filters (limit/offset are ignored).
    func transactionCount(_ q: TransactionQuery) throws -> Int {
        let parts = filterParts(q)
        let sql = """
            SELECT COUNT(*)
            FROM transactions t
            \(parts.joins)
            WHERE \(parts.whereClause)
            """
        return Int(Self.int64(try db.scalar(sql, parts.params)) ?? 0)
    }

    /// Bank-import dedupe: every `financial_id` ever seen for the account, INCLUDING tombstoned
    /// rows — a transaction the user deleted must not be resurrected by the next import.
    func existingImportedIDs(accountID: String) throws -> Set<String> {
        let rows = try db.query("""
            SELECT financial_id
            FROM transactions
            WHERE acct = ? AND financial_id IS NOT NULL
            """, [.text(accountID)])
        var ids: Set<String> = []
        for row in rows {
            if let importedID = row.string("financial_id") {
                ids.insert(importedID)
            }
        }
        return ids
    }

    // MARK: - Budget & aggregates

    func budgetCells(month: BudgetMonth) throws -> [BudgetCell] {
        try db.query("""
            SELECT category, amount, carryover
            FROM zero_budgets
            WHERE month = ? AND category IS NOT NULL
            """, [.int(Int64(month.raw))]).compactMap { row in
            guard let categoryID = row.string("category") else { return nil }
            return BudgetCell(
                month: month,
                categoryID: categoryID,
                budgeted: Money(cents: row.int("amount") ?? 0),
                carryover: (row.int("carryover") ?? 0) != 0
            )
        }
    }

    /// Category id → month outflow as NEGATIVE Money. Sums only negative amounts of
    /// non-income categories in on-budget accounts; parent split rows excluded.
    func spentByCategory(month: BudgetMonth) throws -> [String: Money] {
        let rows = try db.query("""
            SELECT COALESCE(cm.transferId, t.category) AS category, SUM(t.amount) AS total
            FROM transactions t
            JOIN accounts a ON a.id = t.acct AND a.offbudget = 0 AND a.tombstone = 0
            LEFT JOIN category_mapping cm ON cm.id = t.category
            JOIN categories c ON c.id = COALESCE(cm.transferId, t.category) AND c.is_income = 0
            WHERE t.tombstone = 0 AND t.isParent = 0 AND t.amount < 0
              AND t.date >= ? AND t.date <= ?
            GROUP BY COALESCE(cm.transferId, t.category)
            """, [.int(Int64(month.firstDay.raw)), .int(Int64(month.lastDay.raw))])
        var spent: [String: Money] = [:]
        for row in rows {
            guard let categoryID = row.string("category") else { continue }
            spent[categoryID, default: .zero] += Money(cents: row.int("total") ?? 0)
        }
        return spent
    }

    /// Sum of all amounts in income categories for the month, on-budget accounts only.
    func incomeTotal(month: BudgetMonth) throws -> Money {
        let value = try db.scalar("""
            SELECT SUM(t.amount)
            FROM transactions t
            JOIN accounts a ON a.id = t.acct AND a.offbudget = 0 AND a.tombstone = 0
            LEFT JOIN category_mapping cm ON cm.id = t.category
            JOIN categories c ON c.id = COALESCE(cm.transferId, t.category) AND c.is_income = 1
            WHERE t.tombstone = 0 AND t.isParent = 0
              AND t.date >= ? AND t.date <= ?
            """, [.int(Int64(month.firstDay.raw)), .int(Int64(month.lastDay.raw))])
        return Money(cents: Self.int64(value) ?? 0)
    }

    /// Outflow per month (NEGATIVE Money) for the last `monthsBack` months ending at the current
    /// month, oldest first, zero-filled. On-budget accounts, non-income categories (or
    /// uncategorized), transfers excluded.
    func monthlySpendSeries(monthsBack: Int) throws -> [(BudgetMonth, Money)] {
        let months = BudgetMonth.lastMonths(max(1, monthsBack))
        guard let firstMonth = months.first else { return [] }
        let rows = try db.query("""
            SELECT CAST(t.date AS INTEGER) / 100 AS ym, SUM(t.amount) AS total
            FROM transactions t
            JOIN accounts a ON a.id = t.acct AND a.offbudget = 0 AND a.tombstone = 0
            LEFT JOIN category_mapping cm ON cm.id = t.category
            LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
            WHERE t.tombstone = 0 AND t.isParent = 0 AND t.amount < 0
              AND t.transferred_id IS NULL
              AND (c.is_income IS NULL OR c.is_income = 0)
              AND t.date >= ?
            GROUP BY CAST(t.date AS INTEGER) / 100
            """, [.int(Int64(firstMonth.firstDay.raw))])
        var totals: [Int: Int64] = [:]
        for row in rows {
            guard let ym = row.int("ym") else { continue }
            totals[Int(ym), default: 0] += row.int("total") ?? 0
        }
        return months.map { ($0, Money(cents: totals[$0.raw] ?? 0)) }
    }

    /// Day-of-month → outflow (NEGATIVE Money) for the month. Days without spending are absent.
    /// Same filters as `monthlySpendSeries`.
    func dailySpend(month: BudgetMonth) throws -> [Int: Money] {
        let rows = try db.query("""
            SELECT CAST(t.date AS INTEGER) % 100 AS day, SUM(t.amount) AS total
            FROM transactions t
            JOIN accounts a ON a.id = t.acct AND a.offbudget = 0 AND a.tombstone = 0
            LEFT JOIN category_mapping cm ON cm.id = t.category
            LEFT JOIN categories c ON c.id = COALESCE(cm.transferId, t.category)
            WHERE t.tombstone = 0 AND t.isParent = 0 AND t.amount < 0
              AND t.transferred_id IS NULL
              AND (c.is_income IS NULL OR c.is_income = 0)
              AND t.date >= ? AND t.date <= ?
            GROUP BY CAST(t.date AS INTEGER) % 100
            """, [.int(Int64(month.firstDay.raw)), .int(Int64(month.lastDay.raw))])
        var spend: [Int: Money] = [:]
        for row in rows {
            guard let day = row.int("day") else { continue }
            spend[Int(day), default: .zero] += Money(cents: row.int("total") ?? 0)
        }
        return spend
    }

    /// Cumulative balance across ALL accounts (on- and off-budget, incl. closed) at each month's
    /// end, for the last `monthsBack` months ending at the current month, oldest first. Transfer
    /// legs cancel across accounts, so this is true net worth movement. One grouped query plus a
    /// running sum in Swift.
    func netWorthSeries(monthsBack: Int) throws -> [(BudgetMonth, Money)] {
        let months = BudgetMonth.lastMonths(max(1, monthsBack))
        let rows = try db.query("""
            SELECT CAST(t.date AS INTEGER) / 100 AS ym, SUM(t.amount) AS total
            FROM transactions t
            JOIN accounts a ON a.id = t.acct AND a.tombstone = 0
            WHERE t.tombstone = 0 AND t.isParent = 0 AND t.date IS NOT NULL
            GROUP BY CAST(t.date AS INTEGER) / 100
            ORDER BY ym ASC
            """, [])
        var index = 0
        var running: Int64 = 0
        var series: [(BudgetMonth, Money)] = []
        series.reserveCapacity(months.count)
        for month in months {
            while index < rows.count,
                  let ym = rows[index].int("ym"),
                  ym <= Int64(month.raw) {
                running += rows[index].int("total") ?? 0
                index += 1
            }
            series.append((month, Money(cents: running)))
        }
        return series
    }

    // MARK: - CRDT plumbing (used by SyncEngine + Mutations)

    /// Last-write-wins apply per docs/PROTOCOL.md §6: compares the message's HLC timestamp
    /// (plain string comparison — the format is lexicographically chronological) against the
    /// newest recorded timestamp for the same (dataset, row, column) cell in `messages_crdt`.
    ///
    /// - An exact-duplicate timestamp for the cell is dropped entirely (returns false).
    /// - A strictly-newer message mutates the domain row (INSERT OR IGNORE id-only row, then
    ///   UPDATE the one column) and is recorded; an older message is recorded only.
    /// - `insertOnly: true` records the message without ever touching domain tables (used when
    ///   the domain change was already applied optimistically by Mutations).
    /// - Returns true iff domain data changed (message won LWW and was applied).
    ///
    /// The whole step runs in one SQLite transaction. `dataset`/`column` are validated against
    /// the tables/columns discovered in the opened file before any SQL interpolation; messages
    /// for unknown datasets/columns (e.g. `prefs`, or tables from a newer server schema) are
    /// recorded for merkle correctness but not applied.
    func apply(_ message: CRDTMessage, insertOnly: Bool) throws -> Bool {
        try db.transaction {
            let existing = try db.scalar("""
                SELECT MAX(timestamp) FROM messages_crdt
                WHERE dataset = ? AND "row" = ? AND "column" = ?
                """, [.text(message.dataset), .text(message.row), .text(message.column)])
            var existingTimestamp: String?
            if case .text(let ts)? = existing {
                existingTimestamp = ts
            }
            if existingTimestamp == message.timestamp {
                return false
            }

            let wins = existingTimestamp.map { message.timestamp > $0 } ?? true
            var changed = false
            if wins && !insertOnly {
                changed = try applyToDomain(message)
            }

            try db.run("""
                INSERT OR IGNORE INTO messages_crdt (timestamp, dataset, "row", "column", value)
                VALUES (?, ?, ?, ?, ?)
                """, [.text(message.timestamp), .text(message.dataset), .text(message.row),
                      .text(message.column), .text(message.value.encoded)])
            return changed
        }
    }

    func haveTimestamp(_ ts: String) throws -> Bool {
        try db.scalar("SELECT 1 FROM messages_crdt WHERE timestamp = ? LIMIT 1", [.text(ts)]) != nil
    }

    /// Every recorded message with timestamp strictly greater than `ts`, ascending — the
    /// outbound batch for a sync request (PROTOCOL §6.4).
    func messagesSince(_ ts: String) throws -> [CRDTMessage] {
        let rows = try db.query("""
            SELECT timestamp, dataset, "row", "column", value
            FROM messages_crdt
            WHERE timestamp > ?
            ORDER BY timestamp ASC
            """, [.text(ts)])
        return rows.compactMap(Self.message(from:))
    }

    /// Reads the single `messages_clock` row (id = 1) and splits its JSON into the HLC timestamp
    /// string (`clock`) and the merkle trie JSON string (`merkle`). Nil when never saved.
    func clockState() throws -> (clock: String, merkle: String)? {
        guard case .text(let json)? = try db.scalar("SELECT clock FROM messages_clock WHERE id = 1", []),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestamp = object["timestamp"] as? String else {
            return nil
        }
        let merkleObject = (object["merkle"] as? [String: Any]) ?? [:]
        let merkleData = (try? JSONSerialization.data(withJSONObject: merkleObject, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let merkle = String(data: merkleData, encoding: .utf8) ?? "{}"
        return (clock: timestamp, merkle: merkle)
    }

    /// Persists `{"timestamp": clock, "merkle": <parsed merkle JSON>}` as the single
    /// `messages_clock` row, matching Actual's serializeClock format (PROTOCOL §3.7 / §6.1).
    func saveClockState(clock: String, merkle: String) throws {
        var merkleObject: Any = [String: Any]()
        if let data = merkle.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            merkleObject = parsed
        } else {
            Self.log.error("saveClockState received an unparseable merkle string; storing empty trie")
        }
        let payload: [String: Any] = ["timestamp": clock, "merkle": merkleObject]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try db.run("INSERT OR REPLACE INTO messages_clock (id, clock) VALUES (1, ?)", [.text(json)])
    }

    // MARK: - Offline outbox (used by SyncEngine's pending queue)

    /// Messages applied locally but not yet confirmed by the server, ascending by timestamp —
    /// re-sent on every sync attempt until `clearPending(_:)` removes them.
    func pendingMessages() throws -> [CRDTMessage] {
        let rows = try db.query("""
            SELECT timestamp, dataset, "row", "column", value
            FROM local_pending_messages
            ORDER BY timestamp ASC
            """, [])
        return rows.compactMap(Self.message(from:))
    }

    /// Adds messages to the offline outbox (idempotent per timestamp). Call after applying a
    /// local mutation's messages, before attempting network sync.
    func enqueuePending(_ msgs: [CRDTMessage]) throws {
        guard !msgs.isEmpty else { return }
        try db.transaction {
            for message in msgs {
                try db.run("""
                    INSERT OR REPLACE INTO local_pending_messages (timestamp, dataset, "row", "column", value)
                    VALUES (?, ?, ?, ?, ?)
                    """, [.text(message.timestamp), .text(message.dataset), .text(message.row),
                          .text(message.column), .text(message.value.encoded)])
            }
        }
    }

    /// Removes outbox rows by timestamp. Call with the timestamps of every message the server
    /// acknowledged (a successful /sync/sync round-trip).
    func clearPending(_ timestamps: [String]) throws {
        guard !timestamps.isEmpty else { return }
        try db.transaction {
            for timestamp in timestamps {
                try db.run("DELETE FROM local_pending_messages WHERE timestamp = ?", [.text(timestamp)])
            }
        }
    }

    // MARK: - Internals

    private struct FilterParts {
        var joins: String
        var whereClause: String
        var params: [SQLValue]
    }

    private func filterParts(_ q: TransactionQuery) -> FilterParts {
        var joins = """
            LEFT JOIN payee_mapping pm ON pm.id = t.description
            LEFT JOIN category_mapping cm ON cm.id = t.category
            """
        var conditions = [
            "t.tombstone = 0",
            "t.isParent = 0",
            "t.date IS NOT NULL",
            "t.acct IS NOT NULL",
        ]
        var params: [SQLValue] = []

        if let accountID = q.accountID {
            conditions.append("t.acct = ?")
            params.append(.text(accountID))
        }
        if let categoryID = q.categoryID {
            conditions.append("COALESCE(cm.transferId, t.category) = ?")
            params.append(.text(categoryID))
        }
        if let payeeID = q.payeeID {
            conditions.append("COALESCE(pm.targetId, t.description) = ?")
            params.append(.text(payeeID))
        }
        let searchTerm = q.search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !searchTerm.isEmpty {
            joins += "\nLEFT JOIN payees p ON p.id = COALESCE(pm.targetId, t.description)"
            let pattern = Self.likePattern(searchTerm)
            conditions.append("(t.notes LIKE ? ESCAPE '\\' OR p.name LIKE ? ESCAPE '\\')")
            params.append(.text(pattern))
            params.append(.text(pattern))
        }
        if let months = q.months {
            conditions.append("t.date >= ?")
            params.append(.int(Int64(months.lowerBound.firstDay.raw)))
            conditions.append("t.date <= ?")
            params.append(.int(Int64(months.upperBound.lastDay.raw)))
        }
        if q.onlyUncategorized {
            // "Needs a category": on-budget, not a transfer, category unresolved.
            conditions.append("COALESCE(cm.transferId, t.category) IS NULL")
            conditions.append("t.transferred_id IS NULL")
            conditions.append("t.acct IN (SELECT id FROM accounts WHERE offbudget = 0 AND tombstone = 0)")
        }

        return FilterParts(
            joins: joins,
            whereClause: conditions.joined(separator: " AND "),
            params: params
        )
    }

    /// Escapes LIKE wildcards and wraps the term in %...% (queries pass ESCAPE '\').
    private static func likePattern(_ term: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(term.count + 2)
        for character in term {
            if character == "\\" || character == "%" || character == "_" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }

    /// Applies a winning message's value to its domain table. Returns false (without touching
    /// anything) for `prefs` and for any dataset/column not present in the opened file.
    private func applyToDomain(_ message: CRDTMessage) throws -> Bool {
        if message.dataset == "prefs" {
            return false
        }
        guard Self.isValidIdentifier(message.dataset),
              Self.isValidIdentifier(message.column),
              let columns = tableColumns[message.dataset],
              columns.contains(message.column) else {
            Self.log.debug("Skipping CRDT message for unhandled dataset/column in dataset \(message.dataset, privacy: .public)")
            return false
        }
        try db.run("INSERT OR IGNORE INTO \"\(message.dataset)\" (id) VALUES (?)", [.text(message.row)])
        try db.run("UPDATE \"\(message.dataset)\" SET \"\(message.column)\" = ? WHERE id = ?",
                   [message.value.sqlValue, .text(message.row)])
        return true
    }

    private static func message(from row: SQLRow) -> CRDTMessage? {
        guard let timestamp = row.string("timestamp"),
              let dataset = row.string("dataset"),
              let rowID = row.string("row"),
              let column = row.string("column") else { return nil }
        let encoded = row.string("value")
            ?? row.data("value").flatMap { String(data: $0, encoding: .utf8) }
            ?? "0:"
        return CRDTMessage(
            timestamp: timestamp,
            dataset: dataset,
            row: rowID,
            column: column,
            value: CRDTValue.decode(encoded)
        )
    }

    /// Discovers the domain tables (and their columns) present in the opened budget file.
    /// Internal bookkeeping tables are excluded; only id-keyed tables qualify, since CRDT
    /// messages address rows by `id`.
    private static func discoverTables(_ db: SQLiteDB) throws -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'", [])
        for row in tables {
            guard let name = row.string("name"), isValidIdentifier(name) else { continue }
            let lowered = name.lowercased()
            if lowered.hasPrefix("sqlite_") || lowered.hasPrefix("messages_")
                || lowered.hasPrefix("local_") || lowered.hasPrefix("kvcache")
                || lowered == "__migrations__" || lowered == "db_version" {
                continue
            }
            let info = try db.query("PRAGMA table_info(\"\(name)\")", [])
            var columns: Set<String> = []
            for columnRow in info {
                if let columnName = columnRow.string("name"), isValidIdentifier(columnName) {
                    columns.insert(columnName)
                }
            }
            if columns.contains("id") {
                result[name] = columns
            }
        }
        return result
    }

    /// True for strings safe to interpolate as quoted SQL identifiers: ASCII letters, digits,
    /// underscore; must not start with a digit; non-empty.
    private static func isValidIdentifier(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 128 else { return false }
        for (index, scalar) in s.unicodeScalars.enumerated() {
            switch scalar {
            case "a"..."z", "A"..."Z", "_":
                continue
            case "0"..."9":
                if index == 0 { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func int64(_ value: SQLValue?) -> Int64? {
        switch value {
        case .int(let i)?: return i
        case .real(let d)?: return d.isFinite ? Int64(exactly: d.rounded()) : nil
        case .text(let s)?: return Int64(s)
        default: return nil
        }
    }
}
