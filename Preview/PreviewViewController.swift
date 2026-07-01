import Cocoa
import QuickLookUI
import SwiftUI
import PDFKit
import OSLog
import DrivePeakKit

private let log = Logger(subsystem: "com.drivepeak.app.preview", category: "preview")

/// Quick Look Preview Extension entry point.
///
/// Tier 1: when signed in and file is exportable, fetches a Drive PDF export
/// and renders it via PDFView. Falls back to Tier 0 (StubCardView) on ANY
/// failure — no auth, non-exportable type, network error, or timeout.
/// The preview is NEVER blank and NEVER hangs (2 s hard timeout).
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

        // Attempt authenticated PDF fetch only when signed in and type is exportable.
        if stub.type.isExportable,
           let clientID = OAuthConfig.clientID(bundle: Bundle(for: PreviewViewController.self)),
           TokenStore().load() != nil {

            // Render only if the fetch succeeded AND the bytes are a loadable
            // PDF; a false from showPDF (corrupt/non-PDF data) must fall through
            // to Tier 0, never leave a blank PDFView.
            if let pdfData = await fetchPDF(docID: stub.docID, clientID: clientID),
               showPDF(pdfData) {
                return
            }
            // Any failure falls through to Tier 0.
            log.notice("PDF fetch failed or timed out — falling back to Tier 0")
        }

        // Tier 0 fallback: always works, no network needed.
        show(AnyView(StubCardView(stub: stub)))
    }

    // MARK: - Private helpers

    /// Attempts to fetch (or load from cache) a PDF for the given doc.
    /// Returns nil on any error or timeout so the caller can fall back cleanly.
    private func fetchPDF(docID: String, clientID: String) async -> Data? {
        do {
            return try await withTimeout(seconds: 2.0) {
                // All work here is plain async — no main-actor-isolated state.
                let store = TokenStore()
                let client = DriveClient(store: store, clientID: clientID)
                let cache: PreviewCache? = PreviewCache.groupContainerURL().map { PreviewCache(directory: $0) }

                // Fetch metadata to key the cache by the doc's modifiedTime. If
                // metadata fails (offline, 401, timeout, decode), fall back to
                // ANY cached PDF for this doc — a stale-but-real render beats
                // downgrading to the Tier 0 card. Only give up (nil) if there's
                // no cached PDF at all.
                let meta: DriveMetadata
                do {
                    meta = try await client.metadata(docID: docID)
                } catch {
                    if let cached = cache?.anyCachedPDF(docID: docID) { return cached }
                    throw error
                }

                // Fresh metadata: serve the cache if it matches, else export.
                if let cached = cache?.cachedPDF(docID: docID, modifiedTime: meta.modifiedTime) {
                    return cached
                }
                let pdf = try await client.exportPDF(docID: docID)
                // Don't write a result that arrived after the deadline — a
                // timed-out task is cancelled, so bail before the cache write.
                try Task.checkCancellation()
                try? cache?.store(docID: docID, modifiedTime: meta.modifiedTime, pdf: pdf)
                return pdf
            }
        } catch {
            log.error("PDF fetch error: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

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

// MARK: - Timeout helper

/// Races `operation` against a deadline. Throws `CancellationError` if the
/// deadline fires first. The operation closure MUST NOT touch main-actor-
/// isolated state (it runs in a detached child task).
private func withTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        // First result wins; cancel the loser.
        guard let result = try await group.next() else { throw CancellationError() }
        group.cancelAll()
        return result
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
