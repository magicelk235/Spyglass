import XCTest
@testable import SpyglassKit

final class TarReaderTests: ArchiveTestCase {

    private let longName = "deeply/" + String(repeating: "nested-folder-name/", count: 8) + "file-with-a-long-name.txt"

    /// A tree with a file, a folder, a symlink, a hard link and a path
    /// longer than the 100 bytes a plain ustar name field holds.
    private func makeTree() throws -> URL {
        let root = dir.appendingPathComponent("tree", isDirectory: true)
        try write("tree/a.txt", "alpha")
        try write("tree/\(longName)", "long")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                                   withDestinationPath: "a.txt")
        try FileManager.default.linkItem(at: root.appendingPathComponent("a.txt"),
                                         to: root.appendingPathComponent("hard.txt"))
        return root
    }

    private func tar(format: String) throws -> URL {
        let root = try makeTree()
        let out = dir.appendingPathComponent("\(format).tar")
        try run("/usr/bin/tar", ["--no-mac-metadata", "--format", format, "-cf", out.path,
                                 "a.txt", "hard.txt", "link", "empty", longName], in: root)
        return out
    }

    func testListsTypesSizesAndLinks() throws {
        let listing = try TarReader.list(try tar(format: "pax"))
        let byPath = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.path, $0) })
        XCTAssertEqual(byPath["a.txt"]?.kind, .file)
        XCTAssertEqual(byPath["a.txt"]?.size, 5)
        XCTAssertEqual(byPath["empty"]?.kind, .directory)
        XCTAssertEqual(byPath["link"]?.kind, .symlink)
        XCTAssertEqual(byPath["link"]?.linkTarget, "a.txt")
        XCTAssertEqual(byPath["hard.txt"]?.kind, .hardlink)
        XCTAssertEqual(byPath["hard.txt"]?.linkTarget, "a.txt")
        XCTAssertNil(listing.incomplete)
    }

    func testReadsPaxPaths() throws {
        let paths = try TarReader.list(try tar(format: "pax")).entries.map(\.path)
        XCTAssertTrue(paths.contains(longName), "\(paths)")
    }

    func testReadsGNULongNames() throws {
        let url = try tar(format: "gnutar")
        let bytes = try Data(contentsOf: url)
        XCTAssertNotNil(bytes.range(of: Data("././@LongLink".utf8)), "expected a GNU long-name header")
        let paths = try TarReader.list(url).entries.map(\.path)
        XCTAssertTrue(paths.contains(longName), "\(paths)")
        XCTAssertTrue(paths.contains("a.txt"))
    }

    func testReadsUstarPrefixField() throws {
        // ustar splits paths up to 255 bytes between the prefix and name fields.
        let paths = try TarReader.list(try tar(format: "ustar")).entries.map(\.path)
        XCTAssertTrue(paths.contains(longName), "\(paths)")
    }

    func testModifiedDateComesFromTheHeader() throws {
        var bytes = TarBuilder.header(name: "dated.txt", size: 0, mtime: 1_234_567_890)
        bytes += TarBuilder.header(name: "undated.txt", size: 0, mtime: 0)
        bytes += TarBuilder.end
        let entries = try TarReader.list(try write("dated.tar", Data(bytes))).entries
        XCTAssertEqual(entries.map(\.modified), [Date(timeIntervalSince1970: 1_234_567_890), nil])
    }

    func testReadsBase256Sizes() throws {
        // GNU writes sizes of 8 GiB and up in base-256: high bit set, then
        // big-endian bytes. 600 = 0x0258.
        var field = [UInt8](repeating: 0, count: 12)
        field[0] = 0x80
        field[10] = 0x02
        field[11] = 0x58
        let payload = [UInt8](repeating: 0x61, count: 600)
        var bytes = TarBuilder.header(name: "big.bin", size: 0, sizeField: field)
        bytes += TarBuilder.padded(payload)
        bytes += TarBuilder.header(name: "after.txt", size: 3)
        bytes += TarBuilder.padded(Array("abc".utf8))
        bytes += TarBuilder.end
        let entries = try TarReader.list(try write("b256.tar", Data(bytes))).entries
        XCTAssertEqual(entries.map(\.path), ["big.bin", "after.txt"])
        XCTAssertEqual(entries.map(\.size), [600, 3])
    }

    func testStopsAtTheEndOfArchiveBlock() throws {
        var bytes = TarBuilder.header(name: "only.txt", size: 2) + TarBuilder.padded(Array("hi".utf8))
        bytes += TarBuilder.end
        bytes += Array(repeating: 0x5A, count: 2048)      // trailing junk
        let listing = try TarReader.list(try write("junk.tar", Data(bytes)))
        XCTAssertEqual(listing.entries.map(\.path), ["only.txt"])
        XCTAssertNil(listing.incomplete)
    }

    func testCorruptChecksumKeepsEarlierEntries() throws {
        var second = TarBuilder.header(name: "second.txt", size: 0)
        second[0] = UInt8(ascii: "S")                       // changes the sum
        var bytes = TarBuilder.header(name: "first.txt", size: 1) + TarBuilder.padded([0x31])
        bytes += second + TarBuilder.end
        let listing = try TarReader.list(try write("bad.tar", Data(bytes)))
        XCTAssertEqual(listing.entries.map(\.path), ["first.txt"])
        XCTAssertEqual(listing.incomplete, .damaged("A tar header fails its checksum"))
    }

    func testCorruptFirstHeaderThrows() throws {
        var header = TarBuilder.header(name: "first.txt", size: 0)
        header[148] = UInt8(ascii: "7")
        let url = try write("bad-first.tar", Data(header + TarBuilder.end))
        XCTAssertThrowsError(try TarReader.list(url)) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("A tar header fails its checksum"))
        }
    }

    func testTruncatedMemberKeepsEarlierEntries() throws {
        var bytes = TarBuilder.header(name: "whole.txt", size: 4) + TarBuilder.padded(Array("full".utf8))
        bytes += TarBuilder.header(name: "cut.bin", size: 5000) + Array(repeating: 0x42, count: 1000)
        let listing = try TarReader.list(try write("cut.tar", Data(bytes)))
        XCTAssertEqual(listing.entries.map(\.path), ["whole.txt", "cut.bin"])
        XCTAssertEqual(listing.incomplete, .damaged("The tar archive is cut short"))
    }

    func testFilesThatArentTarThrow() throws {
        XCTAssertThrowsError(try TarReader.list(try write("empty.tar", Data())))
        XCTAssertThrowsError(try TarReader.list(try write("half.tar", Data(TarBuilder.header(name: "x", size: 0).prefix(300)))))
        XCTAssertThrowsError(try TarReader.list(try write("text.tar", repetitiveText(4096))))
    }

    func testStopsAtTheEntryLimit() throws {
        var bytes: [UInt8] = []
        for index in 1...5 { bytes += TarBuilder.header(name: "f\(index)", size: 0) }
        bytes += TarBuilder.end
        let url = try write("five.tar", Data(bytes))
        let listing = try TarReader.list(url, limits: ArchiveLimits(maxEntries: 3))
        XCTAssertEqual(listing.entries.map(\.path), ["f1", "f2", "f3"])
        XCTAssertEqual(listing.incomplete, .entryLimit(total: nil))
        XCTAssertNil(try TarReader.list(url, limits: ArchiveLimits(maxEntries: 5)).incomplete)
    }

    func testOutOfTimeReportsHowFarItGot() throws {
        let bytes = TarBuilder.header(name: "f", size: 0) + TarBuilder.end
        let listing = try TarReader.list(try write("slow.tar", Data(bytes)), limits: ArchiveLimits(maxDuration: -1))
        XCTAssertEqual(listing.incomplete, .workLimit(decompressedBytes: 0))
    }

    func testParsesPaxRecordsAndStopsAtMalformedOnes() {
        var attributes: [String: String] = [:]
        TarParser.parsePax(Array("18 path=a/b/c.txt\n11 size=42\n6 bad\n13 mtime=1.5\n".utf8), into: &attributes)
        XCTAssertEqual(attributes, ["path": "a/b/c.txt", "size": "42"])
    }

    func testListsTheProjectFixture() throws {
        let listing = try ArchiveReader.list(fixture("project.tar"), format: .tar)
        XCTAssertEqual(listing.entries.map(\.path), ["project/main.swift"])
        XCTAssertEqual(listing.entries.first?.size, 170)
    }
}
