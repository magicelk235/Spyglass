import Foundation

/// Recovers a `Stub` from a Google Workspace document URL.
///
/// The inverse of `GoogleURLBuilder`. `.gdoc` stubs carry the doc id in JSON,
/// but a `.webloc` carries only a link, so the type and doc id have to come
/// back out of the path:
///
///     https://docs.google.com/spreadsheets/d/<doc id>/edit#gid=0
///                             ^^^^^^^^^^^^   ^^^^^^^^^^
///                             type segment   doc id
///
/// The type segment is matched against `WorkspaceType.urlPath` so the mapping
/// stays in one place. Links that name no type, such as
/// `drive.google.com/file/d/<id>/view`, return nil: without a type there is no
/// way to pick an icon, a product name, or an export format.
public enum GoogleURLParser {

    private static let hosts: Set<String> = ["docs.google.com", "sites.google.com"]

    public static func stub(from url: URL, title: String) -> Stub? {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }

        // ["spreadsheets", "d", "<doc id>", "edit"] once the leading "/" is gone.
        let parts = url.pathComponents.filter { $0 != "/" }
        guard
            let marker = parts.firstIndex(of: "d"), marker > 0,
            parts.index(after: marker) < parts.endIndex
        else { return nil }

        let segment = parts[marker - 1]
        guard let type = WorkspaceType(urlSegment: segment) else { return nil }

        let docID = parts[marker + 1]
        guard !docID.isEmpty else { return nil }

        return Stub(
            type: type,
            title: title,
            docID: docID,
            resourceKey: resourceKey(from: url)
        )
    }

    private static func resourceKey(from url: URL) -> String? {
        guard
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let value = items.first(where: { $0.name == "resourcekey" })?.value,
            !value.isEmpty
        else { return nil }
        return value
    }
}
