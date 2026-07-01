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

    public func store(docID: String, modifiedTime: String, pdf: Data) throws {
        try FileManager.default.createDirectory(at: previewsDir, withIntermediateDirectories: true)
        try pdf.write(to: pdfURL(docID))
        try modifiedTime.write(to: metaURL(docID), atomically: true, encoding: .utf8)
    }

    private func pdfURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(docID).pdf") }
    private func metaURL(_ docID: String) -> URL { previewsDir.appendingPathComponent("\(docID).meta") }
}
