import XCTest
@testable import SpyglassKit

final class XZArchiveTests: ArchiveTestCase {

    /// Compresses with Python's lzma module (xz container). `check` is one
    /// of lzma's CHECK_* names.
    private func xz(_ data: Data, check: String = "CHECK_CRC64") throws -> Data {
        let input = try write("in/\(UUID().uuidString)", data)
        let output = dir.appendingPathComponent("out-\(UUID().uuidString).xz")
        let script = "import lzma, sys; open(sys.argv[2], 'wb').write(lzma.compress(open(sys.argv[1], 'rb').read(), check=lzma.\(check)))"
        try run("/usr/bin/python3", ["-c", script, input.path, output.path])
        return try Data(contentsOf: output)
    }

    /// Bytes no compressor can shrink, so a cut lands where it's aimed.
    private func noise(_ count: Int, seed: UInt64 = 7) -> Data {
        var state = seed
        return Data((0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 33)
        })
    }

    /// A .tar.xz made by the system tar.
    private func tarXZ(_ files: [String: Data]) throws -> Data {
        let root = dir.appendingPathComponent("tree-\(UUID().uuidString)", isDirectory: true)
        for (name, data) in files {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return try run("/usr/bin/tar", ["--no-mac-metadata", "-cJf", "-"] + files.keys.sorted(), in: root)
    }

    func testListsATarballInsideXZ() throws {
        let url = try write("t.tar.xz", try tarXZ(["a.txt": Data("alpha".utf8), "dir/b.txt": repetitiveText(50_000)]))
        let listing = try ArchiveReader.list(url, format: .xz)
        XCTAssertFalse(listing.isSingleFile)
        XCTAssertEqual(listing.entries.map(\.path), ["a.txt", "dir/b.txt"])
        XCTAssertEqual(listing.entries.map(\.size), [5, 50_000])
        XCTAssertNil(listing.incomplete)
    }

    func testSingleFileShowsItsNameAndSize() throws {
        let listing = try ArchiveReader.list(try write("notes.txt.xz", try xz(repetitiveText(123_456))), format: .xz)
        XCTAssertTrue(listing.isSingleFile)
        XCTAssertEqual(listing.entries, [ArchiveEntry(path: "notes.txt", kind: .file, size: 123_456)])
        XCTAssertNil(listing.incomplete)

        // A .txz that isn't a tarball still shows the name it implies.
        let fake = try ArchiveReader.list(try write("fake.txz", try xz(repetitiveText(300))), format: .xz)
        XCTAssertEqual(fake.entries.map(\.path), ["fake.tar"])
    }

    func testEveryIntegrityCheckDecodes() throws {
        for check in ["CHECK_NONE", "CHECK_CRC32", "CHECK_CRC64", "CHECK_SHA256"] {
            let listing = try CompressedArchive.list(try write("\(check).bin.xz", try xz(noise(70_000), check: check)), format: .xz)
            XCTAssertEqual(listing.entries.first?.size, 70_000, check)
            XCTAssertNil(listing.incomplete, check)
        }
    }

    func testFollowsConcatenatedStreamsAcrossPadding() throws {
        var joined = try xz(Data("hello ".utf8))
        joined += Data(count: 8)                                    // stream padding
        joined += try xz(Data("world".utf8))
        let url = try write("greeting.xz", joined)
        let listing = try CompressedArchive.list(url, format: .xz)
        XCTAssertEqual(listing.entries.first?.size, 11)
        XCTAssertNil(listing.incomplete)
        XCTAssertEqual(try XZIndex.uncompressedSize(of: FileBytes(url: url)), 11)

        // A tarball split across two streams, the cut inside a header.
        let files = ["one.txt": repetitiveText(3000), "two.txt": repetitiveText(5000)]
        let root = dir.appendingPathComponent("split", isDirectory: true)
        for (name, data) in files { try write("split/\(name)", data) }
        let plain = try run("/usr/bin/tar", ["--no-mac-metadata", "-cf", "-", "one.txt", "two.txt"], in: root)
        let parts = try xz(plain.prefix(700)) + Data(count: 4) + xz(plain.dropFirst(700))
        let split = try ArchiveReader.list(try write("split.tar.xz", parts), format: .xz)
        XCTAssertEqual(split.entries.map(\.path), ["one.txt", "two.txt"])
        XCTAssertNil(split.incomplete)
    }

    func testTruncatedStreamsKeepWhatDecoded() throws {
        let tar = try tarXZ(["a.txt": Data("alpha".utf8), "b.bin": noise(100_000)])
        let cutTar = try ArchiveReader.list(try write("cut.tar.xz", tar.prefix(tar.count * 6 / 10)), format: .xz)
        XCTAssertEqual(cutTar.entries.map(\.path), ["a.txt", "b.bin"])
        XCTAssertEqual(cutTar.incomplete, .damaged("The compressed data ends early"))

        let single = try xz(noise(200_000))
        let cutSingle = try CompressedArchive.list(try write("cut.bin.xz", single.prefix(single.count / 2)), format: .xz)
        XCTAssertEqual(cutSingle.incomplete, .damaged("The compressed data ends early"))
        let size = try XCTUnwrap(cutSingle.entries.first?.size)
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, 200_000)

        // Cut inside the stream header: nothing decodes.
        XCTAssertThrowsError(try CompressedArchive.list(try write("head.xz", single.prefix(10)), format: .xz))
        // A damaged index makes the size unknowable without decompressing.
        XCTAssertThrowsError(try XZIndex.uncompressedSize(of: FileBytes(url: try write("noindex.xz", single.prefix(single.count - 4)))))
    }

    func testCorruptDataThrowsOrIsFlagged() throws {
        var damaged = [UInt8](try xz(repetitiveText(5000)))
        for index in 14..<40 { damaged[index] ^= 0x5A }
        XCTAssertThrowsError(try CompressedArchive.list(try write("bad.xz", Data(damaged)), format: .xz))

        // Without a readable index the whole stream is decoded, so damage to
        // the check at its end is found; the decoded bytes are kept, flagged.
        var check = [UInt8](try xz(repetitiveText(5000), check: "CHECK_CRC32"))
        check[check.count - 12 - 12 - 1] ^= 0xFF                    // inside the CRC32 before the index
        check[check.count - 1] = 0                                  // the footer's "YZ"
        let listing = try CompressedArchive.list(try write("badcheck.xz", Data(check)), format: .xz)
        XCTAssertEqual(listing.entries.first?.size, 5000)
        XCTAssertEqual(listing.incomplete, .damaged("The compressed data is corrupt"))
    }

    func testWrongMagicThrows() throws {
        XCTAssertThrowsError(try CompressedArchive.list(try write("plain.xz", repetitiveText(100)), format: .xz)) { error in
            XCTAssertEqual(error as? ArchiveError, .unrecognized("Not an xz file"))
        }
    }

    /// A single file's size comes from the index, so a large one lists
    /// without decoding past the tar check, and without a banner.
    func testSingleFileSizeComesFromTheIndex() throws {
        let compressed = try xz(repetitiveText(3_000_000))
        let limits = ArchiveLimits(maxDecompressedBytes: 65_536)
        let listing = try CompressedArchive.list(try write("big.txt.xz", compressed), format: .xz, limits: limits)
        XCTAssertEqual(listing.entries.first?.size, 3_000_000)
        XCTAssertNil(listing.incomplete)

        // With the footer gone, decoding runs into the cap instead.
        let cut = try CompressedArchive.list(try write("cut.txt.xz", compressed.prefix(compressed.count - 12)),
                                             format: .xz, limits: limits)
        XCTAssertEqual(cut.incomplete, .workLimit(decompressedBytes: 65_536))
        XCTAssertEqual(cut.entries.first?.size, 65_536)
    }

    func testTimeLimitStopsATarball() throws {
        let url = try write("slow.tar.xz", try tarXZ(["a.bin": noise(600_000), "b.txt": Data("b".utf8)]))
        let listing = try ArchiveReader.list(url, format: .xz, limits: ArchiveLimits(maxDuration: -1))
        XCTAssertEqual(listing.entries.map(\.path), ["a.bin"])
        guard case .workLimit = listing.incomplete else { return XCTFail("\(String(describing: listing.incomplete))") }
    }

    func testSniffsXZOverTheExtension() throws {
        let url = try write("mislabelled.tar", try tarXZ(["a.txt": Data("alpha".utf8)]))
        XCTAssertEqual(try ArchiveReader.list(url, format: .tar).entries.map(\.path), ["a.txt"])
        XCTAssertEqual(ArchiveReader.sniff([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 0x00, 0x04]), .xz)
        XCTAssertNil(ArchiveReader.sniff([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x01]))
    }

    func testListsTheFixtures() throws {
        let listing = try ArchiveReader.list(fixture("project.tar.xz"), format: .xz)
        XCTAssertEqual(listing.entries.map(\.path), ["project/README.md", "project/main.swift"])
        XCTAssertNil(listing.incomplete)

        let notes = try ArchiveReader.list(fixture("notes.txt.xz"), format: .xz)
        XCTAssertTrue(notes.isSingleFile)
        XCTAssertEqual(notes.entries.map(\.path), ["notes.txt"])
        XCTAssertEqual(notes.entries.first?.size, UInt64(try Data(contentsOf: fixture("notes.txt")).count))
    }
}
