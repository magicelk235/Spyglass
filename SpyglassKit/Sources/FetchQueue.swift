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

    public static func groupContainerURL(groupID: String = "group.com.spyglass.shared") -> URL? {
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

    // MARK: - UserDefaults request channel (extension → app)

    private static let defaultsKey = "pendingDocIDs"

    /// The QL extension's sandbox denies direct file writes into the group
    /// container (EPERM), but shared-UserDefaults writes go through cfprefsd
    /// (IPC) and are allowed. The extension posts requests here; the app takes
    /// them during drain and processes them like marker files.
    /// ponytail: read-modify-write is not atomic across processes; previews
    /// arrive one at a time, so a lost concurrent append is acceptable.
    public static func postRequest(docID: String, groupID: String = "group.com.spyglass.shared") {
        guard let d = UserDefaults(suiteName: groupID) else { return }
        var list = d.stringArray(forKey: defaultsKey) ?? []
        guard !list.contains(docID) else { return }
        list.append(docID)
        d.set(list, forKey: defaultsKey)
    }

    /// Takes (returns and clears) all requests posted via postRequest.
    public static func takeRequests(groupID: String = "group.com.spyglass.shared") -> [String] {
        guard let d = UserDefaults(suiteName: groupID) else { return [] }
        let list = d.stringArray(forKey: defaultsKey) ?? []
        if !list.isEmpty { d.removeObject(forKey: defaultsKey) }
        return list
    }

    private func markerURL(_ docID: String) -> URL {
        let digest = SHA256.hash(data: Data(docID.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return requestsDirectory.appendingPathComponent("\(key).req")
    }
}
