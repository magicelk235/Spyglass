import XCTest
@testable import SpyglassKit

final class BencodeTests: XCTestCase {

    private func decode(_ text: String, limits: Bencode.Limits = .standard) throws -> BencodeValue {
        try Bencode.decode(Data(text.utf8), limits: limits)
    }

    private func assertThrows(_ text: String, _ expected: BencodeError, limits: Bencode.Limits = .standard,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(text, limits: limits), text, file: file, line: line) { error in
            XCTAssertEqual(error as? BencodeError, expected, text, file: file, line: line)
        }
    }

    // MARK: - Integers

    func testIntegers() throws {
        XCTAssertEqual(try decode("i42e"), .integer(42))
        XCTAssertEqual(try decode("i-7e"), .integer(-7))
        XCTAssertEqual(try decode("i0e"), .integer(0))
        XCTAssertEqual(try decode("i9223372036854775807e"), .integer(.max))
        XCTAssertEqual(try decode("i-9223372036854775808e"), .integer(.min))
    }

    func testMalformedIntegersThrow() {
        assertThrows("i-0e", .invalidInteger(offset: 0))
        assertThrows("i03e", .invalidInteger(offset: 0))
        assertThrows("ie", .invalidInteger(offset: 0))
        assertThrows("i-e", .invalidInteger(offset: 0))
        assertThrows("i1.5e", .invalidInteger(offset: 0))
        assertThrows("i+1e", .invalidInteger(offset: 0))
        assertThrows("i9223372036854775808e", .invalidInteger(offset: 0))
        assertThrows("i-9223372036854775809e", .invalidInteger(offset: 0))
        assertThrows("i12", .unexpectedEnd)
    }

    // MARK: - Byte strings

    func testByteStrings() throws {
        XCTAssertEqual(try decode("4:spam"), .bytes(Data("spam".utf8)))
        XCTAssertEqual(try decode("0:"), .bytes(Data()))
        // Byte strings are raw bytes, not text: a colon or digits inside are data.
        XCTAssertEqual(try decode("5:1:a:e"), .bytes(Data("1:a:e".utf8)))
        let binary = try Bencode.decode(Data([0x33, 0x3A, 0x00, 0xFF, 0x80]))
        XCTAssertEqual(binary, .bytes(Data([0x00, 0xFF, 0x80])))
    }

    func testBadLengthsThrow() {
        assertThrows("5:spam", .invalidLength(offset: 0))
        assertThrows("04:spam", .invalidLength(offset: 0))
        assertThrows("4spam", .invalidLength(offset: 0))
        assertThrows("99999999999999999999:x", .invalidLength(offset: 0))
        assertThrows("4", .invalidLength(offset: 0))
    }

    // MARK: - Lists and dictionaries

    func testNestedListsAndDictionaries() throws {
        let value = try decode("d4:listli1e3:twoe3:mapd2:kv0:ee")
        XCTAssertEqual(value["list"], .list([.integer(1), .bytes(Data("two".utf8))]))
        XCTAssertEqual(value["map"]?["kv"], .bytes(Data()))
        XCTAssertNil(value["missing"])
        XCTAssertEqual(try decode("le"), .list([]))
        XCTAssertEqual(try decode("de"), .dictionary([]))
    }

    func testEntryRangesCoverTheValueBytesExactly() throws {
        let text = "d4:infod1:ai1ee3:keyi2ee"
        guard case .dictionary(let entries) = try decode(text) else { return XCTFail("not a dictionary") }
        let bytes = Array(text.utf8)
        XCTAssertEqual(entries.map { String(decoding: $0.key, as: UTF8.self) }, ["info", "key"])
        XCTAssertEqual(String(decoding: bytes[entries[0].range], as: UTF8.self), "d1:ai1ee")
        XCTAssertEqual(String(decoding: bytes[entries[1].range], as: UTF8.self), "i2e")
    }

    func testRangesAreRelativeToTheSliceStart() throws {
        let whole = Data("xxd1:ai5ee".utf8)
        let slice = whole[2...]
        guard case .dictionary(let entries) = try Bencode.decode(slice) else { return XCTFail("not a dictionary") }
        XCTAssertEqual(entries.first?.range, 4..<7)
    }

    func testUnsortedKeysAreTolerated() throws {
        let value = try decode("d1:bi1e1:ai2ee")
        XCTAssertEqual(value["a"], .integer(2))
        XCTAssertEqual(value["b"], .integer(1))
    }

    func testDuplicateKeysThrow() {
        assertThrows("d1:ai1e1:ai2ee", .duplicateKey(offset: 7))
        // Out of order first, so the duplicate is caught off the sorted path.
        assertThrows("d1:bi1e1:ai2e1:bi3ee", .duplicateKey(offset: 13))
    }

    func testNonStringKeyThrows() {
        assertThrows("di1ei2ee", .invalidKey(offset: 1))
    }

    func testUnterminatedContainersThrow() {
        assertThrows("l", .unexpectedEnd)
        assertThrows("li1e", .unexpectedEnd)
        assertThrows("d1:a", .unexpectedEnd)
        assertThrows("", .unexpectedEnd)
    }

    func testUnknownTypeByteThrows() {
        assertThrows("x", .unexpectedByte(offset: 0))
        assertThrows("lxe", .unexpectedByte(offset: 1))
    }

    func testTrailingDataThrows() {
        assertThrows("i1ei2e", .trailingData(offset: 3))
        assertThrows("de\n", .trailingData(offset: 2))
    }

    // MARK: - Caps

    func testDepthCap() throws {
        let limits = Bencode.Limits(maxDepth: 8)
        XCTAssertNoThrow(try decode(String(repeating: "l", count: 8) + String(repeating: "e", count: 8), limits: limits))
        assertThrows(String(repeating: "l", count: 9) + String(repeating: "e", count: 9), .tooDeep, limits: limits)
    }

    func testDeepInputDoesNotOverflowTheStack() {
        // Far past the default cap; must throw rather than recurse 100,000 levels.
        assertThrows(String(repeating: "l", count: 100_000), .tooDeep)
    }

    func testValueCountCap() {
        let limits = Bencode.Limits(maxValues: 10)
        XCTAssertNoThrow(try decode("l" + String(repeating: "i1e", count: 9) + "e", limits: limits))
        assertThrows("l" + String(repeating: "i1e", count: 10) + "e", .tooManyValues, limits: limits)
    }

    func testSizeCap() {
        assertThrows("4:spam", .tooLarge, limits: Bencode.Limits(maxSize: 5))
        XCTAssertNoThrow(try decode("4:spam", limits: Bencode.Limits(maxSize: 6)))
    }

    // MARK: - Accessors

    func testTextAndIntegerAccessors() throws {
        let value = try decode("d4:name5:hello4:sizei12ee")
        XCTAssertEqual(value["name"]?.text, "hello")
        XCTAssertEqual(value["size"]?.integer, 12)
        XCTAssertNil(value["size"]?.text)
        XCTAssertNil(value["name"]?.integer)
    }
}
