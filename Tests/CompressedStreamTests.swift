import XCTest
@testable import SpyglassKit

final class CompressedStreamTests: ArchiveTestCase {

    /// Bytes no compressor can shrink, so a cut lands where it's aimed.
    private func noise(_ count: Int, seed: UInt64 = 42) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    private func gzip(_ data: Data, named name: String = "member", storeName: Bool = true) throws -> Data {
        let source = try write("in/\(name)", data)
        return try run("/usr/bin/gzip", (storeName ? [] : ["-n"]) + ["-c", source.path])
    }

    private func bzip2(_ data: Data) throws -> Data {
        let source = try write("in/bz-\(UUID().uuidString)", data)
        return try run("/usr/bin/bzip2", ["-c", source.path])
    }

    private func makeTar(_ files: [String: Data]) throws -> Data {
        let root = dir.appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
        for (name, data) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return try run("/usr/bin/tar", ["--no-mac-metadata", "-cf", "-"] + files.keys.sorted(), in: root)
    }

    func testListsATarballInsideGzip() throws {
        let tar = try makeTar(["a.txt": Data("alpha".utf8), "dir/b.txt": repetitiveText(50_000)])
        let url = try write("t.tgz", try gzip(tar))
        let listing = try ArchiveReader.list(url, format: .gzip)
        XCTAssertFalse(listing.isSingleFile)
        XCTAssertEqual(listing.entries.map(\.path), ["a.txt", "dir/b.txt"])
        XCTAssertEqual(listing.entries.map(\.size), [5, 50_000])
        XCTAssertNil(listing.incomplete)
    }

    func testListsATarballInsideBzip2() throws {
        let tar = try makeTar(["a.txt": Data("alpha".utf8), "b.bin": noise(3000)])
        let url = try write("t.tar.bz2", try bzip2(tar))
        let listing = try ArchiveReader.list(url, format: .bzip2)
        XCTAssertEqual(listing.entries.map(\.path), ["a.txt", "b.bin"])
        XCTAssertNil(listing.incomplete)
    }

    func testFollowsConcatenatedGzipMembers() throws {
        let tar = try makeTar(["one.txt": repetitiveText(3000), "two.txt": repetitiveText(5000)])
        // Split mid-block so the second member starts inside a header.
        var joined = try gzip(tar.prefix(700), named: "part1")
        joined += try gzip(tar.dropFirst(700), named: "part2")
        let url = try write("joined.tar.gz", joined)
        let listing = try ArchiveReader.list(url, format: .gzip)
        XCTAssertEqual(listing.entries.map(\.path), ["one.txt", "two.txt"])
        XCTAssertNil(listing.incomplete)
    }

    func testSingleFileSizeCountsEveryMember() throws {
        var joined = try gzip(Data("hello ".utf8), storeName: false)
        joined += try gzip(Data("world".utf8), storeName: false)
        let listing = try CompressedArchive.list(try write("greeting.txt.gz", joined), format: .gzip)
        XCTAssertTrue(listing.isSingleFile)
        XCTAssertEqual(listing.entries.map(\.path), ["greeting.txt"])
        XCTAssertEqual(listing.entries.first?.size, 11)
    }

    func testSingleGzipFileTakesItsNameAndDateFromTheHeader() throws {
        let contents = Data("create table t(a);\n".utf8)
        let source = try write("in/dump.sql", contents)
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: source.path)
        let compressed = try run("/usr/bin/gzip", ["-c", source.path])
        let listing = try CompressedArchive.list(try write("renamed.gz", compressed), format: .gzip)
        XCTAssertEqual(listing.entries, [ArchiveEntry(path: "dump.sql", kind: .file, size: 19, modified: stamp)])
    }

    func testSingleGzipWithoutAStoredNameUsesTheFileName() throws {
        let url = try write("notes.txt.gz", try gzip(Data("note".utf8), storeName: false))
        let entry = try XCTUnwrap(CompressedArchive.list(url, format: .gzip).entries.first)
        XCTAssertEqual(entry.path, "notes.txt")
        XCTAssertNil(entry.modified)
    }

    func testSingleBzip2FileCountsItsSize() throws {
        let url = try write("data.csv.bz2", try bzip2(repetitiveText(123_456)))
        let listing = try CompressedArchive.list(url, format: .bzip2)
        XCTAssertTrue(listing.isSingleFile)
        XCTAssertEqual(listing.entries.map(\.path), ["data.csv"])
        XCTAssertEqual(listing.entries.first?.size, 123_456)
        XCTAssertNil(listing.incomplete)
    }

    func testANonTarInsideATarGzIsASingleFile() throws {
        let url = try write("fake.tar.gz", try gzip(repetitiveText(2000), storeName: false))
        let listing = try ArchiveReader.list(url, format: .gzip)
        XCTAssertTrue(listing.isSingleFile)
        XCTAssertEqual(listing.entries.map(\.path), ["fake.tar"])
        XCTAssertEqual(listing.entries.first?.size, 2000)
    }

    func testTruncatedTarballKeepsEarlierEntries() throws {
        let tar = try makeTar(["a.txt": Data("alpha".utf8), "b.bin": noise(100_000)])
        let compressed = try gzip(tar)
        let url = try write("cut.tgz", compressed.prefix(compressed.count * 6 / 10))
        let listing = try ArchiveReader.list(url, format: .gzip)
        XCTAssertEqual(listing.entries.map(\.path), ["a.txt", "b.bin"])
        XCTAssertEqual(listing.incomplete, .damaged("The compressed data ends early"))
    }

    func testTruncatedSingleFileReportsWhatItRead() throws {
        let compressed = try gzip(noise(200_000), storeName: false)
        let url = try write("cut.bin.gz", compressed.prefix(compressed.count / 2))
        let listing = try CompressedArchive.list(url, format: .gzip)
        XCTAssertEqual(listing.incomplete, .damaged("The compressed data ends early"))
        let size = try XCTUnwrap(listing.entries.first?.size)
        XCTAssertGreaterThan(size, 50_000)
        XCTAssertLessThan(size, 200_000)
    }

    func testStreamsCutBeforeAnyDataThrow() throws {
        let compressed = try gzip(repetitiveText(1000))
        XCTAssertThrowsError(try CompressedArchive.list(try write("head.gz", compressed.prefix(12)), format: .gzip))
        let bz = try bzip2(repetitiveText(1000))
        XCTAssertThrowsError(try CompressedArchive.list(try write("head.bz2", bz.prefix(20)), format: .bzip2))
    }

    func testCorruptDataIsNeverListedAsWhole() throws {
        // Damage near the start: nothing decodes, so there's nothing to show.
        var bz = [UInt8](try bzip2(repetitiveText(5000)))
        for index in 20..<40 { bz[index] ^= 0x5A }
        XCTAssertThrowsError(try CompressedArchive.list(try write("bad.bz2", Data(bz)), format: .bzip2))
        var gz = [UInt8](try gzip(repetitiveText(5000), storeName: false))
        for index in 12..<30 { gz[index] ^= 0x5A }
        XCTAssertThrowsError(try CompressedArchive.list(try write("bad.gz", Data(gz)), format: .gzip))

        // Damage at the end (the gzip CRC): the bytes decoded so far are
        // listed, flagged as damaged.
        var tail = [UInt8](try gzip(repetitiveText(5000), storeName: false))
        tail[tail.count - 6] ^= 0xFF
        let listing = try CompressedArchive.list(try write("badcrc.gz", Data(tail)), format: .gzip)
        XCTAssertEqual(listing.entries.first?.size, 5000)
        XCTAssertEqual(listing.incomplete, .damaged("The compressed data is corrupt"))
    }

    func testWrongMagicThrows() throws {
        let url = try write("plain.gz", repetitiveText(100))
        XCTAssertThrowsError(try CompressedArchive.list(url, format: .gzip)) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not a gzip file"))
        }
        XCTAssertThrowsError(try CompressedArchive.list(url, format: .bzip2))
    }

    func testByteLimitStopsAndGzipFallsBackToItsTrailer() throws {
        let limits = ArchiveLimits(maxDecompressedBytes: 65_536)
        let gz = try write("big.gz", try gzip(repetitiveText(1_000_000), storeName: false))
        let gzListing = try CompressedArchive.list(gz, format: .gzip, limits: limits)
        XCTAssertEqual(gzListing.incomplete, .workLimit(decompressedBytes: 65_536))
        XCTAssertEqual(gzListing.entries.first?.size, 1_000_000)

        let bz = try write("big.bz2", try bzip2(repetitiveText(1_000_000)))
        let bzListing = try CompressedArchive.list(bz, format: .bzip2, limits: limits)
        XCTAssertEqual(bzListing.incomplete, .workLimit(decompressedBytes: 65_536))
        XCTAssertEqual(bzListing.entries.first?.size, 65_536)
    }

    func testTimeLimitStopsATarball() throws {
        let tar = try makeTar(["a.bin": noise(600_000), "b.txt": Data("b".utf8)])
        let url = try write("slow.tgz", try gzip(tar))
        let listing = try ArchiveReader.list(url, format: .gzip, limits: ArchiveLimits(maxDuration: -1))
        XCTAssertEqual(listing.entries.map(\.path), ["a.bin"])
        guard case .workLimit(let bytes) = listing.incomplete else {
            return XCTFail("\(String(describing: listing.incomplete))")
        }
        XCTAssertLessThan(bytes, UInt64(tar.count))
    }

    func testSniffsTheRealFormatOverTheExtension() throws {
        let tar = try makeTar(["a.txt": Data("alpha".utf8)])
        let url = try write("mislabelled.tar", try gzip(tar))
        XCTAssertEqual(try ArchiveReader.list(url, format: .tar).entries.map(\.path), ["a.txt"])
    }

    func testListsTheFixtures() throws {
        XCTAssertEqual(try ArchiveReader.list(fixture("project.tar.gz"), format: .gzip).entries.map(\.path),
                       ["project/README.md", "project/main.swift"])
        XCTAssertEqual(try ArchiveReader.list(fixture("project.tar.bz2"), format: .bzip2).entries.map(\.path),
                       ["project/main.swift"])
        let dump = try ArchiveReader.list(fixture("dump.sql.gz"), format: .gzip)
        XCTAssertTrue(dump.isSingleFile)
        XCTAssertEqual(dump.entries.map(\.path), ["dump.sql"])
        XCTAssertEqual(dump.entries.map(\.size), [19])
    }
}
