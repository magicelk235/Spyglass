import Foundation

public enum StubParseError: Error, Equatable {
    case unsupportedType(String)   // extension not one of the six
    case notJSON                   // file wasn't readable JSON
    case missingDocID              // JSON lacked a usable doc_id
}

/// Parses a Google Workspace stub file into a `Stub`.
///
/// The stub is a tiny JSON object, e.g.:
/// ```json
/// {"":"WARNING!…","doc_id":"1Ypz…","resource_key":"","email":"me@x.com"}
/// ```
/// The title is NOT in the JSON — it is the filename without extension.
public enum StubParser {

    /// Parse the file at `url`. Reads the file itself.
    public static func parse(fileAt url: URL) throws -> Stub {
        guard let type = WorkspaceType(fileExtension: url.pathExtension) else {
            throw StubParseError.unsupportedType(url.pathExtension)
        }
        let data = try Data(contentsOf: url)
        let title = url.deletingPathExtension().lastPathComponent
        return try parse(data: data, type: type, title: title)
    }

    /// Parse already-loaded stub `data`. Split out so it is unit-testable
    /// without touching the filesystem.
    public static func parse(data: Data, type: WorkspaceType, title: String) throws -> Stub {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dict = object as? [String: Any]
        else {
            throw StubParseError.notJSON
        }

        let docID = (dict["doc_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let docID, !docID.isEmpty else {
            throw StubParseError.missingDocID
        }

        return Stub(
            type: type,
            title: title,
            docID: docID,
            resourceKey: nonEmpty(dict["resource_key"] as? String),
            ownerEmail: nonEmpty(dict["email"] as? String)
        )
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return s
    }
}
