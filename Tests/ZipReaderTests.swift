import XCTest
@testable import SpyglassKit

final class ZipReaderTests: ArchiveTestCase {

    /// A zip made by /usr/bin/zip from a small folder tree.
    private func makeZip(extraArguments: [String] = []) throws -> (zip: URL, text: Data, binary: Data) {
        let text = repetitiveText(20_000)
        let binary = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7919 >> 3) })
        try write("src/notes.txt", text)
        try write("src/sub/blob.bin", binary)
        try write("src/ünïcode.txt", "hi")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src/empty"),
                                                withIntermediateDirectories: true)
        try run("/usr/bin/zip", ["-q", "-r"] + extraArguments + ["out.zip", "."], in: dir.appendingPathComponent("src"))
        return (dir.appendingPathComponent("src/out.zip"), text, binary)
    }

    func testListsNamesSizesAndFolders() throws {
        let (zip, text, binary) = try makeZip()
        let reader = try ZipReader(url: zip)
        let byPath = Dictionary(uniqueKeysWithValues: reader.entries.map { ($0.path, $0) })
        XCTAssertEqual(Set(byPath.keys), ["notes.txt", "sub", "sub/blob.bin", "ünïcode.txt", "empty"])
        XCTAssertEqual(byPath["notes.txt"]?.uncompressedSize, UInt64(text.count))
        XCTAssertLessThan(byPath["notes.txt"]!.compressedSize, UInt64(text.count / 10))
        XCTAssertEqual(byPath["sub/blob.bin"]?.uncompressedSize, UInt64(binary.count))
        XCTAssertEqual(byPath["empty"]?.isDirectory, true)
        XCTAssertEqual(byPath["notes.txt"]?.isDirectory, false)
        XCTAssertEqual(reader.declaredEntryCount, 5)
        XCTAssertFalse(reader.hitEntryLimit)
    }

    func testModifiedDateMatchesTheFile() throws {
        let (zip, _, _) = try makeZip()
        let onDisk = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("src/notes.txt").path)[.modificationDate] as! Date
        let entry = try XCTUnwrap(ZipReader(url: zip).entries.first { $0.path == "notes.txt" })
        // DOS time has 2-second resolution; the UT extra field has 1 second.
        XCTAssertEqual(entry.modified!.timeIntervalSince1970, onDisk.timeIntervalSince1970, accuracy: 2)
    }

    func testExtractsDeflatedAndStoredMembers() throws {
        let (zip, text, binary) = try makeZip()
        let reader = try ZipReader(url: zip)
        let notes = try XCTUnwrap(reader.entries.first { $0.path == "notes.txt" })
        XCTAssertEqual(notes.method, 8)
        XCTAssertEqual(try reader.contents(of: notes, maxSize: 1 << 20), text)
        let blob = try XCTUnwrap(reader.entries.first { $0.path == "sub/blob.bin" })
        XCTAssertEqual(try reader.contents(of: blob, maxSize: 1 << 20), binary)
        XCTAssertEqual(try reader.prefix(of: notes, length: 100), text.prefix(100))
    }

    func testRefusesMembersOverTheSizeCap() throws {
        let (zip, _, _) = try makeZip()
        let reader = try ZipReader(url: zip)
        let notes = try XCTUnwrap(reader.entries.first { $0.path == "notes.txt" })
        XCTAssertThrowsError(try reader.contents(of: notes, maxSize: 1000)) { error in
            guard case ArchiveError.tooLarge = error else { return XCTFail("\(error)") }
        }
    }

    func testEncryptedMembersAreFlaggedAndNotRead() throws {
        let (zip, _, _) = try makeZip(extraArguments: ["-P", "secret"])
        let reader = try ZipReader(url: zip)
        let notes = try XCTUnwrap(reader.entries.first { $0.path == "notes.txt" })
        XCTAssertTrue(notes.isEncrypted)
        XCTAssertThrowsError(try reader.contents(of: notes, maxSize: 1 << 20))
    }

    func testDamagedMemberFailsItsChecksum() throws {
        var builder = ZipBuilder()
        builder.members = [.init(name: Array("a.txt".utf8), data: Array("hello world".utf8))]
        var bytes = [UInt8](builder.build())
        bytes[30 + 5 + 2] ^= 0xFF          // a byte of the stored data
        let url = try write("bad.zip", Data(bytes))
        let reader = try ZipReader(url: url)
        XCTAssertThrowsError(try reader.contents(of: reader.entries[0], maxSize: 100)) { error in
            guard case ArchiveError.corrupt = error else { return XCTFail("\(error)") }
        }
    }

    func testReadsZip64FieldsAndEndRecords() throws {
        var builder = ZipBuilder()
        builder.zip64End = true
        builder.members = [
            .init(name: Array("small.txt".utf8), data: Array("tiny".utf8)),
            .init(name: Array("big.bin".utf8), data: Array("zip64 sized".utf8), zip64: true),
        ]
        let url = try write("z64.zip", builder.build())
        let reader = try ZipReader(url: url)
        XCTAssertEqual(reader.entries.map(\.path), ["small.txt", "big.bin"])
        XCTAssertEqual(reader.entries[1].uncompressedSize, 11)
        XCTAssertEqual(reader.entries[1].compressedSize, 11)
        XCTAssertEqual(try reader.contents(of: reader.entries[1], maxSize: 100), Data("zip64 sized".utf8))
    }

    func testReadsTheZip64EndRecordsZipWritesForStreamedInput() throws {
        // zip writes ZIP64 end records whenever it compresses from stdin.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'streamed' | /usr/bin/zip -q stream.zip -"]
        process.currentDirectoryURL = dir
        try process.run()
        process.waitUntilExit()
        let bytes = try Data(contentsOf: dir.appendingPathComponent("stream.zip"))
        XCTAssertNotNil(bytes.range(of: Data([0x50, 0x4B, 0x06, 0x06])), "expected a ZIP64 end record")
        let reader = try ZipReader(url: dir.appendingPathComponent("stream.zip"))
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(try reader.contents(of: reader.entries[0], maxSize: 100), Data("streamed".utf8))
    }

    func testFindsTheArchiveBehindAPrefix() throws {
        var builder = ZipBuilder()
        builder.prefix = Array(repeating: 0x90, count: 300)
        builder.members = [.init(name: Array("inside.txt".utf8), data: Array("found".utf8))]
        let url = try write("sfx.zip", builder.build())
        let reader = try ZipReader(url: url)
        XCTAssertEqual(try reader.contents(of: reader.entries[0], maxSize: 100), Data("found".utf8))
    }

    func testNamesWithoutTheUTF8FlagAreCP437() throws {
        var builder = ZipBuilder()
        // 0x8E is "Ä" and 0x81 "ü" in CP437; together they aren't valid UTF-8.
        builder.members = [
            .init(name: [0x8E, 0x81, 0x2E, 0x74, 0x78, 0x74], data: []),
            .init(name: Array("naïve.txt".utf8), data: [], flags: 0x0800),
        ]
        let url = try write("names.zip", builder.build())
        XCTAssertEqual(try ZipReader(url: url).entries.map(\.path), ["Äü.txt", "naïve.txt"])
    }

    func testUnicodePathFieldWinsWhileItMatchesTheStoredName() throws {
        func unicodePath(_ name: String, for raw: [UInt8]) -> [UInt8] {
            var field: [UInt8] = []
            let utf8 = Array(name.utf8)
            field.le16(0x7075); field.le16(UInt16(5 + utf8.count))
            field.append(1); field.le32(crc32(of: raw))
            return field + utf8
        }
        let raw = Array("file.txt".utf8)
        var stale = unicodePath("старый.txt", for: raw)
        stale[8] ^= 0xFF                       // CRC no longer matches the name
        var builder = ZipBuilder()
        builder.members = [
            .init(name: raw, data: [], extra: unicodePath("файл.txt", for: raw)),
            .init(name: Array("other.txt".utf8), data: [], extra: stale),
        ]
        let url = try write("unicode.zip", builder.build())
        XCTAssertEqual(try ZipReader(url: url).entries.map(\.path), ["файл.txt", "other.txt"])
    }

    func testDOSDatesAreLocalTime() throws {
        var builder = ZipBuilder()
        builder.members = [.init(name: Array("a".utf8), data: [])]
        let url = try write("date.zip", builder.build())
        let date = try XCTUnwrap(ZipReader(url: url).entries[0].modified)
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second],
                       [2026, 10, 8, 10, 36, 12])
    }

    func testStopsAtTheEntryLimitAndSaysSo() throws {
        var builder = ZipBuilder()
        builder.members = (1...5).map { .init(name: Array("f\($0)".utf8), data: [0x41]) }
        let url = try write("five.zip", builder.build())
        let reader = try ZipReader(url: url, maxEntries: 3)
        XCTAssertEqual(reader.entries.map(\.path), ["f1", "f2", "f3"])
        XCTAssertTrue(reader.hitEntryLimit)
        XCTAssertEqual(reader.listing.incomplete, .entryLimit(total: 5))
        XCTAssertNil(try ZipReader(url: url, maxEntries: 5).listing.incomplete)
    }

    func testKeepsEntriesBeforeADamagedRecord() throws {
        var builder = ZipBuilder()
        builder.members = (1...3).map { .init(name: Array("f\($0)".utf8), data: [0x41]) }
        var bytes = [UInt8](builder.build())
        let second = try XCTUnwrap(findAll([0x50, 0x4B, 0x01, 0x02], in: bytes).dropFirst().first)
        bytes[second] = 0x00
        let url = try write("damaged.zip", Data(bytes))
        let listing = try ZipReader(url: url).listing
        XCTAssertEqual(listing.entries.map(\.path), ["f1"])
        guard case .damaged = listing.incomplete else { return XCTFail("\(String(describing: listing.incomplete))") }
    }

    func testTruncatedArchiveThrows() throws {
        let (zip, _, _) = try makeZip()
        let bytes = try Data(contentsOf: zip)
        let cut = try write("cut.zip", bytes.prefix(bytes.count / 2))
        XCTAssertThrowsError(try ZipReader(url: cut)) { error in
            guard case ArchiveError.truncated = error else { return XCTFail("\(error)") }
        }
    }

    func testGarbageAndEmptyFilesThrow() throws {
        let garbage = try write("garbage.zip", Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 31) }))
        XCTAssertThrowsError(try ZipReader(url: garbage))
        let empty = try write("empty.zip", Data())
        XCTAssertThrowsError(try ZipReader(url: empty))
        // An end record whose directory points past the end of the file.
        var bytes: [UInt8] = []
        bytes.le32(0x0605_4B50); bytes.le16(0); bytes.le16(0); bytes.le16(1); bytes.le16(1)
        bytes.le32(4000); bytes.le32(0); bytes.le16(0)
        let lying = try write("lying.zip", Data(bytes))
        XCTAssertThrowsError(try ZipReader(url: lying))
    }

    func testListsTheProjectFixture() throws {
        let listing = try ArchiveReader.list(fixture("project.zip"), format: .zip)
        XCTAssertEqual(listing.entries.map(\.path), ["project/README.md", "project/src/main.swift", "project/assets"])
        XCTAssertEqual(listing.entries.map(\.kind), [.file, .file, .directory])
    }

    private func findAll(_ needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard haystack.count >= needle.count else { return [] }
        return (0...(haystack.count - needle.count)).filter { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }
}
