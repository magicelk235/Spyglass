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
            return nil

        case .jsonLines:
            return nil

        case .torrent:
            return nil

        case .binary:
            return nil

        case .folder:
            return nil
        }
    }
}
