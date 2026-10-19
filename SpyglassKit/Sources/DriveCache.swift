import Foundation

/// The rendered Drive preview the app cached for a document, if the user may
/// see it. Shared by the Quick Look preview and the Finder thumbnail so both
/// apply the same license gate.
public enum DriveCache {

    /// Gate the read, not just the app's fetch: a cache left over from a
    /// lapsed license must never show. Stale-but-present PDFs are returned;
    /// the app revalidates freshness on every scan.
    public static func licensedPDF(docID: String,
                                   license: LicenseStore = LicenseStore(),
                                   container: URL? = AppGroup.containerURL) -> Data? {
        guard license.access().allowsDrive, let container else { return nil }
        return PreviewCache(directory: container).anyCachedPDF(docID: docID)
    }
}
