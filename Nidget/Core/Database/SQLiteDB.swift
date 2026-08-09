import Foundation
import SQLite3
import os

// MARK: - SQLValue
//
// A dynamically-typed SQLite value mirroring SQLite's five storage classes.

enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

// MARK: - SQLRow
//
// One result row: column name → value, with lenient typed accessors that coerce between
// SQLite's dynamic storage classes (a value CRDT-written as REAL can still be read as Int64).

struct SQLRow: Sendable {
    let values: [String: SQLValue]

    init(values: [String: SQLValue]) {
        self.values = values
    }

    subscript(_ column: String) -> SQLValue? { values[column] }

    func string(_ column: String) -> String? {
        switch values[column] {
        case .text(let s): return s
        case .int(let i): return String(i)
        case .real(let d): return String(d)
        default: return nil
        }
    }

    func int(_ column: String) -> Int64? {
        switch values[column] {
        case .int(let i): return i
        case .real(let d): return d.isFinite ? Int64(exactly: d.rounded()) : nil
        case .text(let s): return Int64(s)
        default: return nil
        }
    }

    func double(_ column: String) -> Double? {
        switch values[column] {
        case .real(let d): return d
        case .int(let i): return Double(i)
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    func data(_ column: String) -> Data? {
        switch values[column] {
        case .blob(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }
}

// MARK: - DBError

enum DBError: Error, LocalizedError, Equatable, Sendable {
    case openFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case execFailed(String)
    case closed

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "Could not open the database: \(message)"
        case .prepareFailed(let message): return "Could not prepare a database statement: \(message)"
        case .bindFailed(let message): return "Could not bind a database parameter: \(message)"
        case .stepFailed(let message): return "A database statement failed: \(message)"
        case .execFailed(let message): return "A database command failed: \(message)"
        case .closed: return "The database connection is closed."
        }
    }
}

// MARK: - SQLiteDB

/// `SQLITE_TRANSIENT` tells sqlite to copy bound text/blob bytes immediately, so Swift-managed
/// buffers may be released as soon as the bind call returns.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Thin wrapper over the sqlite3 C API. Opened with `SQLITE_OPEN_FULLMUTEX` so the handle itself
/// is thread-safe; all Nidget access is additionally serialized behind `DatabaseQueue`.
final class SQLiteDB {
    private var handle: OpaquePointer?
    private static let log = Logger(subsystem: "app.nidget", category: "database")

    /// Opens (or creates) the database at `path` with RW|CREATE|FULLMUTEX, switches to WAL
    /// journaling, sets a 5s busy timeout, and leaves foreign-key enforcement off (Actual's
    /// budget files rely on soft tombstones, not FK cascades).
    init(path: String) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &opened, flags, nil)
        guard rc == SQLITE_OK, let db = opened else {
            let message: String
            if let db = opened {
                message = String(cString: sqlite3_errmsg(db))
                sqlite3_close_v2(db)
            } else {
                message = "out of memory opening database (code \(rc))"
            }
            throw DBError.openFailed(message)
        }
        handle = db
        do {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA busy_timeout=5000")
            try exec("PRAGMA foreign_keys=OFF")
        } catch {
            sqlite3_close_v2(db)
            handle = nil
            throw error
        }
    }

    deinit {
        close()
    }

    /// Runs one or more semicolon-separated statements that take no parameters.
    func exec(_ sql: String) throws {
        guard let handle else { throw DBError.closed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "sqlite error code \(rc)"
            sqlite3_free(errorMessage)
            throw DBError.execFailed(message)
        }
    }

    /// Runs a single parameterized statement that returns no rows (INSERT/UPDATE/DELETE).
    func run(_ sql: String, _ params: [SQLValue]) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError.stepFailed(lastMessage())
        }
    }

    /// Runs a parameterized SELECT and materializes every row.
    func query(_ sql: String, _ params: [SQLValue]) throws -> [SQLRow] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            if let cName = sqlite3_column_name(statement, Int32(index)) {
                names.append(String(cString: cName))
            } else {
                names.append("column\(index)")
            }
        }

        var rows: [SQLRow] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW {
                var values: [String: SQLValue] = [:]
                values.reserveCapacity(columnCount)
                for index in 0..<columnCount {
                    values[names[index]] = columnValue(statement, Int32(index))
                }
                rows.append(SQLRow(values: values))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw DBError.stepFailed(lastMessage())
            }
        }
        return rows
    }

    /// Runs a parameterized SELECT and returns the first column of the first row,
    /// or nil when the statement produces no rows at all.
    func scalar(_ sql: String, _ params: [SQLValue]) throws -> SQLValue? {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        if rc == SQLITE_ROW {
            guard sqlite3_column_count(statement) > 0 else { return nil }
            return columnValue(statement, 0)
        } else if rc == SQLITE_DONE {
            return nil
        }
        throw DBError.stepFailed(lastMessage())
    }

    /// BEGIN IMMEDIATE / COMMIT, with ROLLBACK when `body` throws. Not reentrant.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            let original = error
            do {
                try exec("ROLLBACK")
            } catch {
                Self.log.error("Rollback failed after a transaction error")
            }
            throw original
        }
    }

    var lastInsertRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    // MARK: Internals

    private func prepare(_ sql: String, _ params: [SQLValue]) throws -> OpaquePointer {
        guard let handle else { throw DBError.closed }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DBError.prepareFailed(lastMessage())
        }
        for (index, value) in params.enumerated() {
            let position = Int32(index + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, position)
            case .int(let i):
                rc = sqlite3_bind_int64(statement, position, i)
            case .real(let d):
                rc = sqlite3_bind_double(statement, position, d)
            case .text(let s):
                rc = sqlite3_bind_text(statement, position, s, -1, SQLITE_TRANSIENT)
            case .blob(let d):
                if d.isEmpty {
                    rc = sqlite3_bind_zeroblob(statement, position, 0)
                } else {
                    rc = d.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(d.count), SQLITE_TRANSIENT)
                    }
                }
            }
            guard rc == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw DBError.bindFailed(lastMessage())
            }
        }
        return statement
    }

    private func columnValue(_ statement: OpaquePointer, _ index: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index))
        case SQLITE3_TEXT:
            if let cString = sqlite3_column_text(statement, index) {
                return .text(String(cString: cString))
            }
            return .null
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            if count > 0, let bytes = sqlite3_column_blob(statement, index) {
                return .blob(Data(bytes: bytes, count: count))
            }
            return .blob(Data())
        default:
            return .null
        }
    }

    private func lastMessage() -> String {
        guard let handle else { return "database closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}
