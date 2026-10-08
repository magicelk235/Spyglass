import XCTest
@testable import SpyglassKit

final class DelimitedTextTests: XCTestCase {

    private func tsv(_ text: String, rowLimit: Int = DelimitedText.rowLimit) throws -> DelimitedTable {
        try DelimitedText.parse(Data(text.utf8), separator: "\t", rowLimit: rowLimit)
    }

    func testFirstRowIsTheHeader() throws {
        let table = try tsv("name\tage\nAda\t36\nLinus\t54\n")
        XCTAssertEqual(table.header, ["name", "age"])
        XCTAssertEqual(table.rows, [["Ada", "36"], ["Linus", "54"]])
        XCTAssertFalse(table.truncated)
    }

    func testQuotedFieldKeepsSeparatorsAndEscapedQuotes() throws {
        let table = try tsv("a\tb\n\"x\ty\"\t\"say \"\"hi\"\"\"\n")
        XCTAssertEqual(table.rows, [["x\ty", "say \"hi\""]])
    }

    func testQuotedFieldKeepsLineBreaks() throws {
        let table = try tsv("a\tb\n\"one\ntwo\r\nthree\"\tz\n")
        XCTAssertEqual(table.rows, [["one\ntwo\r\nthree", "z"]])
    }

    func testCRLFAndBareCRLineEnds() throws {
        XCTAssertEqual(try tsv("a\tb\r\n1\t2\r\n3\t4\r\n").rows, [["1", "2"], ["3", "4"]])
        XCTAssertEqual(try tsv("a\tb\r1\t2\r").rows, [["1", "2"]])
    }

    func testCRLFSplitAcrossChunksIsOneLineEnd() throws {
        // Put the CR as the last byte of the first chunk.
        let prefix = "h\n" + String(repeating: "x", count: DelimitedText.chunkSize - 3)
        let url = try temporaryFile(Data((prefix + "\r\nnext\r\n").utf8))
        let table = try DelimitedText.parse(contentsOf: url, separator: "\t")
        XCTAssertEqual(table.rows.map(\.first), [String(repeating: "x", count: DelimitedText.chunkSize - 3), "next"])
    }

    func testStripsUTF8BOM() throws {
        let table = try DelimitedText.parse(Data([0xEF, 0xBB, 0xBF] + Array("id\tv\n1\t2\n".utf8)), separator: "\t")
        XCTAssertEqual(table.header, ["id", "v"])
    }

    func testQuotedHeaderAfterBOM() throws {
        let table = try DelimitedText.parse(Data([0xEF, 0xBB, 0xBF] + Array("\"id\"\tv\n".utf8)), separator: "\t")
        XCTAssertEqual(table.header, ["id", "v"])
    }

    func testRaggedRowsArePaddedToTheWidestRow() throws {
        let table = try tsv("a\tb\n1\n1\t2\t3\n")
        XCTAssertEqual(table.header, ["a", "b", ""])
        XCTAssertEqual(table.rows, [["1", "", ""], ["1", "2", "3"]])
    }

    func testBlankLinesAreSkippedButEmptyFieldsKept() throws {
        let table = try tsv("a\tb\n\n1\t\n\n\t2\n")
        XCTAssertEqual(table.rows, [["1", ""], ["", "2"]])
    }

    func testLastRowWithoutTrailingNewline() throws {
        XCTAssertEqual(try tsv("a\n1\n2").rows, [["1"], ["2"]])
    }

    func testCommaSeparator() throws {
        let table = try DelimitedText.parse(Data("a,b\n\"1,5\",2\n".utf8), separator: ",")
        XCTAssertEqual(table.rows, [["1,5", "2"]])
    }

    func testTextAfterClosingQuoteAndStrayQuotesAreKept() throws {
        XCTAssertEqual(try tsv("a\tb\n\"x\"y\t5\"\n").rows, [["xy", "5\""]])
    }

    func testRowLimitStopsAndReportsTruncation() throws {
        let text = "n\n" + (1...5).map(String.init).joined(separator: "\n") + "\n"
        let exact = try tsv(text, rowLimit: 5)
        XCTAssertEqual(exact.rows.count, 5)
        XCTAssertFalse(exact.rowsTruncated)

        let cut = try tsv(text, rowLimit: 3)
        XCTAssertEqual(cut.rows, [["1"], ["2"], ["3"]])
        XCTAssertTrue(cut.rowsTruncated)
        XCTAssertFalse(cut.bytesTruncated)
    }

    func testRowLimitIgnoresTrailingBlankLines() throws {
        XCTAssertFalse(try tsv("n\n1\n2\n\n\n", rowLimit: 2).truncated)
    }

    func testRowLimitOnAFileStopsReadingEarly() throws {
        // A malformed tail past the limit is never read.
        let body = "n\n" + (1...20).map(String.init).joined(separator: "\n") + "\n\"unterminated"
        let url = try temporaryFile(Data(body.utf8))
        let table = try DelimitedText.parse(contentsOf: url, separator: "\t", rowLimit: 10)
        XCTAssertEqual(table.rows.count, 10)
        XCTAssertTrue(table.rowsTruncated)
    }

    func testByteLimitDropsThePartialRow() throws {
        let url = try temporaryFile(Data("h\nfirst\nsecond\nthird\n".utf8))
        // 14 bytes ends inside "second".
        let table = try DelimitedText.parse(contentsOf: url, separator: "\t", byteLimit: 14)
        XCTAssertEqual(table.rows, [["first"]])
        XCTAssertTrue(table.bytesTruncated)
        XCTAssertFalse(table.rowsTruncated)
    }

    func testFileExactlyAtTheByteLimitIsNotTruncated() throws {
        let data = Data("h\n1\n".utf8)
        let url = try temporaryFile(data)
        let table = try DelimitedText.parse(contentsOf: url, separator: "\t", byteLimit: data.count)
        XCTAssertEqual(table.rows, [["1"]])
        XCTAssertFalse(table.truncated)
    }

    func testColumnLimit() throws {
        let wide = (0...DelimitedText.columnLimit).map(String.init).joined(separator: "\t")
        let table = try tsv(wide + "\n")
        XCTAssertEqual(table.columnCount, DelimitedText.columnLimit)
        XCTAssertTrue(table.columnsTruncated)
    }

    func testInvalidUTF8Throws() {
        let data = Data(Array("a\tb\n1\t".utf8) + [0xC3, 0x28] + Array("\n".utf8))
        XCTAssertThrowsError(try DelimitedText.parse(data, separator: "\t")) { error in
            XCTAssertEqual(error as? DelimitedTextError, .invalidUTF8(row: 1))
        }
    }

    func testPartialBOMIsInvalidUTF8() {
        XCTAssertThrowsError(try DelimitedText.parse(Data([0xEF, 0xBB, 0x41, 0x0A]), separator: "\t"))
    }

    func testMultibyteTextSplitAcrossChunks() throws {
        // "é" straddles the chunk boundary.
        let filler = String(repeating: "x", count: DelimitedText.chunkSize - 3)
        let url = try temporaryFile(Data(("h\n" + filler + "é\n").utf8))
        let table = try DelimitedText.parse(contentsOf: url, separator: "\t")
        XCTAssertEqual(table.rows, [[filler + "é"]])
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try tsv("a\n\"never closed\n")) { error in
            XCTAssertEqual(error as? DelimitedTextError, .unterminatedQuote)
        }
    }

    func testNonASCIISeparatorIsRejected() {
        XCTAssertThrowsError(try DelimitedText.parse(Data(), separator: "→"))
        XCTAssertThrowsError(try DelimitedText.parse(Data(), separator: "\""))
    }

    func testEmptyInput() throws {
        let table = try tsv("")
        XCTAssertEqual(table.header, [])
        XCTAssertEqual(table.rows, [])
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DelimitedTextTests-\(UUID().uuidString).tsv")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
