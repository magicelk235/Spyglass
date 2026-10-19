import Foundation
import SQLite3

public enum SQLiteReaderError: Error, Equatable {
    /// The file doesn't start with the SQLite header (plenty of `.db` files
    /// are something else, and encrypted databases look like noise).
    case notSQLite
    case unreadable
    /// SQLite refused the file or a query: corrupt, truncated, or using a
    /// feature this build of SQLite lacks.
    case sqlite(code: Int32, message: String)
    /// A query ran past its deadline and was interrupted.
    case timedOut
}

public struct SQLiteColumn: Equatable, Sendable {
    public var name: String
    /// As written in the schema; empty when the column has none.
    public var declaredType: String
}

public struct SQLiteObject: Equatable, Sendable {
    public enum Kind: String, Sendable { case table, view }
    public var name: String
    public var kind: Kind
    public var columns: [SQLiteColumn]
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    /// `truncated` means the stored text was longer than the display limit.
    case text(String, truncated: Bool)
    /// Only the size is kept.
    case blob(bytes: Int)
}

public struct SQLiteRows: Equatable, Sendable {
    public var columns: [String]
    public var rows: [[SQLiteValue]]
    /// The table has more rows than were read.
    public var truncated: Bool
}

public enum SQLiteRowCount: Equatable, Sendable {
    case exact(Int)
    /// Counting took too long, but there are at least this many rows.
    case atLeast(Int)
    case unknown
}

/// Read-only access to a SQLite file: the table and view list, column
/// types, and the first few hundred rows of each.
///
/// The database is opened `immutable`, so SQLite takes no locks and never
/// creates `-wal`/`-shm` files; the Quick Look sandbox can't write next to
/// the previewed file. A WAL database is read as of its last checkpoint.
///
/// One connection, guarded by a lock, so a reader can be shared between
/// tasks.
public final class SQLiteReader: @unchecked Sendable {

    public static let rowLimit = 500
    /// Longer text values are cut to this many UTF-8 bytes for display.
    public static let textByteLimit = 2_048

    private static let header = Array("SQLite format 3\0".utf8)

    private let lock = NSLock()
    private let db: OpaquePointer

    /// Checks the header, opens the file, and reads the schema once so a
    /// corrupt or unreadable file fails here rather than later.
    public init(url: URL) throws {
        guard try Self.hasSQLiteHeader(url) else { throw SQLiteReaderError.notSQLite }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(Self.immutableURI(for: url), &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(handle)
            throw SQLiteReaderError.sqlite(code: rc, message: message)
        }
        db = handle
        sqlite3_extended_result_codes(db, 1)
        // Walks the schema table: fails with SQLITE_NOTADB / SQLITE_CORRUPT
        // on a damaged file.
        _ = try locked { try scalarInt("SELECT count(*) FROM sqlite_schema") }
    }

    deinit {
        sqlite3_close_v2(db)
    }

    static func hasSQLiteHeader(_ url: URL) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw SQLiteReaderError.unreadable }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: header.count) ?? Data()
        } catch {
            throw SQLiteReaderError.unreadable
        }
        return Array(data) == header
    }

    /// `file:` URI for `url` with `immutable=1`. Everything but unreserved
    /// characters and `/` is percent-encoded, so `?`, `#` and `%` in a
    /// filename can't be read as URI syntax.
    static func immutableURI(for url: URL) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~/")
        let path = url.path.addingPercentEncoding(withAllowedCharacters: allowed) ?? url.path
        return "file:\(path)?immutable=1"
    }

    /// Tables first, then views, each sorted by name. SQLite's own
    /// `sqlite_*` tables are left out.
    public func objects() throws -> [SQLiteObject] {
        try locked {
            var found: [(String, SQLiteObject.Kind)] = []
            try query("""
                SELECT name, type FROM sqlite_schema
                WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
                ORDER BY type = 'view', name COLLATE NOCASE
                """) { stmt in
                let name = Self.text(stmt, 0)
                found.append((name, Self.text(stmt, 1) == "view" ? .view : .table))
            }
            return found.map { name, kind in
                // A view over a missing table, or a virtual table whose module
                // this SQLite lacks, can't report columns. Its rows fail later
                // with a proper error; the rest of the database still lists.
                var columns: [SQLiteColumn] = []
                try? query("SELECT name, type FROM pragma_table_info(?1)", bind: [name]) { stmt in
                    columns.append(SQLiteColumn(name: Self.text(stmt, 0), declaredType: Self.text(stmt, 1)))
                }
                return SQLiteObject(name: name, kind: kind, columns: columns)
            }
        }
    }

    /// The first `limit` rows of a table or view, in storage order. A view
    /// can be any query at all, so reading gives up after `timeout` seconds.
    public func rows(of name: String, limit: Int = rowLimit, timeout: TimeInterval = 5) throws -> SQLiteRows {
        try locked {
            try withDeadline(timeout) { try readRows(of: name, limit: limit) }
        }
    }

    private func readRows(of name: String, limit: Int) throws -> SQLiteRows {
        var stmt: OpaquePointer?
        let sql = "SELECT * FROM \(Self.quoteIdentifier(name)) LIMIT \(max(0, limit) + 1)"
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        defer { sqlite3_finalize(stmt) }
        let count = Int(sqlite3_column_count(stmt))
        let columns = (0..<count).map { i in
            sqlite3_column_name(stmt, Int32(i)).map { String(cString: $0) } ?? ""
        }
        var rows: [[SQLiteValue]] = []
        var truncated = false
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc == SQLITE_INTERRUPT { throw SQLiteReaderError.timedOut }
            try check(rc, expected: SQLITE_ROW)
            if rows.count == limit {
                truncated = true
                break
            }
            rows.append((0..<count).map { Self.value(stmt, Int32($0)) })
        }
        return SQLiteRows(columns: columns, rows: rows, truncated: truncated)
    }

    /// Counts the rows of `name`, giving up after roughly `timeout` seconds.
    /// A count that runs out of time reports `.atLeast(limit)` when a capped
    /// count finishes, else `.unknown`.
    public func rowCount(of name: String, timeout: TimeInterval = 0.5, limit: Int = rowLimit) -> SQLiteRowCount {
        locked {
            let table = Self.quoteIdentifier(name)
            if let count = try? withDeadline(timeout, { try scalarInt("SELECT count(*) FROM \(table)") }) {
                return .exact(count)
            }
            // A view can be arbitrarily slow; a capped count often isn't.
            let capped = "SELECT count(*) FROM (SELECT 1 FROM \(table) LIMIT \(limit + 1))"
            if let count = try? withDeadline(timeout, { try scalarInt(capped) }) {
                return count > limit ? .atLeast(limit) : .exact(count)
            }
            return .unknown
        }
    }

    /// `"name"` with embedded quotes doubled.
    static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Statement helpers (call with the lock held)

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func check(_ rc: Int32, expected: Int32 = SQLITE_OK) throws {
        guard rc != expected else { return }
        throw SQLiteReaderError.sqlite(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }

    private func query(_ sql: String, bind: [String] = [], row: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &stmt, nil))
        defer { sqlite3_finalize(stmt) }
        guard let stmt else { return }  // empty statement
        for (i, value) in bind.enumerated() {
            try check(sqlite3_bind_text(stmt, Int32(i + 1), value, -1, Self.transient))
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            try check(rc, expected: SQLITE_ROW)
            try row(stmt)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var result = 0
        try query(sql) { stmt in result = Int(sqlite3_column_int64(stmt, 0)) }
        return result
    }

    /// Runs `body` with a progress handler that interrupts any statement
    /// still running after `seconds`.
    private func withDeadline<T>(_ seconds: TimeInterval, _ body: () throws -> T) throws -> T {
        let deadline = Unmanaged.passRetained(Deadline(seconds))
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            deadline.release()
        }
        sqlite3_progress_handler(db, 1_000, { context in
            guard let context else { return 0 }
            return Unmanaged<Deadline>.fromOpaque(context).takeUnretainedValue().passed ? 1 : 0
        }, deadline.toOpaque())
        return try body()
    }

    private final class Deadline {
        let end: UInt64
        init(_ seconds: TimeInterval) {
            end = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
        }
        var passed: Bool { DispatchTime.now().uptimeNanoseconds >= end }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func text(_ stmt: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? ""
    }

    private static func value(_ stmt: OpaquePointer?, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(stmt, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, column))
        case SQLITE_BLOB:
            return .blob(bytes: Int(sqlite3_column_bytes(stmt, column)))
        case SQLITE_TEXT:
            guard let raw = sqlite3_column_text(stmt, column) else { return .text("", truncated: false) }
            let length = Int(sqlite3_column_bytes(stmt, column))
            var end = min(length, textByteLimit)
            let truncated = end < length
            // Don't cut a multi-byte character in half.
            while truncated, end > 0, raw[end] & 0xC0 == 0x80 { end -= 1 }
            let text = String(decoding: UnsafeBufferPointer(start: raw, count: end), as: UTF8.self)
            return .text(text, truncated: truncated)
        default:
            return .null
        }
    }
}
