import XCTest
@testable import SpyglassKit

final class WeblocParserTests: XCTestCase {

    /// Builds a real binary plist, which is what Finder and the Drive clients
    /// actually write, rather than hand-rolled XML.
    private func webloc(url: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: ["URL": url], format: .binary, options: 0)
    }

    func testReadsURLFromBinaryPlist() throws {
        let data = try webloc(url: "https://docs.google.com/document/d/abc123/edit")
        XCTAssertEqual(
            WeblocParser.url(from: data)?.absoluteString,
            "https://docs.google.com/document/d/abc123/edit")
    }

    func testReadsURLFromXMLPlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>URL</key><string>https://example.com/page</string>
        </dict></plist>
        """
        XCTAssertEqual(
            WeblocParser.url(from: Data(xml.utf8))?.absoluteString,
            "https://example.com/page")
    }

    func testEmptyURLIsRejected() throws {
        XCTAssertNil(WeblocParser.url(from: try webloc(url: "")))
    }

    func testNonPlistDataIsRejected() {
        XCTAssertNil(WeblocParser.url(from: Data("not a plist".utf8)))
    }

    func testPlistWithoutURLKeyIsRejected() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Title": "no url here"], format: .binary, options: 0)
        XCTAssertNil(WeblocParser.url(from: data))
    }
}
