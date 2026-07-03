import Foundation

/// A parsed Google Workspace stub file: its type, doc id, and metadata.
///
/// The stub's own JSON carries only `doc_id`, `resource_key`, and `email` —
/// no title and no URL. The title comes from the filename; the URL is built
/// from `doc_id` + type (see `GoogleURLBuilder`).
public struct Stub: Equatable, Sendable {
    public let type: WorkspaceType
    public let title: String
    public let docID: String
    public let resourceKey: String?
    public let ownerEmail: String?

    public init(
        type: WorkspaceType,
        title: String,
        docID: String,
        resourceKey: String? = nil,
        ownerEmail: String? = nil
    ) {
        self.type = type
        self.title = title
        self.docID = docID
        self.resourceKey = resourceKey
        self.ownerEmail = ownerEmail
    }
}
