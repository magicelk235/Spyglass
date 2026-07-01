import Foundation

/// Caches exported PDFs in a directory (the shared App Group container in
/// production), keyed by docID and invalidated by the file's modifiedTime.
/// ponytail: no eviction yet — add LRU/size cap if <container>/previews grows.
public struct PreviewCache {
    private let previewsDir: URL

    public init(directory: URL) {
        self.previewsDir = directory.appendingPathComponent("previews", isDirectory: true)
    }

    public static func groupContainerURL(groupID: String = "group.com.drivepeak.shared") -> URL? {
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

    /// docID comes from an untrusted stub file. Reduce it to a safe filename
    /// token (alphanumerics, - and _ only) so it can't contain "/" or ".." and
    /// escape the previews directory. appendingPathComponent does NOT normalize
    /// "..", so this guard is the trust boundary.
    private func safeKey(_ docID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scrubbed = String(docID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return scrubbed.isEmpty ? "_" : scrubbed
    }

    private func pdfURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(safeKey(docID)).pdf") }
    private func metaURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(safeKey(docID)).meta") }
}
