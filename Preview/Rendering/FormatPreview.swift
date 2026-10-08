import AppKit
import OSLog
import SpyglassKit

private let log = Logger(subsystem: "com.spyglass.app.preview", category: "format")

/// Produces the preview for any non-Google file. Never blank, never hangs:
/// the routed renderer gets `budget` seconds, then plain text, then a file
/// card.
@MainActor
enum FormatPreview {

    static let budget: Double = 2

    static func makeView(kind: PreviewKind?, url: URL, settings: PreviewSettings) async -> NSView {
        let view = await resolve(kind: kind, url: url, settings: settings)
        switch settings.theme {
        case .system: break
        case .light:  view.appearance = NSAppearance(named: .aqua)
        case .dark:   view.appearance = NSAppearance(named: .darkAqua)
        }
        return view
    }

    private static func resolve(kind: PreviewKind?, url: URL, settings: PreviewSettings) async -> NSView {
        let name = url.lastPathComponent
        if let kind, let group = kind.group, settings.isEnabled(group),
           let renderer = RendererRegistry.renderer(for: kind) {
            do {
                let view = try await withRenderBudget(seconds: budget) {
                    try await renderer.makeView(for: url, kind: kind, settings: settings)
                }
                log.notice("Rendered \(name, privacy: .public) as \(String(describing: kind), privacy: .public)")
                return view
            } catch {
                log.error("Renderer failed for \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        let loaded = await Task.detached(priority: .userInitiated) { TextSniffer.readText(at: url) }.value
        if let loaded {
            log.notice("Plain-text fallback for \(name, privacy: .public)")
            return FallbackViews.plainText(loaded.text, truncated: loaded.truncated, fontSize: settings.codeFontSize)
        }
        log.notice("File-card fallback for \(name, privacy: .public)")
        return FallbackViews.fileCard(for: url)
    }
}
