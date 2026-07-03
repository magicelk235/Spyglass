import XCTest
@testable import SpyglassKit

final class FetchQueueTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dp-queue-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testEnqueueThenPendingReturnsDocID() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "D1")
        XCTAssertEqual(q.pending(), ["D1"])
    }

    func testEnqueueIsIdempotent() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "D1")
        try q.enqueue(docID: "D1")
        XCTAssertEqual(q.pending(), ["D1"])
    }

    func testCompleteRemovesMarker() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "D1")
        q.complete(docID: "D1")
        XCTAssertEqual(q.pending(), [])
    }

    func testCompleteOfAbsentMarkerIsHarmless() {
        FetchQueue(directory: tempDir()).complete(docID: "never-enqueued")
    }

    func testPendingOnEmptyQueueIsEmpty() {
        XCTAssertEqual(FetchQueue(directory: tempDir()).pending(), [])
    }

    func testMaliciousDocIDStaysInsideRequestsDir() throws {
        let root = tempDir()
        let q = FetchQueue(directory: root)
        try q.enqueue(docID: "../../etc/passwd")
        // Marker must land inside <root>/requests/, nowhere else.
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: requests.path)
        XCTAssertEqual(contents.count, 1)
        // And the docID round-trips intact for the Drive call.
        XCTAssertEqual(q.pending(), ["../../etc/passwd"])
    }

    func testPostThenTakeRequestsRoundTrip() {
        let suite = "dp-defaults-test-\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        FetchQueue.postRequest(docID: "D1", groupID: suite)
        FetchQueue.postRequest(docID: "D1", groupID: suite)   // dedup
        FetchQueue.postRequest(docID: "D2", groupID: suite)
        XCTAssertEqual(FetchQueue.takeRequests(groupID: suite), ["D1", "D2"])
        XCTAssertEqual(FetchQueue.takeRequests(groupID: suite), [])   // cleared
    }

    func testMultiplePendingDocIDs() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "A")
        try q.enqueue(docID: "B")
        XCTAssertEqual(Set(q.pending()), Set(["A", "B"]))
    }
}
