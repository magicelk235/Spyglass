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
            // Counted once per opened preview, not per live reload.
            if let group = kind?.group { UsageStats.inExtension().record(group) }
            install(await formatView(kind: kind, url: url))
            watcher = FileWatcher(url: url) { [weak self] in
                Task { @MainActor in await self?.reload(url: url, kind: kind) }
            }
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

        UsageStats.inExtension().recordDrive()

        // Tier 1: the rendered PDF the app cached, behind the license gate
        // (see DriveCache). Forms/Sites arrive as a thumbnail wrapped in a
        // PDF by the app; exportable types as the real export.
        if let pdf = DriveCache.licensedPDF(docID: stub.docID), showPDF(pdf) {
            log.notice("Drive: showing cached PDF")
            return
        }

        // Tier 0 fallback: always works, no network needed.
        log.notice("Drive: showing offline card")
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

    // MARK: - Live reload

    private var watcher: FileWatcher?
    private var reloading = false
    private var reloadAgain = false

    /// Re-renders the open preview after its file changed on disk, keeping
    /// the scroll position. Changes that land mid-render queue one more pass.
    private func reload(url: URL, kind: PreviewKind?) async {
        guard !reloading else { reloadAgain = true; return }
        reloading = true
        defer { reloading = false }
        repeat {
            reloadAgain = false
            var position: ScrollMemory.Position?
            if let current = view.subviews.first { position = await ScrollMemory.capture(in: current) }
            let content = await formatView(kind: kind, url: url)
            install(content)
            ScrollMemory.restore(position, in: content)
            log.notice("Reloaded \(url.lastPathComponent, privacy: .public)")
        } while reloadAgain
    }

    // MARK: - Trial and license gate

    /// The format preview the user's access allows. Without access, the file
    /// still gets the free fallback (plain text or a summary) with a note
    /// saying why, never a blank or a lock screen.
    private func formatView(kind: PreviewKind?, url: URL) async -> NSView {
        let access = LicenseStore().access()
        let settings = PreviewSettings.load()
        guard kind?.group != nil, !access.allowsFormats else {
            let view = await FormatPreview.makeView(kind: kind, url: url, settings: settings)
            return FallbackViews.withNote(view, note: Self.trialNote(access))
        }
        log.notice("Format preview locked: \(String(describing: access), privacy: .public)")
        let view = await FormatPreview.makeView(kind: nil, url: url, settings: settings)
        return FallbackViews.withNote(view, note: Self.lockedNote(access))
    }

    /// A reminder in the last two days of the trial; nothing otherwise.
    static func trialNote(_ access: LicenseStore.Access) -> String? {
        guard case .trial(let days) = access, days <= 2 else { return nil }
        return days == 1
            ? "Last day of your Spyglass trial. Unlock Pro from the menu bar to keep these previews."
            : "2 days left in your Spyglass trial. Unlock Pro from the menu bar to keep these previews."
    }

    static func lockedNote(_ access: LicenseStore.Access) -> String {
        access == .notStarted
            ? "Open the Spyglass app once to start your free 7-day trial of rich previews."
            : "Your Spyglass trial has ended. Unlock Pro from the menu bar to bring back rich previews."
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
