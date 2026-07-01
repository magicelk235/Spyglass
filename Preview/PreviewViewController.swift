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
        let type = WorkspaceType(fileExtension: url.pathExtension)
        let title = url.deletingPathExtension().lastPathComponent
        log.notice("DrivePeak preview invoked for \(url.lastPathComponent, privacy: .public)")

        // Step 1: prove routing works. Real card lands in step 3.
        let hosting = NSHostingView(
            rootView: PipelineProofView(
                title: title,
                typeName: type?.displayName ?? "Unknown (\(url.pathExtension))"
            )
        )
        hosting.frame = view.bounds
        hosting.autoresizingMask = [.width, .height]
        view.subviews.forEach { $0.removeFromSuperview() }
        view.addSubview(hosting)
    }
}

private struct PipelineProofView: View {
    let title: String
    let typeName: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text(title).font(.title2).bold()
            Text(typeName).foregroundStyle(.secondary)
            Text("DrivePeak pipeline OK").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
