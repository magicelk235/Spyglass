import XCTest
@testable import SpyglassKit

final class GoogleURLParserTests: XCTestCase {

    private func stub(_ string: String, title: String = "Notes") -> Stub? {
        GoogleURLParser.stub(from: URL(string: string)!, title: title)
    }

    func testAllSixTypesRoundTripFromBuiltURLs() {
        for type in WorkspaceType.allCases {
            let built = GoogleURLBuilder.openURL(
                for: Stub(type: type, title: "Notes", docID: "DOC\(type.rawValue)"))
            let parsed = GoogleURLParser.stub(from: built!, title: "Notes")
            XCTAssertEqual(parsed?.type, type, "round trip failed for \(type)")
            XCTAssertEqual(parsed?.docID, "DOC\(type.rawValue)")
        }
    }

    func testDocumentURL() {
        let parsed = stub("https://docs.google.com/document/d/1AbC_dEf/edit")
        XCTAssertEqual(parsed?.type, .doc)
        XCTAssertEqual(parsed?.docID, "1AbC_dEf")
        XCTAssertEqual(parsed?.title, "Notes")
    }

    func testSpreadsheetURLWithFragment() {
        let parsed = stub("https://docs.google.com/spreadsheets/d/SHEET1/edit#gid=0")
        XCTAssertEqual(parsed?.type, .sheet)
        XCTAssertEqual(parsed?.docID, "SHEET1")
    }

    func testPresentationAndDrawing() {
        XCTAssertEqual(stub("https://docs.google.com/presentation/d/P1/edit")?.type, .slides)
        XCTAssertEqual(stub("https://docs.google.com/drawings/d/D1/edit")?.type, .drawing)
    }

    func testResourceKeyIsCaptured() {
        let parsed = stub("https://docs.google.com/document/d/D1/edit?resourcekey=0-xYz")
        XCTAssertEqual(parsed?.resourceKey, "0-xYz")
    }

    func testMissingResourceKeyStaysNil() {
        XCTAssertNil(stub("https://docs.google.com/document/d/D1/edit")?.resourceKey)
    }

    /// A Drive file link names no product, so there is no type to render.
    func testDriveFileLinkIsRejected() {
        XCTAssertNil(stub("https://drive.google.com/file/d/XYZ/view"))
    }

    func testNonGoogleHostIsRejected() {
        XCTAssertNil(stub("https://example.com/document/d/D1/edit"))
    }

    func testURLWithoutDocIDIsRejected() {
        XCTAssertNil(stub("https://docs.google.com/document/d"))
    }

    func testDriveFolderLinkIsRejected() {
        XCTAssertNil(stub("https://drive.google.com/drive/folders/F1"))
    }
}
