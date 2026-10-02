import Foundation
import SQLite3

/// A minimal SQLite wrapper for the session index. Each connection is used from a single
/// queue; the index uses one for writing and one for searching (WAL lets them overlap).
final class SQLiteConnection {
    enum Error: Swift.Error, CustomStringConvertible {
        case sqlite(String)
        var description: String {
            switch self { case .sqlite(let message): return message }
        }
    }

    private let db: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]

    init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(handle)
            throw Error.sqlite(message)
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(db)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    func run(_ sql: String, _ args: [Any?] = []) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_reset(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error() }
    }

    func query(_ sql: String, _ args: [Any?] = [], _ row: (Row) -> Void) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_reset(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw error() }
            row(Row(statement: statement))
        }
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    struct Row {
        let statement: OpaquePointer

        func int(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
        func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
        func string(_ index: Int32) -> String? {
            guard let text = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: text)
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw error() }
            statements[sql] = prepared
            statement = prepared
        }

        sqlite3_clear_bindings(statement)
        for (offset, arg) in args.enumerated() {
            let index = Int32(offset + 1)
            switch arg {
            case nil: sqlite3_bind_null(statement, index)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            default: sqlite3_bind_text(statement, index, "\(arg!)", -1, Self.transient)
            }
        }
        return statement
    }

    private func error() -> Error {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
