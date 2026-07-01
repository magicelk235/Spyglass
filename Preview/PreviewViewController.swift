import Cocoa
import QuickLookUI
import SwiftUI
import OSLog
import DrivePeakKit

private let log = Logger(subsystem: "com.drivepeak.app.preview", category: "preview")

/// Quick Look Preview Extension entry point.
///
/// macOS instantiates this when the user presses Space on a file whose UTI is
/// listed in `QLSupportedContentTypes` (see Preview/Info.plist). It must hand
/// back a view quickly and never block — the extension is sandboxed and
/// short-lived.
final class PreviewViewController: NSViewController, QLPreviewingController {

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        log.notice("Preview invoked for \(url.lastPathComponent, privacy: .public)")

        let root: AnyView
        do {
            let stub = try StubParser.parse(fileAt: url)
            root = AnyView(StubCardView(stub: stub))
        } catch {
            log.error("Parse failed: \(String(describing: error), privacy: .public)")
            root = AnyView(UnparseableView(filename: url.lastPathComponent))
        }

        let hosting = NSHostingView(rootView: root)
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hosting)
    }
}

/// Shown when the file isn't a stub we can parse (corrupt/empty). Rare, but the
/// preview must never be blank.
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
