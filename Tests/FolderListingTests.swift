import XCTest
@testable import SpyglassKit

final class FolderListingTests: XCTestCase {
    private var dir: URL!
    private var lockedFolders: [URL] = []

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderListingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in lockedFolders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func file(_ path: String, bytes: Int = 0) throws -> URL {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        return url
    }

    @discardableResult
    private func folder(_ path: String) throws -> URL {
        let url = dir.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        lockedFolders.append(url)
    }

    private func names(_ listing: FolderListing) -> [String] {
        listing.entries.map(\.name)
    }

    // MARK: - Listing

    func testHiddenFilesAreSkipped() throws {
        try file("visible.txt")
        try file(".dotfile")
        var flagged = try file("flagged.txt")
        var values = URLResourceValues()
        values.isHidden = true
        try flagged.setResourceValues(values)

        let listing = try FolderListing.read(at: dir)
        XCTAssertEqual(names(listing), ["visible.txt"])
        XCTAssertEqual(listing.itemCount, 1)
    }

    func testFoldersComeFirstThenFinderNameOrder() throws {
        for name in ["file10.txt", "file2.txt", "File1.txt", "b.txt"] { try file(name) }
        for name in ["Zeta", "alpha", "folder 10", "folder 9"] { try folder(name) }
        XCTAssertEqual(names(try FolderListing.read(at: dir)), [
            "alpha", "folder 9", "folder 10", "Zeta",
            "b.txt", "File1.txt", "file2.txt", "file10.txt",
        ])
    }

    func testEntriesCarryKindSizeDateAndTypeDescription() throws {
        try file("five.txt", bytes: 5)
        try folder("Inside")
        let entries = try FolderListing.read(at: dir).entries
        XCTAssertEqual(entries.map(\.kind), [.folder, .file])
        XCTAssertNil(entries[0].size)
        XCTAssertEqual(entries[1].size, 5)
        XCTAssertNotNil(entries[1].modified)
        XCTAssertFalse(entries[0].typeDescription?.isEmpty ?? true)
        XCTAssertFalse(entries[1].typeDescription?.isEmpty ?? true)
        XCTAssertNotEqual(entries[0].typeDescription, entries[1].typeDescription)
    }

    func testListingIsCappedAfterSortingAndReportsTheTotal() throws {
        for index in 1...28 { try file("item \(index).txt") }
        try folder("zz folder")
        try folder("aa folder")
        let listing = try FolderListing.read(at: dir, limit: 10)
        XCTAssertEqual(listing.entries.count, 10)
        XCTAssertEqual(listing.itemCount, 30)
        XCTAssertTrue(listing.isTruncated)
        XCTAssertFalse(listing.itemCountIsLowerBound)
        // The cut keeps the first entries in display order, not whatever
        // order the disk returned.
        XCTAssertEqual(names(listing), ["aa folder", "zz folder"] + (1...8).map { "item \($0).txt" })
    }

    func testScanLimitMakesTheCountALowerBound() throws {
        for index in 1...30 { try file("f\(index)") }
        let listing = try FolderListing.read(at: dir, limit: 10, scanLimit: 20)
        XCTAssertEqual(listing.entries.count, 10)
        XCTAssertEqual(listing.itemCount, 20)
        XCTAssertTrue(listing.itemCountIsLowerBound)
        XCTAssertTrue(listing.isTruncated)
    }

    func testTimeLimitMakesTheCountALowerBound() throws {
        for index in 1...600 { try file("f\(index)") }
        let listing = try FolderListing.read(at: dir, seconds: 0)
        XCTAssertTrue(listing.itemCountIsLowerBound)
        XCTAssertGreaterThan(listing.itemCount, 0)
        XCTAssertLessThan(listing.itemCount, 600)
        XCTAssertEqual(listing.entries.count, listing.itemCount)
    }

    func testPackagesCountAsOneItem() throws {
        try file("Doc.rtfd/TXT.rtf", bytes: 100)
        try file("Doc.rtfd/image.png", bytes: 50)
        try file("notes.txt", bytes: 3)
        let listing = try FolderListing.read(at: dir)
        XCTAssertEqual(listing.itemCount, 2)
        XCTAssertEqual(listing.entries.first { $0.name == "Doc.rtfd" }?.kind, .package)

        let size = FolderSize.measure(dir)
        XCTAssertEqual(size.total, .exact(153))
        XCTAssertEqual(size.childSizes["Doc.rtfd"], 150)
    }

    func testSymlinksAreListedButNeverFollowed() throws {
        try file("target.txt", bytes: 7)
        try file("sub/inner.txt", bytes: 11)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("loop").path,
                                                   withDestinationPath: dir.path)
        try FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("sub/up").path,
                                                   withDestinationPath: "..")
        let listing = try FolderListing.read(at: dir)
        XCTAssertEqual(listing.entries.first { $0.name == "loop" }?.kind, .symlink)
        XCTAssertNil(listing.entries.first { $0.name == "loop" }?.size)

        let size = FolderSize.measure(dir)
        XCTAssertEqual(size.total, .exact(18))
        XCTAssertEqual(size.childSizes["sub"], 11)
        XCTAssertEqual(FolderListing.itemCounts(in: dir, folders: ["sub"]), ["sub": 2])
    }

    func testEmptyFolder() throws {
        try file(".DS_Store", bytes: 10)
        let listing = try FolderListing.read(at: dir)
        XCTAssertEqual(listing.entries, [])
        XCTAssertEqual(listing.itemCount, 0)
        XCTAssertFalse(listing.isTruncated)
    }

    func testUnreadableFolderThrows() throws {
        let locked = try folder("locked")
        try file("locked/secret.txt")
        try lock(locked)
        XCTAssertThrowsError(try FolderListing.read(at: locked)) { error in
            XCTAssertEqual(error as? FolderListingError, .unreadable)
        }
        XCTAssertEqual(FolderSize.measure(locked).total, .unknown)
    }

    func testMissingFolderThrows() {
        XCTAssertThrowsError(try FolderListing.read(at: dir.appendingPathComponent("missing"))) { error in
            XCTAssertEqual(error as? FolderListingError, .unreadable)
        }
    }

    // MARK: - Item counts

    func testItemCountsSkipHiddenItemsAndDontDescend() throws {
        try file("sub/b.bin")
        try file("sub/.dot")
        try file("sub/deeper/c.bin")
        try file("sub/deeper/d.bin")
        try folder("empty")
        XCTAssertEqual(FolderListing.itemCounts(in: dir, folders: ["sub", "empty"]), ["sub": 2, "empty": 0])
    }

    func testItemCountsLeaveOutUnreadableAndMissingFolders() throws {
        try file("open/a.txt")
        try file("locked/b.txt")
        try lock(dir.appendingPathComponent("locked"))
        XCTAssertEqual(FolderListing.itemCounts(in: dir, folders: ["locked", "missing", "open"]), ["open": 1])
    }

    func testItemCountsStopAtTheDeadline() throws {
        try file("a/x.txt")
        try file("b/y.txt")
        XCTAssertEqual(FolderListing.itemCounts(in: dir, folders: ["a", "b"], seconds: 0), [:])
        XCTAssertEqual(FolderListing.itemCounts(in: dir, folders: ["a", "b"], isCancelled: { true }), [:])
    }

    // MARK: - Size

    func testSizeCountsHiddenFilesAndFolderContents() throws {
        try file("a.bin", bytes: 10)
        try file(".hidden", bytes: 5)
        try file("sub/b.bin", bytes: 20)
        try file("sub/.dot", bytes: 7)
        try file("sub/deeper/c.bin", bytes: 30)
        let size = FolderSize.measure(dir)
        XCTAssertEqual(size.total, .exact(72))
        XCTAssertEqual(size.childSizes["sub"], 57)
        XCTAssertNil(size.childSizes["a.bin"])
    }

    func testItemBudgetReturnsAtLeast() throws {
        for index in 0..<50 { try file("sub\(index % 5)/f\(index)", bytes: 10) }
        let size = FolderSize.measure(dir, budget: FolderSize.Budget(seconds: 10, items: 12))
        guard case .atLeast(let bytes) = size.total else { return XCTFail("expected a lower bound, got \(size.total)") }
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertLessThan(bytes, 500)
        // Folders the walk didn't finish have no size.
        XCTAssertLessThan(size.childSizes.count, 5)
    }

    func testTimeBudgetStopsTheWalk() throws {
        for index in 0..<20 { try file("sub\(index % 4)/f\(index)", bytes: 10) }
        let size = FolderSize.measure(dir, budget: FolderSize.Budget(seconds: 0, items: 1_000))
        XCTAssertNotEqual(size.total, .exact(200))
    }

    func testCancellationStopsTheWalk() throws {
        for index in 0..<20 { try file("sub\(index % 4)/f\(index)", bytes: 10) }
        let size = FolderSize.measure(dir, isCancelled: { true })
        XCTAssertNotEqual(size.total, .exact(200))
    }

    func testUnreadableSubfolderMakesTheTotalALowerBound() throws {
        try file("open.bin", bytes: 10)
        try file("locked/inside.bin", bytes: 99)
        try file("fine/x.bin", bytes: 4)
        try lock(dir.appendingPathComponent("locked"))
        let size = FolderSize.measure(dir)
        XCTAssertEqual(size.total, .atLeast(14))
        XCTAssertNil(size.childSizes["locked"])
        XCTAssertEqual(size.childSizes["fine"], 4)
    }
}
