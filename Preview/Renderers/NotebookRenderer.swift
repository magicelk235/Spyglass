import AppKit
import SpyglassKit

/// Jupyter notebooks in the web shell: Markdown cells through the same
/// pipeline as Markdown files, code cells highlighted in the kernel's
/// language, and outputs as the one representation `Notebook` picked.
struct NotebookRenderer: PreviewRenderer {

    func makeView(for url: URL, kind: PreviewKind, settings: PreviewSettings) async throws -> NSView {
        let (payload, note) = try await Task.detached(priority: .userInitiated) {
            try Self.prepare(url, settings: settings)
        }.value
        let view = try await WebRenderer.makeView(payload, settings: settings, servesLocalImages: true)
        return FallbackViews.withNote(view, note: note)
    }

    nonisolated static func prepare(_ url: URL, settings: PreviewSettings,
                                    limits: Notebook.Limits = .standard) throws -> (WebPayload, String?) {
        let notebook = try Notebook.read(at: url, limits: limits)
        var notes: [String?] = []
        if let cut = notebook.cut {
            notes.append("Showing the cells in the first \(PreviewNote.size(cut.readBytes)) of \(PreviewNote.size(cut.fileSize))")
        }
        if notebook.cells.count < notebook.cellCount {
            notes.append("Showing the first \(notebook.cells.count.formatted()) of \(notebook.cellCount.formatted()) cells")
        }
        if notebook.omittedImageCount > 0 {
            let images = notebook.omittedImageCount == 1 ? "1 image" : "\(notebook.omittedImageCount.formatted()) images"
            notes.append("\(images) left out to keep images under \(PreviewNote.size(limits.imageBudget))")
        }
        var payload = WebPayload(mode: .notebook, settings: settings)
        payload.notebook = notebook
        payload.truncated = notes.contains { $0 != nil }
        payload.baseURL = url.deletingLastPathComponent().absoluteString
        return (payload, PreviewNote.joined(notes))
    }
}
