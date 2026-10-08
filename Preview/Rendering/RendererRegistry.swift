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
            return nil

        case .structured:
            return nil

        case .markdown:
            return nil

        case .diff:
            return nil

        case .table:
            return nil

        case .sqlite:
            return nil

        case .archive:
            return ArchiveRenderer()

        case .bundle:
            return nil
        }
    }
}
