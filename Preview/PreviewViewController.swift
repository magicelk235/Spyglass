import Cocoa
import QuickLookUI
import SwiftUI
import PDFKit
import OSLog
import SpyglassKit

private let log = Logger(subsystem: "com.spyglass.app.preview", category: "preview")

/// Quick Look Preview Extension entry point.
///
/// Every file is routed first. Google stubs and `.webloc` bookmarks take the
/// Drive path below; everything else goes to `FormatPreview`.
///
/// The extension's sandbox is read-only in practice: no DNS (every host fails
/// with -1003), no group-container writes, no shared-prefs writes, no
/// launching the app. So the Drive path is a pure cache READER. The app (a
/// menu-bar agent) discovers stub files on disk, pre-fetches their PDF
/// exports, and keeps the shared App Group cache warm. This controller
/// renders the cached PDF if present, else the Tier 0 card. The preview is
/// NEVER blank and NEVER hangs.
final class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        log.notice("Preview invoked for \(url.lastPathComponent, privacy: .public)")

        let uti = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
        let kind = PreviewKind.route(filename: url.lastPathComponent, uti: uti)
        guard kind == .googleStub || kind == .webloc else {
            let settings = PreviewSettings.load()
            install(await FormatPreview.makeView(kind: kind, url: url, settings: settings))
            return
        }

        // Parse stub — failure shows UnparseableView instead of throwing.
        let stub: Stub
        do {
            stub = try StubParser.parse(fileAt: url)
        } catch StubParseError.notAGoogleDocument(let link) {
            // A .webloc that points somewhere other than a Google document.
            // Spyglass owns the type now, so it has to render these too, and a
            // card naming the destination beats claiming the file is broken.
            log.notice("Webloc points outside Google Workspace")
            show(AnyView(LinkCardView(filename: url.lastPathComponent, link: link)))
            return
        } catch {
            log.error("Parse failed: \(String(describing: error), privacy: .public)")
            show(AnyView(UnparseableView(filename: url.lastPathComponent)))
            return
        }

        // Freshness can't be checked here (needs metadata = network); the app
        // validated modifiedTime when it wrote the cache and revalidates on
        // every scan pass.
        // Tier 1 (rendered PDF) requires a valid license. Gate the READ, not
        // just the app's fetch: a stale/trial cache must never leak a rendered
        // preview to an unlicensed user. No license -> fall through to Tier 0.
        // Any type with a cached PDF renders (Forms/Sites arrive as a thumbnail
        // wrapped in a PDF by the app; exportable types as the real export).
        if LicenseStore().isPro,
           let container = FetchQueue.groupContainerURL(),
           let pdf = PreviewCache(directory: container).anyCachedPDF(docID: stub.docID),
           showPDF(pdf) {
            return
        }

        // Tier 0 fallback: always works, no network needed.
        show(AnyView(StubCardView(stub: stub)))
    }

    // MARK: - Rendering

    /// Renders the PDF. Returns false (rendering nothing) if the data isn't a
    /// loadable PDF, so the caller can fall back to the Tier 0 card.
    private func showPDF(_ data: Data) -> Bool {
        guard let doc = PDFDocument(data: data) else { return false }
        let pdfView = PDFView(frame: view.bounds)
        pdfView.autoresizingMask = [.width, .height]
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.document = doc
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(pdfView)
        // A PDFView assigned its document before layout lands scrolled to the
        // last page. Snap to page 1 in viewDidLayout (below), which fires after
        // Quick Look finishes sizing the panel — a single async runs too early.
        self.pdfView = pdfView
        self.needsSnapToTop = true
        return true
    }

    private weak var pdfView: PDFView?
    private var needsSnapToTop = false

    override func viewDidLayout() {
        super.viewDidLayout()
        guard needsSnapToTop, let pdfView, let first = pdfView.document?.page(at: 0),
              pdfView.bounds.height > 1 else { return }
        needsSnapToTop = false   // one-shot: leave the user free to scroll after
        let top = CGPoint(x: 0, y: first.bounds(for: .mediaBox).height)
        pdfView.go(to: PDFDestination(page: first, at: top))
    }

    /// Installs a SwiftUI hosting view as the view's sole subview.
    private func show(_ root: AnyView) {
        install(NSHostingView(rootView: root))
    }

    private func install(_ content: NSView) {
        content.frame = view.bounds
        content.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(content)
    }
}

// MARK: - Unparseable fallback

/// Shown when the file isn't a stub we can parse (corrupt/empty). Rare, but
/// the preview must never be blank.
private struct UnparseableView: View {
    let filename: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(filename).font(.headline).lineLimit(2)
            Text("Not a readable Google Workspace file")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Non-Google webloc

/// Shown for a `.webloc` that points outside Google Workspace. Spyglass claims
/// the whole `.webloc` type to catch the ones third-party Drive clients write,
/// so it inherits every other bookmark on the machine and owes them a preview
/// that names where they lead.
private struct LinkCardView: View {
    let filename: String
    let link: URL

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "safari")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(filename.replacingOccurrences(of: ".webloc", with: ""))
                .font(.headline).lineLimit(2)
            if let host = link.host {
                Text(host).font(.callout).foregroundStyle(.secondary)
            }
            Text(link.absoluteString)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
