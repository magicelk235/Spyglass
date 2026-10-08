import XCTest
@testable import SpyglassKit

final class ISOImageTests: ArchiveTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    /// An image of `files` made by hdiutil; `format` is its flags.
    private func makeImage(_ files: [String: Data], format: [String] = ["-iso", "-joliet"],
                           volume: String = "Spyglass Test") throws -> URL {
        let root = dir.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        let image = dir.appendingPathComponent("image-\(UUID().uuidString).iso")
        try run("/usr/bin/hdiutil", ["makehybrid"] + format + ["-default-volume-name", volume, "-o", image.path, root.path])
        return image
    }

    func testListsAJolietImage() throws {
        let image = try makeImage([
            "readme.txt": Data("hello".utf8),
            "Docs/A long file name, with spaces.markdown": repetitiveText(1000),
            "Docs/Nested/deep data.bin": repetitiveText(3000),
            "Ünïcode name.txt": Data("x".utf8),
        ])
        let listing = try ArchiveReader.list(image, format: .iso)
        XCTAssertEqual(listing.volumeName, "Spyglass Test")
        XCTAssertNil(listing.incomplete)
        XCTAssertFalse(listing.isSingleFile)
        let sizes = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.path, $0.size) })
        XCTAssertEqual(sizes, [
            "readme.txt": 5,
            "Docs": 0,
            "Docs/A long file name, with spaces.markdown": 1000,
            "Docs/Nested": 0,
            "Docs/Nested/deep data.bin": 3000,
            "Ünïcode name.txt": 1,
        ])
        let kinds = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.path, $0.kind) })
        XCTAssertEqual(kinds["Docs/Nested"], .directory)
        XCTAssertEqual(kinds["readme.txt"], .file)
        let readme = try XCTUnwrap(listing.entries.first { $0.path == "readme.txt" })
        XCTAssertEqual(readme.modified, stamp)
    }

    func testPlainISO9660NamesDropTheirVersion() throws {
        let image = try makeImage(["readme.txt": Data("hello".utf8), "notes": Data("n".utf8)], format: ["-iso"],
                                  volume: "PLAIN")
        let listing = try ISOImage.list(image)
        XCTAssertEqual(listing.volumeName, "PLAIN")
        let names = listing.entries.map(\.path).sorted()
        XCTAssertEqual(names.map { $0.uppercased() }, ["NOTES", "README.TXT"])
        XCTAssertFalse(names.contains { $0.contains(";") || $0.hasSuffix(".") })
    }

    func testUDFOnlyImagesAreUnsupported() throws {
        let image = try makeImage(["a.txt": Data("a".utf8)], format: ["-udf"])
        XCTAssertThrowsError(try ArchiveReader.list(image, format: .iso)) { error in
            XCTAssertEqual(error as? ArchiveError, .unsupported("UDF disc images aren't supported"))
        }
    }

    func testFilesThatArentImagesThrow() throws {
        for data in [repetitiveText(40_000), Data(), Data(count: 20_000)] {
            XCTAssertThrowsError(try ISOImage.list(try write("not-\(data.count).iso", data))) { error in
                XCTAssertEqual(error as? ArchiveError, .unrecognized("Not an ISO 9660 disc image"))
            }
        }
    }

    func testEntryLimit() throws {
        var files: [String: Data] = [:]
        for index in 0..<30 { files["file\(index).txt"] = Data("\(index)".utf8) }
        let listing = try ISOImage.list(try makeImage(files), limits: ArchiveLimits(maxEntries: 10))
        XCTAssertEqual(listing.entries.count, 10)
        XCTAssertEqual(listing.incomplete, .entryLimit(total: nil))
    }

    // MARK: - Hand-built images

    /// A directory record; `date` is years since 1900, month, day, hour,
    /// minute, second and the GMT offset in 15-minute steps.
    private func record(_ name: [UInt8], extent: UInt32, size: UInt32, flags: UInt8,
                        date: [UInt8] = [126, 10, 8, 12, 30, 15, 8]) -> [UInt8] {
        let padding = name.count % 2 == 0 ? 1 : 0
        var bytes: [UInt8] = [UInt8(33 + name.count + padding), 0]
        bytes.le32(extent); bytes.be32(extent); bytes.le32(size); bytes.be32(size)
        bytes += date
        bytes += [flags, 0, 0]
        bytes.le16(1); bytes.be16(1)
        bytes.append(UInt8(name.count))
        bytes += name + [UInt8](repeating: 0, count: padding)
        return bytes
    }

    /// Sector 16 holds the primary descriptor, 17 the terminator, and the
    /// root folder (`rootRecords`, after "." and "..") sector 18. `sectors`
    /// fills later sectors by number.
    private func handmadeImage(rootRecords: [[UInt8]], rootSize: UInt32 = 2048,
                               sectors: [Int: [UInt8]] = [:], imageSectors: Int = 24) -> Data {
        var image = [UInt8](repeating: 0, count: imageSectors * 2048)
        func put(_ bytes: [UInt8], sector: Int, offset: Int = 0) {
            let start = sector * 2048 + offset
            guard start < image.count else { return }
            let end = min(start + bytes.count, image.count)
            image.replaceSubrange(start..<end, with: bytes.prefix(end - start))
        }
        var primary = [UInt8](repeating: 0, count: 2048)
        primary.replaceSubrange(0..<7, with: [1] + Array("CD001".utf8) + [1])
        primary.replaceSubrange(40..<72, with: Array("HANDMADE".utf8) + [UInt8](repeating: 0x20, count: 24))
        primary.replaceSubrange(128..<132, with: [0x00, 0x08, 0x08, 0x00])
        primary.replaceSubrange(156..<190, with: record([0], extent: 18, size: rootSize, flags: 2))
        put(primary, sector: 16)
        put([255] + Array("CD001".utf8) + [1], sector: 17)
        let root = record([0], extent: 18, size: rootSize, flags: 2) + record([1], extent: 18, size: rootSize, flags: 2)
            + rootRecords.joined()
        put(root, sector: 18)
        for (sector, bytes) in sectors { put(bytes, sector: sector) }
        return Data(image)
    }

    func testCyclesMultiExtentFilesAndDates() throws {
        let image = handmadeImage(rootRecords: [
            // A folder pointing back at the root must not be walked again.
            record(Array("LOOP".utf8), extent: 18, size: 2048, flags: 2),
            record(Array("SUB".utf8), extent: 19, size: 2048, flags: 2),
            record(Array("A.TXT;1".utf8), extent: 20, size: 10, flags: 0),
            record(Array("A.TXT;1".utf8), extent: 21, size: 99, flags: 4),          // associated file
            record(Array("BIG.BIN;1".utf8), extent: 22, size: 100, flags: 0x80),    // first extent
            record(Array("BIG.BIN;1".utf8), extent: 23, size: 50, flags: 0),
            record(Array("README.;1".utf8), extent: 20, size: 3, flags: 0, date: [0, 0, 0, 0, 0, 0, 0]),
        ], sectors: [
            19: record([0], extent: 19, size: 2048, flags: 2) + record([1], extent: 18, size: 2048, flags: 2)
                + record(Array("UP".utf8), extent: 18, size: 2048, flags: 2)
                + record(Array("INNER.DAT;1".utf8), extent: 20, size: 7, flags: 0),
        ])
        let listing = try ISOImage.list(try write("handmade.iso", image))
        XCTAssertEqual(listing.volumeName, "HANDMADE")
        XCTAssertNil(listing.incomplete)
        XCTAssertEqual(listing.entries.map(\.path), ["LOOP", "SUB", "A.TXT", "BIG.BIN", "README", "SUB/UP", "SUB/INNER.DAT"])
        XCTAssertEqual(listing.entries.map(\.size), [0, 0, 10, 150, 3, 0, 7])
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expected = utc.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 10, minute: 30, second: 15))
        XCTAssertEqual(listing.entries.first { $0.path == "A.TXT" }?.modified, expected)
        XCTAssertNil(listing.entries.first { $0.path == "README" }?.modified)
    }

    func testDamagedFoldersKeepWhatWasRead() throws {
        // The subfolder lies past the end of the image.
        let cut = handmadeImage(rootRecords: [
            record(Array("A.TXT;1".utf8), extent: 20, size: 10, flags: 0),
            record(Array("GONE".utf8), extent: 900, size: 2048, flags: 2),
        ])
        let listing = try ISOImage.list(try write("cut.iso", cut))
        XCTAssertEqual(listing.entries.map(\.path), ["A.TXT", "GONE"])
        XCTAssertEqual(listing.incomplete, .damaged("The image ends inside a folder's records"))

        // A record too short to hold its fields.
        var short = record(Array("B.TXT;1".utf8), extent: 20, size: 1, flags: 0)
        short[0] = 20
        let damaged = handmadeImage(rootRecords: [record(Array("A.TXT;1".utf8), extent: 20, size: 10, flags: 0), short])
        let partial = try ISOImage.list(try write("short.iso", damaged))
        XCTAssertEqual(partial.entries.map(\.path), ["A.TXT"])
        XCTAssertEqual(partial.incomplete, .damaged("A folder's records are damaged"))

        // A root folder that can't be read at all.
        let empty = handmadeImage(rootRecords: [], imageSectors: 18)
        XCTAssertThrowsError(try ISOImage.list(try write("noroot.iso", empty))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("The image ends inside a folder's records"))
        }
    }

    func testBadBlockSizeThrows() throws {
        var image = [UInt8](handmadeImage(rootRecords: []))
        image[16 * 2048 + 128] = 0x07
        XCTAssertThrowsError(try ISOImage.list(try write("block.iso", Data(image)))) { error in
            XCTAssertEqual(error as? ArchiveError, .corrupt("The disc image's block size is invalid"))
        }
    }
}
