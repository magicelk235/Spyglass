import XCTest
@testable import SpyglassKit

final class JSONLinesTests: XCTestCase {

    private typealias Value = JSONLinesTable.Value

    private func parse(_ text: String, rowLimit: Int = JSONLines.rowLimit) throws -> JSONLinesTable {
        try JSONLines.parse(Data(text.utf8), rowLimit: rowLimit)
    }

    private func values(_ table: JSONLinesTable) -> [[Value?]] {
        table.rows.compactMap { row in
            if case .values(_, let values) = row { return values }
            return nil
        }
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONLinesTests-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func assertThrows(_ text: String, _ expected: JSONLinesError,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), file: file, line: line) { error in
            XCTAssertEqual(error as? JSONLinesError, expected, file: file, line: line)
        }
    }

    // MARK: - Columns and values

    func testColumnsAreTheUnionOfKeysInFirstSeenOrder() throws {
        let table = try parse("{\"b\":1,\"a\":2}\n{\"a\":3,\"c\":4}\n")
        XCTAssertEqual(table.columns, ["b", "a", "c"])
        XCTAssertEqual(values(table), [
            [.number("1", 1), .number("2", 2), nil],
            [nil, .number("3", 3), .number("4", 4)],
        ])
        XCTAssertFalse(table.truncated)
    }

    func testValueTypes() throws {
        let line = #"{"s":"x","n":1.50,"i":-3,"e":2E3,"t":true,"f":false,"z":null,"o":{"k": [1, 2]},"a":[ "a" , {"b":null} ]}"#
        let table = try parse(line)
        XCTAssertEqual(table.columns, ["s", "n", "i", "e", "t", "f", "z", "o", "a"])
        XCTAssertEqual(values(table), [[
            .string("x"), .number("1.50", 1.5), .number("-3", -3), .number("2E3", 2000),
            .bool(true), .bool(false), .null,
            .nested(#"{"k":[1,2]}"#), .nested(#"["a",{"b":null}]"#),
        ]])
    }

    func testNestedJSONKeepsWhitespaceInsideStrings() throws {
        let table = try parse(#"{"o": {"msg" : "a  b , c"} }"#)
        XCTAssertEqual(values(table), [[.nested(#"{"msg":"a  b , c"}"#)]])
    }

    func testStringEscapesAreDecoded() throws {
        let table = try parse(#"{"a\"b":"one\ntwo \"q\" \u00e9 \ud83d\ude00 \/ \\ \t"}"#)
        XCTAssertEqual(table.columns, ["a\"b"])
        XCTAssertEqual(values(table), [[.string("one\ntwo \"q\" é 😀 / \\ \t")]])
    }

    func testDuplicateKeyKeepsTheLastValue() throws {
        let table = try parse(#"{"a":1,"b":2,"a":3}"#)
        XCTAssertEqual(table.columns, ["a", "b"])
        XCTAssertEqual(values(table), [[.number("3", 3), .number("2", 2)]])
    }

    func testLongValuesAreCut() throws {
        let long = String(repeating: "x", count: JSONLines.valueLimit + 50)
        let table = try parse("{\"a\":\"\(long)\"}")
        guard case .string(let text)? = values(table).first?.first else { return XCTFail("no string") }
        XCTAssertEqual(text, String(repeating: "x", count: JSONLines.valueLimit) + "…")
    }

    // MARK: - Lines

    func testBlankLinesAreSkippedAndLinesAreNumberedAsInTheFile() throws {
        let table = try parse("\n{\"a\":1}\n   \n{\"a\":2}\r\n\t\n")
        XCTAssertEqual(table.rows, [
            .values(line: 2, [.number("1", 1)]),
            .values(line: 4, [.number("2", 2)]),
        ])
    }

    func testLastLineWithoutNewline() throws {
        XCTAssertEqual(values(try parse("{\"a\":1}\n{\"a\":2}")).count, 2)
    }

    func testStripsUTF8BOM() throws {
        let table = try JSONLines.parse(Data([0xEF, 0xBB, 0xBF] + Array("{\"id\":1}\n".utf8)))
        XCTAssertEqual(table.columns, ["id"])
    }

    func testLineSplitAcrossReadChunksParses() throws {
        let filler = String(repeating: "y", count: JSONLines.chunkSize)
        let text = "{\"a\":\"start\"}\n{\"a\":\"\(filler)\",\"b\":2}\n{\"a\":\"end\"}\n"
        let table = try JSONLines.parse(contentsOf: try temporaryFile(Data(text.utf8)))
        XCTAssertEqual(table.columns, ["a", "b"])
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertEqual(values(table).last, [.string("end"), nil])
    }

    // MARK: - Bad lines

    func testInvalidLineBecomesAnErrorRow() throws {
        var lines = (1...20).map { "{\"n\":\($0)}" }
        lines.insert("{\"n\": oops}", at: 10)
        let table = try parse(lines.joined(separator: "\n"))
        XCTAssertEqual(table.rows.count, 21)
        XCTAssertEqual(table.invalidCount, 1)
        guard case .invalid(let line, let reason) = table.rows[10] else { return XCTFail("row 11 should be invalid") }
        XCTAssertEqual(line, 11)
        // The "o" of "oops" is the 7th character on the line.
        XCTAssertTrue(reason.hasPrefix("Invalid JSON at column 7: "), reason)
        XCTAssertEqual(table.rows[11], .values(line: 12, [.number("11", 11)]))
    }

    func testErrorColumnCountsTheLinesLeadingWhitespace() throws {
        let lines = (1...10).map { "{\"n\":\($0)}" } + ["   {\"n\": oops}"]
        guard case .invalid(_, let reason)? = try parse(lines.joined(separator: "\n")).rows.last else {
            return XCTFail("last row should be invalid")
        }
        XCTAssertTrue(reason.hasPrefix("Invalid JSON at column 10: "), reason)
    }

    func testLaterNonObjectLineIsAnErrorRow() throws {
        let lines = (1...10).map { "{\"n\":\($0)}" } + ["[1,2]"]
        let table = try parse(lines.joined(separator: "\n"))
        XCTAssertEqual(table.invalidCount, 1)
        XCTAssertEqual(table.rows.last, .invalid(line: 11, reason: "An array, not an object"))
    }

    func testTenPercentBadLinesIsAccepted() throws {
        let lines = (1...9).map { "{\"n\":\($0)}" } + ["nope"]
        XCTAssertEqual(try parse(lines.joined(separator: "\n")).invalidCount, 1)
    }

    func testMoreThanTenPercentBadLinesThrows() {
        let lines = (1...9).map { "{\"n\":\($0)}" } + ["nope", "{broken"]
        assertThrows(lines.joined(separator: "\n"), .tooManyInvalidLines(invalid: 2, total: 11))
    }

    func testNothingButGarbageThrows() {
        assertThrows("hello\nworld\n", .tooManyInvalidLines(invalid: 2, total: 2))
    }

    func testArraysAndScalarsAreNotTabular() {
        assertThrows("[1,2]\n[3,4]\n", .notTabular)
        assertThrows("42\n43\n", .notTabular)
        assertThrows("\"text\"\n", .notTabular)
        // A broken first line doesn't decide: the first value that parses does.
        assertThrows("{oops\n[1]\n", .notTabular)
    }

    func testObjectsWithoutKeysAreNotTabular() {
        assertThrows("{}\n{}\n", .notTabular)
    }

    func testEmptyInputThrows() {
        assertThrows("", .empty)
        assertThrows("\n  \n\r\n", .empty)
    }

    // MARK: - Limits

    func testRowLimitStopsAndReportsTruncation() throws {
        let text = (1...5).map { "{\"n\":\($0)}" }.joined(separator: "\n")
        let exact = try parse(text, rowLimit: 5)
        XCTAssertEqual(exact.rows.count, 5)
        XCTAssertFalse(exact.rowsTruncated)

        let cut = try parse(text, rowLimit: 3)
        XCTAssertEqual(cut.rows.count, 3)
        XCTAssertTrue(cut.rowsTruncated)
        XCTAssertFalse(cut.bytesTruncated)
    }

    func testByteLimitDropsThePartialLine() throws {
        let text = "{\"a\":1}\n{\"a\":2}\n{\"a\":333333}\n"
        let url = try temporaryFile(Data(text.utf8))
        // The limit falls inside the third line.
        let table = try JSONLines.parse(contentsOf: url, byteLimit: 20)
        XCTAssertEqual(values(table), [[.number("1", 1)], [.number("2", 2)]])
        XCTAssertTrue(table.bytesTruncated)
        XCTAssertFalse(table.rowsTruncated)

        let whole = try JSONLines.parse(contentsOf: url, byteLimit: text.utf8.count)
        XCTAssertEqual(whole.rows.count, 3)
        XCTAssertFalse(whole.bytesTruncated)
    }

    func testColumnLimit() throws {
        let keys = (0..<(JSONLines.columnLimit + 5)).map { "\"k\($0)\":\($0)" }
        let table = try parse("{" + keys.joined(separator: ",") + "}\n{\"k0\":1,\"extra\":2}\n")
        XCTAssertEqual(table.columns.count, JSONLines.columnLimit)
        XCTAssertTrue(table.columnsTruncated)
        XCTAssertEqual(values(table)[1].first, .number("1", 1))
    }

    func testUnreadableFileThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jsonl")
        XCTAssertThrowsError(try JSONLines.parse(contentsOf: missing)) { error in
            XCTAssertEqual(error as? JSONLinesError, .unreadable)
        }
    }

    func testReadsTheSampleFixture() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("samples/formats/events.jsonl")
        let table = try JSONLines.parse(contentsOf: url)
        XCTAssertGreaterThan(table.rows.count, 10)
        XCTAssertEqual(table.invalidCount, 1)
        XCTAssertFalse(table.truncated)
    }
}
