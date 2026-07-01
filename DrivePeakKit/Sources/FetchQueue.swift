import Foundation
import CryptoKit

/// Marker-file queue in the App Group: the sandboxed Quick Look extension
/// cannot resolve DNS, so it enqueues "please fetch this doc" markers here and
/// the app (which can reach the network) drains them, writing PreviewCache.
///
/// A marker is `requests/<sha256(docID)>.req` whose contents are the raw docID.
/// The hashed filename means an untrusted docID can't escape the directory
/// (same trust-boundary scheme as PreviewCache.safeKey).
public struct FetchQueue {
    public let requestsDirectory: URL

    public init(directory: URL) {
        self.requestsDirectory = directory.appendingPathComponent("requests", isDirectory: true)
    }

    public static func groupContainerURL(groupID: String = "group.com.drivepeak.shared") -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// Writes (or overwrites — idempotent) the marker for this docID.
    public func enqueue(docID: String) throws {
        try FileManager.default.createDirectory(at: requestsDirectory, withIntermediateDirectories: true)
        try Data(docID.utf8).write(to: markerURL(docID), options: .atomic)
    }

    /// All currently requested docIDs (marker file contents).
    public func pending() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requestsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "req" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Removes the marker. Harmless if it's already gone.
    public func complete(docID: String) {
        try? FileManager.default.removeItem(at: markerURL(docID))
    }

    private func markerURL(_ docID: String) -> URL {
        let digest = SHA256.hash(data: Data(docID.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return requestsDirectory.appendingPathComponent("\(key).req")
    }
}
