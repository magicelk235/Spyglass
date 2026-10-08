import SpyglassKit

/// The renderer for each kind of file. nil sends the file straight to the
/// plain-text / file-card fallback.
@MainActor
enum RendererRegistry {
    static func renderer(for kind: PreviewKind) -> PreviewRenderer? {
        switch kind {
        case .googleStub, .webloc:
            // Handled by PreviewViewController's Drive path, never routed here.
            return nil

        case .code:
            return CodeRenderer()

        case .structured:
            return StructuredRenderer()

        case .markdown:
            return MarkdownRenderer()

        case .diff:
            return DiffRenderer()

        case .table:
            return TableRenderer()

        case .sqlite:
            return SQLiteRenderer()

        case .archive:
            return ArchiveRenderer()

        case .bundle:
            return BundleRenderer()

        case .notebook:
            return NotebookRenderer()

        case .jsonLines:
            return JSONLinesRenderer()

        case .torrent:
            return TorrentRenderer()

        case .binary:
            return BinaryRenderer()

        case .folder:
            return FolderRenderer()
        }
    }
}
