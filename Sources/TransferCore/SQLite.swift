import Foundation
import SQLite3

/// A failed SQLite call: the extended result code and the operation, never SQL text or values.
public struct SQLiteError: Error, Equatable, Sendable {
    public let code: Int32
    public let operation: String
}

final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(path: String, flags: Int32) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let code = handle.map(sqlite3_extended_errcode) ?? result
            sqlite3_close_v2(handle)
            throw SQLiteError(code: code, operation: "open")
        }
        self.handle = handle
    }

    deinit { sqlite3_close_v2(handle) }

    var changes: Int64 { sqlite3_changes64(handle) }

    func execute(_ sql: String, operation: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error(operation) }
    }

    func prepare<Result>(_ sql: String, _ body: (Statement) throws -> Result) throws -> Result {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error("prepare")
        }
        defer { sqlite3_finalize(statement) }
        return try body(Statement(handle: statement))
    }

    /// BEGIN IMMEDIATE, so a writer waits for the lock before it reads what it will change.
    func write<Result>(_ body: () throws -> Result) throws -> Result {
        try transaction("BEGIN IMMEDIATE", body)
    }

    /// One snapshot for several statements.
    func read<Result>(_ body: () throws -> Result) throws -> Result {
        try transaction("BEGIN", body)
    }

    private func transaction<Result>(_ begin: String, _ body: () throws -> Result) throws -> Result {
        try execute(begin, operation: "begin")
        do {
            let result = try body()
            try execute("COMMIT", operation: "commit")
            return result
        } catch {
            // Some failures roll back by themselves; a second ROLLBACK would fail.
            if sqlite3_get_autocommit(handle) == 0 { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
            throw error
        }
    }

    private func error(_ operation: String) -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(handle), operation: operation)
    }
}

/// Valid only inside `SQLiteDatabase.prepare`. Parameters count from 1 and columns from 0.
struct Statement {
    // SQLITE_TRANSIENT is a C macro that Swift can't import: SQLite copies the value at once.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let handle: OpaquePointer

    fileprivate init(handle: OpaquePointer) { self.handle = handle }

    func bind(_ index: Int32, _ value: Int64) throws {
        try check(sqlite3_bind_int64(handle, index, value))
    }

    func bind(_ index: Int32, _ value: Int) throws { try bind(index, Int64(value)) }

    func bind(_ index: Int32, _ value: Bool) throws { try bind(index, Int64(value ? 1 : 0)) }

    func bind(_ index: Int32, _ value: Double) throws {
        try check(sqlite3_bind_double(handle, index, value))
    }

    func bind(_ index: Int32, _ value: String) throws {
        try check(sqlite3_bind_text(handle, index, value, Int32(value.utf8.count), Self.transient))
    }

    func bind(_ index: Int32, _ value: Data) throws {
        try check(value.withUnsafeBytes { bytes in
            // An empty buffer has no address, and a nil pointer would bind NULL.
            bytes.isEmpty ? sqlite3_bind_zeroblob(handle, index, 0)
                : sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        })
    }

    func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteError(code: sqlite3_extended_errcode(sqlite3_db_handle(handle)), operation: "step")
        }
    }

    func run() throws { while try step() {} }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }

    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(handle, column) }

    func bool(_ column: Int32) -> Bool { int64(column) != 0 }

    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }

    /// The exact UTF-8 bytes stored; "" for NULL.
    func text(_ column: Int32) -> String {
        // Text first: sqlite3_column_bytes then counts the UTF-8 form that it returned.
        guard let bytes = sqlite3_column_text(handle, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(handle, column))),
                      as: UTF8.self)
    }

    func blob(_ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(handle, column)))
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw SQLiteError(code: sqlite3_extended_errcode(sqlite3_db_handle(handle)), operation: "bind")
        }
    }
}
