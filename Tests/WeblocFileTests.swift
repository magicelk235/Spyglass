import XCTest
@testable import SpyglassKit

/// Exercises the whole `.webloc` path through the filesystem: real binary plist
/// on disk, read by `StubParser.parse(fileAt:)`, which is what the scanner and
/// the Quick Look extension both call.
final class WeblocFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("webloc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, url: String) throws -> URL {
        let file = dir.appendingPathComponent(name)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": url], format: .binary, options: 0)
        try data.write(to: file)
        return file
    }

    func testTitleComesFromFilename() throws {
        let file = try write(
            "Quarterly Report.webloc",
            url: "https://docs.google.com/document/d/DOC1/edit")
        let stub = try StubParser.parse(fileAt: file)
        XCTAssertEqual(stub.title, "Quarterly Report")
        XCTAssertEqual(stub.type, .doc)
        XCTAssertEqual(stub.docID, "DOC1")
    }

    func testSpreadsheetWeblocResolvesToSheet() throws {
        let file = try write(
            "Budget 2026.webloc",
            url: "https://docs.google.com/spreadsheets/d/SHEET1/edit#gid=0")
        let stub = try StubParser.parse(fileAt: file)
        XCTAssertEqual(stub.type, .sheet)
        XCTAssertEqual(stub.docID, "SHEET1")
    }

    /// The rendered-preview pipeline keys off docID, so a webloc and a stub for
    /// the same document have to agree.
    func testWeblocAndStubAgreeOnDocID() throws {
        let weblocFile = try write(
            "Same Doc.webloc",
            url: "https://docs.google.com/document/d/SHARED_ID/edit")
        let fromWebloc = try StubParser.parse(fileAt: weblocFile)

        let stubJSON = #"{"doc_id":"SHARED_ID","resource_key":"","email":"me@example.com"}"#
        let fromStub = try StubParser.parse(
            data: Data(stubJSON.utf8), type: .doc, title: "Same Doc")

        XCTAssertEqual(fromWebloc.docID, fromStub.docID)
        XCTAssertEqual(fromWebloc.type, fromStub.type)
    }

    func testNonGoogleWeblocReportsItsLink() throws {
        let file = try write("Some Blog Post.webloc", url: "https://example.com/post")
        XCTAssertThrowsError(try StubParser.parse(fileAt: file)) { error in
            XCTAssertEqual(
                error as? StubParseError,
                .notAGoogleDocument(URL(string: "https://example.com/post")!))
        }
    }

    func testGarbageWeblocIsRejected() throws {
        let file = dir.appendingPathComponent("Broken.webloc")
        try Data("not a plist at all".utf8).write(to: file)
        XCTAssertThrowsError(try StubParser.parse(fileAt: file)) { error in
            XCTAssertEqual(error as? StubParseError, .notWebloc)
        }
    }
}
