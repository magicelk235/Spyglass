import XCTest
@testable import DrivePeakKit

final class PreviewCacheTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dp-cache-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testStoreThenHitWhenModifiedTimeMatches() throws {
        let cache = PreviewCache(directory: tempDir())
        try cache.store(docID: "D1", modifiedTime: "T1", pdf: Data("PDF".utf8))
        XCTAssertEqual(cache.cachedPDF(docID: "D1", modifiedTime: "T1"),
                       Data("PDF".utf8))
    }

    func testMissWhenModifiedTimeDiffers() throws {
        let cache = PreviewCache(directory: tempDir())
        try cache.store(docID: "D1", modifiedTime: "T1", pdf: Data("PDF".utf8))
        XCTAssertNil(cache.cachedPDF(docID: "D1", modifiedTime: "T2")) // stale
    }

    func testMissWhenAbsent() {
        XCTAssertNil(PreviewCache(directory: tempDir()).cachedPDF(docID: "X", modifiedTime: "T"))
    }

    func testAnyCachedPDFIgnoresModifiedTime() throws {
        let cache = PreviewCache(directory: tempDir())
        try cache.store(docID: "D1", modifiedTime: "T1", pdf: Data("PDF".utf8))
        // Returns the PDF even though the freshness key is unknown/different.
        XCTAssertEqual(cache.anyCachedPDF(docID: "D1"), Data("PDF".utf8))
        // nil when the doc was never stored.
        XCTAssertNil(cache.anyCachedPDF(docID: "never"))
    }

    func testPathTraversalDocIDStaysInPreviewsDir() throws {
        let root = tempDir()
        let cache = PreviewCache(directory: root)
        // A malicious docID must not escape the previews directory.
        let evil = "../../escape"
        try cache.store(docID: evil, modifiedTime: "T1", pdf: Data("PWN".utf8))
        // Round-trips through the sanitized key (proves the key is stable)...
        XCTAssertEqual(cache.anyCachedPDF(docID: evil), Data("PWN".utf8))
        // ...and nothing was written outside the cache root (no traversal).
        let escaped = root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("escape.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path),
                       "docID path traversal escaped the previews directory")
    }
}
