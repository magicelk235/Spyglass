import Foundation
import CryptoKit

/// Caches exported PDFs in a directory (the shared App Group container in
/// production), keyed by docID and invalidated by the file's modifiedTime.
/// ponytail: no eviction yet — add LRU/size cap if <container>/previews grows.
public struct PreviewCache {
    private let previewsDir: URL

    public init(directory: URL) {
        self.previewsDir = directory.appendingPathComponent("previews", isDirectory: true)
    }

    public static func groupContainerURL(groupID: String = "group.com.spyglass.shared") -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    public func cachedPDF(docID: String, modifiedTime: String) -> Data? {
        guard let meta = try? String(contentsOf: metaURL(docID), encoding: .utf8),
              meta == modifiedTime,
              let data = try? Data(contentsOf: pdfURL(docID))
        else { return nil }
        return data
    }

    /// Returns the cached PDF for this doc regardless of freshness, or nil if
    /// none. Used as an offline fallback when we can't fetch metadata to
    /// validate staleness — a stale-but-real PDF beats downgrading to Tier 0.
    public func anyCachedPDF(docID: String) -> Data? {
        try? Data(contentsOf: pdfURL(docID))
    }

    public func store(docID: String, modifiedTime: String, pdf: Data) throws {
        try FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)
        // Invalidate the meta first so a concurrent reader never pairs the old
        // meta with the new PDF (it sees either "no meta" → miss, or the fresh
        // pair). Meta is written last as the commit point.
        try? FileManager.default.removeItem(at: metaURL(docID))
        try pdf.write(to: pdfURL(docID), options: .atomic)
        try modifiedTime.write(to: metaURL(docID), atomically: true, encoding: .utf8)
    }

    /// docID comes from an untrusted stub file. Hash it to a fixed hex filename:
    /// (1) it can't contain "/" or ".." to escape the previews directory (the
    /// trust boundary), and (2) unlike a lossy character scrub, distinct docIDs
    /// never collide onto the same file (which would serve one doc's PDF for
    /// another via anyCachedPDF, which does no content check).
    private func safeKey(_ docID: String) -> String {
        let digest = SHA256.hash(data: Data(docID.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func pdfURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(safeKey(docID)).pdf") }
    private func metaURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(safeKey(docID)).meta") }
}
