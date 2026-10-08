import XCTest
@testable import SpyglassKit

final class TextSnifferTests: XCTestCase {

    func testDecodesUTF8() {
        XCTAssertEqual(TextSniffer.decode(Data("héllo\n".utf8)), "héllo\n")
    }

    func testTrimsMultibyteCharacterCutByTheLimit() {
        // "é" is two bytes; a read limit can land between them.
        var data = Data("abcé".utf8)
        data.removeLast()
        XCTAssertEqual(TextSniffer.decode(data), "abc")
    }

    func testDecodesUTF16WithBOM() {
        var data = Data([0xFF, 0xFE])
        data.append("hi".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(TextSniffer.decode(data), "hi")
    }

    func testRejectsBinary() {
        XCTAssertNil(TextSniffer.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02])))
    }

    func testRejectsInvalidUTF8InTheMiddle() {
        XCTAssertNil(TextSniffer.decode(Data([0x61, 0xFF, 0xFE, 0x62, 0x63])))
    }

    func testEmptyFileIsEmptyText() {
        XCTAssertEqual(TextSniffer.decode(Data()), "")
    }
}
