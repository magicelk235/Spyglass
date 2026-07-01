import Foundation
import OSLog
import DrivePeakKit

private let log = Logger(subsystem: "com.drivepeak.app", category: "fetchworker")

/// Drains the FetchQueue: for each requested docID, fetches metadata + PDF
/// export from Drive (the app CAN resolve DNS; the extension can't) and writes
/// the shared PreviewCache. Watches the requests directory while running so
/// markers written by the extension are picked up immediately.
final class FetchWorker {
    private let queue: FetchQueue?
    private let cache: PreviewCache?
    private var watcher: DispatchSourceFileSystemObject?
    private var draining = false
    private let workQueue = DispatchQueue(label: "com.drivepeak.fetchworker")

    init() {
        let container = FetchQueue.groupContainerURL()
        queue = container.map { FetchQueue(directory: $0) }
        cache = container.map { PreviewCache(directory: $0) }
    }

    /// Drains once (markers written while the app was dead), then watches the
    /// requests directory for new markers. Safe to call once at app launch.
    func start() {
        guard let queue else {
            log.error("No App Group container — fetch worker disabled")
            return
        }
        drain()

        // Watch the requests dir. It may not exist yet (extension creates it on
        // first enqueue) — create it up front so we can open a descriptor.
        try? FileManager.default.createDirectory(at: queue.requestsDirectory,
                                                 withIntermediateDirectories: true)
        let fd = open(queue.requestsDirectory.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("Cannot watch requests dir — will only drain on launch")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: workQueue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func drain() {
        workQueue.async { [self] in
            guard !draining else { return }   // a running drain re-lists pending()
            draining = true
            Task {
                await self.processPending()
                self.workQueue.async { self.draining = false; self.drainIfMorePending() }
            }
        }
    }

    /// A marker enqueued mid-drain is picked up by this tail check.
    private func drainIfMorePending() {
        if let queue, !queue.pending().isEmpty { drain() }
    }

    private func processPending() async {
        guard let queue, let cache else { return }
        let docIDs = queue.pending()
        guard !docIDs.isEmpty else { return }

        // No sign-in → nothing we can fetch; drop the markers so the dir
        // doesn't grow. The extension keeps showing Tier 0.
        guard TokenStore().load() != nil, let clientID = OAuthConfig.clientID() else {
            docIDs.forEach { queue.complete(docID: $0) }
            return
        }

        let client = DriveClient(store: TokenStore(), clientID: clientID,
                                 clientSecret: OAuthConfig.clientSecret())
        for docID in docIDs {
            do {
                let meta = try await client.metadata(docID: docID)
                // Fresh already? Skip the export (cache hit doubles as the check).
                if cache.cachedPDF(docID: docID, modifiedTime: meta.modifiedTime) == nil {
                    let pdf = try await client.exportPDF(docID: docID)
                    try cache.store(docID: docID, modifiedTime: meta.modifiedTime, pdf: pdf)
                    log.notice("Fetched \(docID, privacy: .public) (\(pdf.count) bytes)")
                }
            } catch {
                // Failed fetch: marker still deleted below (no growth); the next
                // Space on the file re-enqueues and retries.
                log.error("Fetch failed for \(docID, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            queue.complete(docID: docID)
        }
    }
}
