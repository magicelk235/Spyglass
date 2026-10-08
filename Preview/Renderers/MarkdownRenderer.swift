import AppKit
import SpyglassKit

/// GitHub-flavored Markdown with math, Mermaid diagrams and a table of
/// contents, rendered by markdown-it in the web shell.
struct MarkdownRenderer: PreviewRenderer {

    /// Longer files show their first 5 MB.
    nonisolated static let limit = 5_000_000

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let (payload, note) = try await Task.detached(priority: .userInitiated) {
            let file = try FilePrefix.read(url, limit: Self.limit)
            var payload = WebPayload(mode: .markdown, settings: settings)
            payload.text = file.text
            payload.truncated = file.truncated
            payload.baseURL = url.deletingLastPathComponent().absoluteString
            return (payload, PreviewNote.joined([file.shownPart(limit: Self.limit)]))
        }.value
        let view = try await WebRenderer.makeView(payload, settings: settings, servesLocalImages: true)
        return FallbackViews.withNote(view, note: note)
    }
}
