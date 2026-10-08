import AppKit
import SpyglassKit

/// Unified diffs and patches: one tab per file, color-coded hunks.
struct DiffRenderer: PreviewRenderer {

    /// Longer files show their first 2 MB.
    nonisolated static let limit = 2_000_000

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let (payload, note) = try await Task.detached(priority: .userInitiated) {
            let file = try FilePrefix.read(url, limit: Self.limit)
            let shown = file.shownPart(limit: Self.limit)
            guard let diff = try? UnifiedDiff.parse(file.text) else {
                // Not a diff the parser understands: show the text, highlighted.
                let code = WebPayload.code(file.text, language: "diff",
                                           highlightLimit: CodeRenderer.highlightLimit, settings: settings)
                var payload = code.payload
                payload.truncated = file.truncated
                return (payload, PreviewNote.joined([shown, code.note]))
            }
            var payload = WebPayload(mode: .diff, settings: settings)
            payload.files = diff.files
            payload.preamble = diff.preamble.isEmpty ? nil : diff.preamble
            payload.truncated = file.truncated
            return (payload, PreviewNote.joined([shown]))
        }.value
        let view = try await WebRenderer.makeView(payload, settings: settings)
        return FallbackViews.withNote(view, note: note)
    }
}
