import Foundation

/// Builds the canonical "open in Google" URL for a stub.
///
/// The stub JSON has no URL; it must be derived from the doc id and type:
/// `https://docs.google.com/<urlPath>/<doc_id>/edit?resourcekey=<key>`
/// (Sites live on `sites.google.com`; everything else on `docs.google.com`.)
public enum GoogleURLBuilder {

    public static func openURL(for stub: Stub) -> URL? {
        let host = stub.type == .site ? "sites.google.com" : "docs.google.com"
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(stub.type.urlPath)/\(stub.docID)/edit"
        if let key = stub.resourceKey {
            components.queryItems = [URLQueryItem(name: "resourcekey", value: key)]
        }
        return components.url
    }
}
