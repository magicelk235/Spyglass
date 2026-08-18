import Foundation

/// Reads the destination URL out of a `.webloc` bookmark file.
///
/// A `.webloc` is a property list holding a single `URL` key. Finder writes it
/// as a binary plist; hand-written ones are usually XML. Both decode through
/// `PropertyListSerialization`.
///
/// These matter because Google's own client is not the only way to mount Drive.
/// Mountain Duck, CloudMounter and ExpanDrive hand you a `.webloc` per document
/// instead of a `.gdoc` stub, so the same document arrives in a different
/// wrapper with the doc id buried in a URL rather than in JSON.
public enum WeblocParser {

    /// The URL a `.webloc` points at, or nil if the data isn't a plist with a
    /// usable `URL` string.
    public static func url(from data: Data) -> URL? {
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
            let dict = plist as? [String: Any],
            let string = dict["URL"] as? String,
            !string.isEmpty
        else { return nil }
        return URL(string: string)
    }
}
