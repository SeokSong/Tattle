import Foundation
import SQLite3

// thin wrapper over the system sqlite. not thread safe: owned by one actor.
// error messages never include bound values.

public enum StorageError: Error, Equatable {
    case sqlite(code: Int32, message: String)
    case invalidData(String)
    case io(String)
    case newerSchema(found: Int, supported: Int)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Statement {
    private let handle: OpaquePointer
    private unowned let db: Database

    init(db: Database, sql: String) throws {
        var h: OpaquePointer?
        let rc = sqlite3_prepare_v2(db.handle, sql, -1, &h, nil)
        guard rc == SQLITE_OK, let h else { throw db.error(rc) }
        self.handle = h
        self.db = db
    }

    deinit { sqlite3_finalize(handle) }

    func reset() {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
    }

    func bind(_ i: Int32, _ v: String?) {
        if let v { sqlite3_bind_text(handle, i, v, -1, sqliteTransient) } else { sqlite3_bind_null(handle, i) }
    }

    func bind(_ i: Int32, _ v: Int?) {
        if let v { sqlite3_bind_int64(handle, i, Int64(v)) } else { sqlite3_bind_null(handle, i) }
    }

    func bind(_ i: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(handle, i, v) } else { sqlite3_bind_null(handle, i) }
    }

    func bind(_ i: Int32, blob v: [UInt8]?) {
        guard let v else { sqlite3_bind_null(handle, i); return }
        v.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(handle, i, raw.baseAddress ?? UnsafeRawPointer(bitPattern: 1), Int32(v.count), sqliteTransient)
        }
    }

    /// true while a row is available, false when done
    @discardableResult
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        throw db.error(rc)
    }

    /// runs a statement that returns no rows, then resets it
    func run() throws {
        defer { reset() }
        try step()
    }

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(handle, i) == SQLITE_NULL }

    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(handle, i)) }
    func optInt(_ i: Int32) -> Int? { isNull(i) ? nil : int(i) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(handle, i) }

    func text(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(handle, i) else { return nil }
        return String(cString: p)
    }

    func blob(_ i: Int32) -> [UInt8] {
        let n = Int(sqlite3_column_bytes(handle, i))
        guard n > 0, let p = sqlite3_column_blob(handle, i) else { return [] }
        return Array(UnsafeRawBufferPointer(start: p, count: n))
    }
}

final class Database {
    fileprivate var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]

    init(path: String) throws {
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK else {
            let e = error(rc)
            sqlite3_close_v2(handle)
            throw e
        }
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    func error(_ rc: Int32) -> StorageError {
        let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
        return .sqlite(code: rc, message: msg)
    }

    var lastInsertRowID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    func exec(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
    }

    /// prepared once, kept for the life of the database
    func statement(_ sql: String) throws -> Statement {
        if let s = cache[sql] { return s }
        let s = try Statement(db: self, sql: sql)
        cache[sql] = s
        return s
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("begin immediate")
        do {
            let result = try body()
            try exec("commit")
            return result
        } catch {
            try? exec("rollback")
            throw error
        }
    }
}
