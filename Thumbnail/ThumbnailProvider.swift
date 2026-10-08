import CoreGraphics
import OSLog
import QuickLookThumbnailing
import SpyglassKit

private let log = Logger(subsystem: "com.spyglass.app.thumbnail", category: "thumbnail")

/// Finder thumbnails for Google Drive stubs: the first page of the document,
/// drawn from the PDF the app cached for licensed users. With no license or
/// no cached copy, it declines and Finder keeps its usual icon.
final class ThumbnailProvider: QLThumbnailProvider {

    enum Failure: Error { case noRenderedPreview }

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        guard let stub = try? StubParser.parse(fileAt: request.fileURL),
              let data = DriveCache.licensedPDF(docID: stub.docID),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else {
            handler(nil, Failure.noRenderedPreview)
            return
        }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else {
            handler(nil, Failure.noRenderedPreview)
            return
        }
        let scale = min(request.maximumSize.width / box.width, request.maximumSize.height / box.height)
        let size = CGSize(width: (box.width * scale).rounded(), height: (box.height * scale).rounded())

        handler(QLThumbnailReply(contextSize: size) { context in
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            return true
        }, nil)
        log.notice("Thumbnail drawn for \(request.fileURL.lastPathComponent, privacy: .public)")
    }
}
