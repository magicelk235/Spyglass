import XCTest
import SwiftUI
@testable import DrivePeakKit

/// Renders the offline card to PNGs on disk so the visual result can be
/// inspected without a GUI Quick Look. Not a pass/fail assertion beyond "it
/// produced a non-empty image" — the images are the artifact.
final class CardSnapshotTests: XCTestCase {

    @MainActor
    func testRenderAllTypeCards() throws {
        let outDir = URL(fileURLWithPath: "/tmp/drivepeak-cards")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        for type in WorkspaceType.allCases {
            let stub = Stub(
                type: type,
                title: "Sample \(type.displayName) Document",
                docID: "1AbCdEf_ExampleDocId_1234567890",
                ownerEmail: "demo@example.com"
            )
            let renderer = ImageRenderer(
                content: StubCardView(stub: stub).frame(width: 380, height: 460)
            )
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                XCTFail("Failed to render \(type)")
                continue
            }
            XCTAssertGreaterThan(png.count, 1000, "\(type) render suspiciously small")
            try png.write(to: outDir.appendingPathComponent("\(type.fileExtension).png"))
        }
    }
}
