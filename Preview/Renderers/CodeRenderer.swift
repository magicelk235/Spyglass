import AppKit
import SpyglassKit

/// Source code: highlight.js in the web shell, with line numbers.
struct CodeRenderer: PreviewRenderer {

    /// Longer files show their first 2 MB.
    nonisolated static let limit = 2_000_000
    /// Syntax colors stop after this many characters; the rest stays plain
    /// so a huge file can't flood the page with millions of styled spans.
    nonisolated static let highlightLimit = 1_000_000

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        guard case .code(let language) = kind else { throw RenderError.unsupported("not a code file") }
        let (payload, note) = try await Task.detached(priority: .userInitiated) {
            let file = try FilePrefix.read(url, limit: Self.limit)
            let code = WebPayload.code(file.text, language: language, highlightLimit: Self.highlightLimit, settings: settings)
            var payload = code.payload
            payload.truncated = file.truncated
            return (payload, PreviewNote.joined([file.shownPart(limit: Self.limit), code.note]))
        }.value
        let view = try await WebRenderer.makeView(payload, settings: settings)
        return FallbackViews.withNote(view, note: note)
    }
}
