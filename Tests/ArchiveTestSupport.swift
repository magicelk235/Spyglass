import XCTest
import zlib

/// A scratch directory, removed when the test case ends.
class ArchiveTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(type(of: self))-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A file inside the scratch directory, creating folders on the way.
    @nonobjc @discardableResult
    func write(_ relativePath: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    @nonobjc @discardableResult
    func write(_ relativePath: String, _ text: String) throws -> URL {
        try write(relativePath, Data(text.utf8))
    }

    /// Runs a command-line tool and fails the test when it exits non-zero.
    @discardableResult
    func run(_ tool: String, _ arguments: [String], in directory: URL? = nil,
             file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? dir
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) \(arguments.joined(separator: " "))", file: file, line: line)
        return data
    }

    func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("samples/formats/\(name)")
    }

    /// Bytes that compress well, so deflate really is used.
    func repetitiveText(_ count: Int) -> Data {
        let line = Data("The quick brown fox jumps over the lazy dog.\n".utf8)
        var data = Data()
        while data.count < count { data.append(line) }
        return data.prefix(count)
    }
}

func crc32(of bytes: [UInt8]) -> UInt32 {
    UInt32(bytes.withUnsafeBufferPointer { zlib.crc32(0, $0.baseAddress, uInt($0.count)) })
}

extension Array where Element == UInt8 {
    mutating func le16(_ value: UInt16) { append(UInt8(value & 0xFF)); append(UInt8(value >> 8)) }
    mutating func le32(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8(value >> shift & 0xFF)) } }
    mutating func le64(_ value: UInt64) { for shift in stride(from: 0, to: 64, by: 8) { append(UInt8(value >> shift & 0xFF)) } }
    mutating func be16(_ value: UInt16) { append(UInt8(value >> 8)); append(UInt8(value & 0xFF)) }
    mutating func be32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { append(UInt8(value >> shift & 0xFF)) } }
    mutating func be64(_ value: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { append(UInt8(value >> shift & 0xFF)) } }
}

/// Writes ZIP archives byte by byte (stored members only), for layouts the
/// zip tool won't produce on demand: ZIP64 fields, CP437 names, prefixes.
struct ZipBuilder {
    struct Member {
        var name: [UInt8]
        var data: [UInt8]
        var flags: UInt16 = 0
        /// Saturate the sizes and offset and put the real values in a
        /// ZIP64 extra field.
        var zip64 = false
        var extra: [UInt8] = []
        /// 2026-10-08 10:36:12 local time.
        var dosDate: UInt16 = (46 << 9) | (10 << 5) | 8
        var dosTime: UInt16 = (10 << 11) | (36 << 5) | 6
    }

    var members: [Member] = []
    /// Bytes before the archive, like a self-extractor stub.
    var prefix: [UInt8] = []
    /// Write ZIP64 end records and saturate the classic end record.
    var zip64End = false

    func build() -> Data {
        var out = prefix
        var central: [UInt8] = []
        for member in members {
            let offset = UInt64(out.count - prefix.count)
            let crc = crc32(of: member.data)
            let size = UInt64(member.data.count)
            var localExtra = member.extra
            if member.zip64 {
                localExtra.le16(0x0001); localExtra.le16(16)
                localExtra.le64(size); localExtra.le64(size)
            }
            out.le32(0x0403_4B50); out.le16(45); out.le16(member.flags); out.le16(0)
            out.le16(member.dosTime); out.le16(member.dosDate); out.le32(crc)
            out.le32(member.zip64 ? 0xFFFF_FFFF : UInt32(size)); out.le32(member.zip64 ? 0xFFFF_FFFF : UInt32(size))
            out.le16(UInt16(member.name.count)); out.le16(UInt16(localExtra.count))
            out += member.name + localExtra + member.data

            var centralExtra = member.extra
            if member.zip64 {
                centralExtra.le16(0x0001); centralExtra.le16(24)
                centralExtra.le64(size); centralExtra.le64(size); centralExtra.le64(offset)
            }
            central.le32(0x0201_4B50); central.le16(0x031E); central.le16(45); central.le16(member.flags)
            central.le16(0); central.le16(member.dosTime); central.le16(member.dosDate); central.le32(crc)
            central.le32(member.zip64 ? 0xFFFF_FFFF : UInt32(size)); central.le32(member.zip64 ? 0xFFFF_FFFF : UInt32(size))
            central.le16(UInt16(member.name.count)); central.le16(UInt16(centralExtra.count)); central.le16(0)
            central.le16(0); central.le16(0); central.le32(0o100644 << 16)
            central.le32(member.zip64 ? 0xFFFF_FFFF : UInt32(offset))
            central += member.name + centralExtra
        }
        let centralOffset = UInt64(out.count - prefix.count)
        out += central
        let count = UInt64(members.count)
        if zip64End {
            let recordOffset = UInt64(out.count - prefix.count)
            out.le32(0x0606_4B50); out.le64(44); out.le16(45); out.le16(45); out.le32(0); out.le32(0)
            out.le64(count); out.le64(count); out.le64(UInt64(central.count)); out.le64(centralOffset)
            out.le32(0x0706_4B50); out.le32(0); out.le64(recordOffset); out.le32(1)
        }
        out.le32(0x0605_4B50); out.le16(0); out.le16(0)
        out.le16(zip64End ? 0xFFFF : UInt16(count)); out.le16(zip64End ? 0xFFFF : UInt16(count))
        out.le32(zip64End ? 0xFFFF_FFFF : UInt32(central.count))
        out.le32(zip64End ? 0xFFFF_FFFF : UInt32(centralOffset))
        out.le16(0)
        return Data(out)
    }
}

/// Writes raw tar headers, for numeric encodings the tar tool only uses
/// for enormous files.
enum TarBuilder {
    /// A 512-byte ustar header with a valid checksum. `sizeField` replaces
    /// the octal size, e.g. with a base-256 encoding.
    static func header(name: String, size: Int, type: UInt8 = UInt8(ascii: "0"),
                       sizeField: [UInt8]? = nil, mtime: Int = 1_700_000_000, linkName: String = "") -> [UInt8] {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ bytes: [UInt8], at offset: Int) {
            for (index, byte) in bytes.enumerated() { block[offset + index] = byte }
        }
        func octal(_ value: Int, width: Int) -> [UInt8] {
            Array(String(format: "%0\(width - 1)o", value).utf8) + [0]
        }
        put(Array(name.utf8), at: 0)
        put(octal(0o644, width: 8), at: 100)
        put(octal(0, width: 8), at: 108)
        put(octal(0, width: 8), at: 116)
        put(sizeField ?? octal(size, width: 12), at: 124)
        put(octal(mtime, width: 12), at: 136)
        block[156] = type
        put(Array(linkName.utf8), at: 157)
        put(Array("ustar\u{0}00".utf8), at: 257)
        put([UInt8](repeating: 0x20, count: 8), at: 148)
        let sum = block.reduce(0) { $0 + Int($1) }
        put(Array(String(format: "%06o", sum).utf8) + [0, 0x20], at: 148)
        return block
    }

    /// Data padded to the 512-byte block size.
    static func padded(_ data: [UInt8]) -> [UInt8] {
        data + [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
    }

    static let end = [UInt8](repeating: 0, count: 1024)
}
