import Foundation
import OSLog
import DrivePeakKit

private let log = Logger(subsystem: "com.drivepeak.app", category: "scanner")

/// Discovers Google Workspace stub files on disk and enqueues their docIDs so
/// the FetchWorker pre-fetches PDF previews into the shared cache.
///
/// The Quick Look extension's sandbox is fully write-locked (no group-container
/// writes, no shared prefs, no launching the app), so it cannot ASK for a
/// fetch. Instead the app discovers every stub itself: a Spotlight live query
/// (catches stubs anywhere, fires again on new syncs) plus a direct sweep of
/// the Google Drive CloudStorage mounts (covers files Spotlight hasn't
/// indexed). Re-enqueueing an already-cached doc is cheap: the worker checks
/// modifiedTime and skips the export unless the doc changed — which is exactly
/// how edited docs get re-rendered.
final class StubScanner: NSObject {
    private var query: NSMetadataQuery?
    private let queue = FetchQueue.groupContainerURL().map { FetchQueue(directory: $0) }

    private var exportableExtensions: [String] {
        WorkspaceType.allCases.filter(\.isExportable).map(\.fileExtension)
    }

    func start() {
        directSweep()
        startSpotlight()
        // A fresh sign-in makes previously-undownloadable stubs fetchable.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reSweep), name: .drivePeakDidSignIn, object: nil)
    }

    @objc private func reSweep() { directSweep() }

    // MARK: - Spotlight live query

    private func startSpotlight() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        q.predicate = NSPredicate(
            format: exportableExtensions.map { _ in "%K LIKE %@" }.joined(separator: " OR "),
            argumentArray: exportableExtensions.flatMap { [NSMetadataItemFSNameKey, "*.\($0)"] })
        NotificationCenter.default.addObserver(self, selector: #selector(harvest(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.addObserver(self, selector: #selector(harvest(_:)),
            name: .NSMetadataQueryDidUpdate, object: q)
        DispatchQueue.main.async {
            q.start()
        }
        query = q
    }

    @objc private func harvest(_ note: Notification) {
        guard let q = query else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            enqueueStub(at: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Direct sweep of Google Drive mounts

    private func directSweep() {
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage")
        guard let mounts = try? FileManager.default.contentsOfDirectory(
            at: cloud, includingPropertiesForKeys: nil) else { return }
        let exts = Set(exportableExtensions)
        for mount in mounts where mount.lastPathComponent.hasPrefix("GoogleDrive-") {
            guard let walker = FileManager.default.enumerator(
                at: mount, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let file as URL in walker where exts.contains(file.pathExtension.lowercased()) {
                enqueueStub(at: file)
            }
        }
    }

    // MARK: - Shared

    private func enqueueStub(at url: URL) {
        guard let queue,
              let stub = try? StubParser.parse(fileAt: url),
              stub.type.isExportable else { return }
        do {
            try queue.enqueue(docID: stub.docID)
        } catch {
            log.error("Enqueue failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
