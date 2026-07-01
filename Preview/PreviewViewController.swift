import Cocoa
import QuickLookUI
import SwiftUI
import PDFKit
import OSLog
import DrivePeakKit

private let log = Logger(subsystem: "com.drivepeak.app.preview", category: "preview")

/// Quick Look Preview Extension entry point.
///
/// The extension's sandbox cannot resolve DNS (verified: every host fails with
/// NSURLErrorDomain -1003), so it makes NO network calls. Tier 1 works by
/// handoff: on every exportable preview it enqueues a fetch marker and wakes
/// the app (headless menu-bar agent), which fetches the PDF export and writes
/// the shared App Group cache. This controller renders whatever is cached —
/// immediately on a hit, after a short poll on a miss — and otherwise shows
/// the Tier 0 card. The preview is NEVER blank and NEVER hangs.
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

        if stub.type.isExportable,
           let container = FetchQueue.groupContainerURL() {
            let cache = PreviewCache(directory: container)

            // Always enqueue + wake, even on a cache hit: the app re-checks
            // modifiedTime and re-exports if the doc changed, so a stale
            // preview self-heals by the next Space.
            requestFetch(docID: stub.docID, container: container)

            // Freshness can't be checked here (needs metadata = network); the
            // app validated modifiedTime when it wrote the cache.
            if let pdf = cache.anyCachedPDF(docID: stub.docID), showPDF(pdf) {
                return
            }

            // Miss: give the just-woken app a moment. If the fetch is quick,
            // the FIRST Space already shows the real document.
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let pdf = cache.anyCachedPDF(docID: stub.docID), showPDF(pdf) {
                    return
                }
            }
            log.notice("No cached PDF after poll — falling back to Tier 0")
        }

        // Tier 0 fallback: always works, no network needed.
        show(AnyView(StubCardView(stub: stub)))
    }

    // MARK: - Fetch handoff

    /// Enqueues a fetch marker and launches the app without activating it.
    /// Failures are non-fatal: the preview just stays Tier 0.
    private func requestFetch(docID: String, container: URL) {
        do {
            try FetchQueue(directory: container).enqueue(docID: docID)
        } catch {
            log.error("Enqueue failed: \(String(describing: error), privacy: .public)")
            return
        }

        // .appex lives at DrivePeak.app/Contents/PlugIns/DrivePeakPreview.appex
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()   // PlugIns/
            .deletingLastPathComponent()   // Contents/
            .deletingLastPathComponent()   // DrivePeak.app
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, error in
            if let error {
                // Sandbox may deny launching. The marker persists: the app
                // fetches it whenever the user next opens it.
                log.error("App wake failed: \(String(describing: error), privacy: .public)")
            }
        }
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
