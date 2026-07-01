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
}
