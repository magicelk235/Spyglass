import XCTest
import SQLite3
@testable import SpyglassKit

final class SQLiteReaderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Builds a database with the normal (writable) API, then closes it.
    private func makeDatabase(_ sql: String, name: String = "fixture.sqlite") throws -> URL {
        let url = directory.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        if rc != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "\(rc)"
            sqlite3_free(error)
            throw NSError(domain: "fixture", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return url
    }

    private func sampleDatabase() throws -> URL {
        try makeDatabase("""
            CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT NOT NULL, price REAL, cover BLOB, notes);
            INSERT INTO books VALUES (1, 'SICP', 39.5, x'00010203', NULL);
            INSERT INTO books VALUES (2, 'TAOCP', NULL, NULL, 'three volumes');
            CREATE TABLE "odd ""name"" here"("select" TEXT, "a b" INT);
            INSERT INTO "odd ""name"" here" VALUES ('quoted', 7);
            CREATE VIEW cheap AS SELECT title FROM books WHERE price < 50;
            CREATE INDEX books_title ON books(title);
            """)
    }

    func testListsTablesThenViewsWithColumnTypes() throws {
        let reader = try SQLiteReader(url: sampleDatabase())
        let objects = try reader.objects()
        XCTAssertEqual(objects.map(\.name), ["books", "odd \"name\" here", "cheap"])
        XCTAssertEqual(objects.map(\.kind), [.table, .table, .view])
        XCTAssertEqual(objects[0].columns, [
            SQLiteColumn(name: "id", declaredType: "INTEGER"),
            SQLiteColumn(name: "title", declaredType: "TEXT"),
            SQLiteColumn(name: "price", declaredType: "REAL"),
            SQLiteColumn(name: "cover", declaredType: "BLOB"),
            SQLiteColumn(name: "notes", declaredType: ""),
        ])
    }

    func testLeavesOutSQLiteInternalTables() throws {
        // AUTOINCREMENT creates sqlite_sequence; ANALYZE creates sqlite_stat1.
        let url = try makeDatabase("""
            CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, v);
            INSERT INTO t(v) VALUES (1);
            CREATE INDEX t_v ON t(v);
            ANALYZE;
            """)
        XCTAssertEqual(try SQLiteReader(url: url).objects().map(\.name), ["t"])
    }

    func testReadsEveryValueType() throws {
        let rows = try SQLiteReader(url: sampleDatabase()).rows(of: "books")
        XCTAssertEqual(rows.columns, ["id", "title", "price", "cover", "notes"])
        XCTAssertEqual(rows.rows, [
            [.integer(1), .text("SICP", truncated: false), .real(39.5), .blob(bytes: 4), .null],
            [.integer(2), .text("TAOCP", truncated: false), .null, .null, .text("three volumes", truncated: false)],
        ])
        XCTAssertFalse(rows.truncated)
    }

    func testQuotesIdentifiers() throws {
        let reader = try SQLiteReader(url: sampleDatabase())
        let rows = try reader.rows(of: "odd \"name\" here")
        XCTAssertEqual(rows.columns, ["select", "a b"])
        XCTAssertEqual(rows.rows, [[.text("quoted", truncated: false), .integer(7)]])
        XCTAssertEqual(reader.rowCount(of: "odd \"name\" here"), .exact(1))
    }

    func testReadsViews() throws {
        let reader = try SQLiteReader(url: sampleDatabase())
        XCTAssertEqual(try reader.rows(of: "cheap").rows, [[.text("SICP", truncated: false)]])
        XCTAssertEqual(reader.rowCount(of: "cheap"), .exact(1))
    }

    func testRowLimit() throws {
        let url = try makeDatabase("""
            CREATE TABLE n(v INTEGER);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 600)
            INSERT INTO n SELECT x FROM c;
            """)
        let reader = try SQLiteReader(url: url)
        let rows = try reader.rows(of: "n")
        XCTAssertEqual(rows.rows.count, SQLiteReader.rowLimit)
        XCTAssertEqual(rows.rows.last, [.integer(Int64(SQLiteReader.rowLimit))])
        XCTAssertTrue(rows.truncated)
        XCTAssertEqual(try reader.rows(of: "n", limit: 600).truncated, false)
        XCTAssertEqual(reader.rowCount(of: "n"), .exact(600))
    }

    func testSlowCountGivesUpWithALowerBound() throws {
        // count(*) over a cross join takes far longer than the deadline, but
        // the first 501 rows arrive at once.
        let url = try makeDatabase("""
            CREATE TABLE n(v INTEGER);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3000)
            INSERT INTO n SELECT x FROM c;
            CREATE VIEW slow AS SELECT a.v FROM n a, n b, n c;
            """)
        let reader = try SQLiteReader(url: url)
        let started = Date()
        XCTAssertEqual(reader.rowCount(of: "slow", timeout: 0.1), .atLeast(SQLiteReader.rowLimit))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    func testSlowViewsTimeOut() throws {
        // Every row is filtered out, so even the capped count must scan it all.
        let url = try makeDatabase("""
            CREATE TABLE n(v INTEGER);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3000)
            INSERT INTO n SELECT x FROM c;
            CREATE VIEW never AS SELECT a.v FROM n a, n b, n c WHERE a.v + b.v + c.v < 0;
            """)
        let reader = try SQLiteReader(url: url)
        XCTAssertEqual(reader.rowCount(of: "never", timeout: 0.1), .unknown)
        let started = Date()
        XCTAssertThrowsError(try reader.rows(of: "never", timeout: 0.1)) { error in
            XCTAssertEqual(error as? SQLiteReaderError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        // The handler is removed afterwards: normal queries still work.
        XCTAssertEqual(try reader.rows(of: "n", limit: 1).rows, [[.integer(1)]])
    }

    func testLongTextIsCutOnACharacterBoundary() throws {
        // 2047 ASCII bytes then "é": the byte limit lands inside the "é".
        let long = String(repeating: "a", count: SQLiteReader.textByteLimit - 1) + "é" + "tail"
        let url = try makeDatabase("CREATE TABLE t(s TEXT); INSERT INTO t VALUES ('\(long)');")
        let rows = try SQLiteReader(url: url).rows(of: "t")
        XCTAssertEqual(rows.rows, [[.text(String(repeating: "a", count: SQLiteReader.textByteLimit - 1), truncated: true)]])
    }

    func testReadsWALDatabaseWithoutCreatingSidecarFiles() throws {
        let url = try makeDatabase("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE t(v); INSERT INTO t VALUES (1);
            PRAGMA wal_checkpoint(TRUNCATE);
            """)
        // As if the database were copied without its -wal/-shm files.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        let reader = try SQLiteReader(url: url)
        XCTAssertEqual(try reader.rows(of: "t").rows, [[.integer(1)]])
        XCTAssertEqual(reader.rowCount(of: "t"), .exact(1))
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files, ["fixture.sqlite"])
    }

    func testPathNeedingPercentEncoding() throws {
        let url = try makeDatabase("CREATE TABLE t(v); INSERT INTO t VALUES (1);", name: "what?#100% sure.db")
        XCTAssertEqual(try SQLiteReader(url: url).objects().map(\.name), ["t"])
    }

    func testEmptyDatabaseHasNoObjects() throws {
        // A freshly created file with a table that was dropped still has the header.
        let url = try makeDatabase("CREATE TABLE t(v); DROP TABLE t;")
        XCTAssertEqual(try SQLiteReader(url: url).objects(), [])
    }

    func testNonSQLiteFileThrows() throws {
        let url = directory.appendingPathComponent("plain.db")
        try Data("plain bytes, not a database.\n".utf8).write(to: url)
        XCTAssertThrowsError(try SQLiteReader(url: url)) { error in
            XCTAssertEqual(error as? SQLiteReaderError, .notSQLite)
        }
    }

    func testZeroLengthFileThrows() throws {
        let url = directory.appendingPathComponent("empty.db")
        try Data().write(to: url)
        XCTAssertThrowsError(try SQLiteReader(url: url)) { error in
            XCTAssertEqual(error as? SQLiteReaderError, .notSQLite)
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try SQLiteReader(url: directory.appendingPathComponent("nope.db")))
    }

    func testHeaderOnlyFileThrows() throws {
        let source = try Data(contentsOf: sampleDatabase())
        let url = directory.appendingPathComponent("header-only.db")
        try source.prefix(100).write(to: url)
        XCTAssertThrowsError(try SQLiteReader(url: url))
    }

    func testTruncatedFileThrowsOnOpenOrRead() throws {
        // Lots of rows so the table spans many pages, then cut the file short.
        let full = try makeDatabase("""
            CREATE TABLE big(v TEXT);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 2000)
            INSERT INTO big SELECT printf('row %d %s', x, hex(randomblob(20))) FROM c;
            """)
        let data = try Data(contentsOf: full)
        let url = directory.appendingPathComponent("truncated.db")
        try data.prefix(data.count / 3).write(to: url)
        XCTAssertThrowsError(try {
            let reader = try SQLiteReader(url: url)
            for object in try reader.objects() { _ = try reader.rows(of: object.name, limit: 10_000) }
        }())
    }

    func testCorruptSchemaPageThrows() throws {
        var data = try Data(contentsOf: sampleDatabase())
        // Scribble over page 1 after the 100-byte file header, where the
        // schema table's b-tree page header lives.
        for i in 100..<min(data.count, 4096) { data[i] = 0xA5 }
        let url = directory.appendingPathComponent("corrupt.db")
        try data.write(to: url)
        XCTAssertThrowsError(try SQLiteReader(url: url)) { error in
            guard case .sqlite = error as? SQLiteReaderError else {
                return XCTFail("expected an SQLite error, got \(error)")
            }
        }
    }

    func testFileURI() {
        let uri = SQLiteReader.immutableURI(for: URL(fileURLWithPath: "/tmp/a b/c?d#e%f.db"))
        XCTAssertEqual(uri, "file:/tmp/a%20b/c%3Fd%23e%25f.db?immutable=1")
    }

    func testQuoteIdentifier() {
        XCTAssertEqual(SQLiteReader.quoteIdentifier("plain"), "\"plain\"")
        XCTAssertEqual(SQLiteReader.quoteIdentifier("say \"hi\""), "\"say \"\"hi\"\"\"")
    }
}
