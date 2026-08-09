import Foundation

// MARK: - Schema
//
// DDL for the local bookkeeping tables Nidget maintains inside the budget's SQLite file.
//
// `messages_crdt` / `messages_clock` match Actual's own init.sql verbatim (docs/PROTOCOL.md §6.1);
// a freshly-downloaded budget file already contains them, so everything here is IF NOT EXISTS.
// (`column` is a SQLite keyword but is accepted unquoted in a column definition — Actual ships
// this exact DDL. Query code quotes `"row"`/`"column"` when referencing the columns.)
//
// `local_pending_messages` is Nidget's offline outbox: CRDT messages applied locally but not yet
// confirmed by the server. `value` stores the tagged `CRDTValue.encoded` string ("0:"/"N:…"/"S:…").
// Rows are deleted by `BudgetDatabase.clearPending(_:)` after a successful sync.

enum Schema {
    static func ensureLocalTables(_ db: SQLiteDB) throws {
        try db.exec("""
            CREATE TABLE IF NOT EXISTS messages_crdt
             (id INTEGER PRIMARY KEY,
              timestamp TEXT NOT NULL UNIQUE,
              dataset TEXT NOT NULL,
              row TEXT NOT NULL,
              column TEXT NOT NULL,
              value BLOB NOT NULL)
            """)
        // Speeds up the per-cell last-write-wins lookup in BudgetDatabase.apply(_:insertOnly:).
        // Actual creates the same index (same name) in its own init.sql, so this is a no-op on
        // freshly-downloaded files.
        try db.exec("""
            CREATE INDEX IF NOT EXISTS messages_crdt_search
              ON messages_crdt(dataset, "row", "column", timestamp)
            """)
        try db.exec("CREATE TABLE IF NOT EXISTS messages_clock (id INTEGER PRIMARY KEY, clock TEXT)")
        try db.exec("""
            CREATE TABLE IF NOT EXISTS local_pending_messages
             (timestamp TEXT PRIMARY KEY,
              dataset TEXT,
              row TEXT,
              column TEXT,
              value TEXT)
            """)
    }
}
