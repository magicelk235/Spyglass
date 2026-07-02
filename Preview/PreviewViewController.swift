import Cocoa
import QuickLookUI
import SwiftUI
import PDFKit
import OSLog
import DrivePeakKit

private let log = Logger(subsystem: "com.drivepeak.app.preview", category: "preview")

/// Quick Look Preview Extension entry point.
///
/// The extension's sandbox is read-only in practice: no DNS (every host fails
/// with -1003), no group-container writes, no shared-prefs writes, no
/// launching the app. So the extension is a pure cache READER. The app (a
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

        // Parse stub — failure shows UnparseableView instead of throwing.
        let stub: Stub
        do {
            stub = try StubParser.parse(fileAt: url)
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
        if LicenseStore().isPro,
           stub.type.isExportable,
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
        pdfView.autoScales = true
        pdfView.document = doc
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(pdfView)
        // A PDFView assigned its document before layout lands scrolled to the
        // last page. Force it back to page 1 after the scroll view has sized.
        if let first = doc.page(at: 0) {
            // PDF coords have origin at bottom-left, so the top of the page is
            // (0, height). Scroll there so page 1 shows from the top.
            let top = CGPoint(x: 0, y: first.bounds(for: .mediaBox).height)
            DispatchQueue.main.async { pdfView.go(to: PDFDestination(page: first, at: top)) }
        }
        return true
    }

    /// Installs a SwiftUI hosting view as the view's sole subview.
    private func show(_ root: AnyView) {
        let hosting = NSHostingView(rootView: root)
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hosting)
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
