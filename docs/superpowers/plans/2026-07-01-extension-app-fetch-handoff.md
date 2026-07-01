# Extension→App Fetch Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tier 1 rendered previews work despite the QL extension having no DNS: the extension only reads the App Group cache and the app (a menu-bar agent) does all network fetching, triggered by marker files.

**Architecture:** Extension, on every exportable preview, enqueues a marker file in the App Group and wakes the app headless; it renders any cached PDF immediately, else polls the cache ~1.5 s, else shows the Tier 0 card. The app becomes an `LSUIElement` + `MenuBarExtra` agent running a `FetchWorker` that drains/watches the marker directory, fetches via the existing `DriveClient`, and writes `PreviewCache`.

**Tech Stack:** Swift 5, SwiftUI (`MenuBarExtra`), XCTest, XcodeGen, App Group container, `DispatchSource` file-system watcher.

## Global Constraints

- macOS deployment target 14.0 (from `project.yml`).
- App Group ID: `group.com.drivepeak.shared` (must match entitlements exactly).
- Free personal team signing: `DEVELOPMENT_TEAM = R28RG6QC6S`, `CODE_SIGN_STYLE: Automatic` — do not change signing settings.
- Extension must NEVER make a network call (its sandbox cannot resolve DNS).
- Preview must never hang: worst case ~1.5 s poll then Tier 0 card.
- Untrusted `docID` from stub files: filenames derived only via SHA-256 hex (existing `PreviewCache` pattern).
- Build command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeak -configuration Release build -derivedDataPath /tmp/drivepeak-dd -allowProvisioningUpdates`
- Test command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeakKit -destination 'platform=macOS' test -derivedDataPath /tmp/drivepeak-dd`
- Commits: no Co-Authored-By trailers (user's global git rule).

---

### Task 1: FetchQueue (marker files in the App Group)

**Files:**
- Create: `DrivePeakKit/Sources/FetchQueue.swift`
- Test: `Tests/FetchQueueTests.swift`
- Modify: none

**Interfaces:**
- Consumes: nothing from other tasks. Uses `Foundation`, `CryptoKit`.
- Produces (used by Tasks 2 and 4):
  - `public struct FetchQueue`
  - `public init(directory: URL)` — `directory` is the App Group container root; markers live in `<directory>/requests/`.
  - `public static func groupContainerURL(groupID: String = "group.com.drivepeak.shared") -> URL?`
  - `public var requestsDirectory: URL { get }` — the watched directory (worker needs it for DispatchSource).
  - `public func enqueue(docID: String) throws` — idempotent.
  - `public func pending() -> [String]` — docIDs of all markers.
  - `public func complete(docID: String)` — removes the marker; no error if absent.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FetchQueueTests.swift`:

```swift
import XCTest
@testable import DrivePeakKit

final class FetchQueueTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("dp-queue-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testEnqueueThenPendingReturnsDocID() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "D1")
        XCTAssertEqual(q.pending(), ["D1"])
    }

    func testEnqueueIsIdempotent() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "D1")
        try q.enqueue(docID: "D1")
        XCTAssertEqual(q.pending(), ["D1"])
    }

    func testCompleteRemovesMarker() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "D1")
        q.complete(docID: "D1")
        XCTAssertEqual(q.pending(), [])
    }

    func testCompleteOfAbsentMarkerIsHarmless() {
        FetchQueue(directory: tempDir()).complete(docID: "never-enqueued")
    }

    func testPendingOnEmptyQueueIsEmpty() {
        XCTAssertEqual(FetchQueue(directory: tempDir()).pending(), [])
    }

    func testMaliciousDocIDStaysInsideRequestsDir() throws {
        let root = tempDir()
        let q = FetchQueue(directory: root)
        try q.enqueue(docID: "../../etc/passwd")
        // Marker must land inside <root>/requests/, nowhere else.
        let requests = root.appendingPathComponent("requests", isDirectory: true)
        let contents = try FileManager.default.contentsOfDirectory(atPath: requests.path)
        XCTAssertEqual(contents.count, 1)
        // And the docID round-trips intact for the Drive call.
        XCTAssertEqual(q.pending(), ["../../etc/passwd"])
    }

    func testMultiplePendingDocIDs() throws {
        let q = FetchQueue(directory: tempDir())
        try q.enqueue(docID: "A")
        try q.enqueue(docID: "B")
        XCTAssertEqual(Set(q.pending()), Set(["A", "B"]))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeakKit -destination 'platform=macOS' test -derivedDataPath /tmp/drivepeak-dd 2>&1 | grep -E "error:|Test Suite|failed"`

Expected: compile FAILURE — `cannot find 'FetchQueue' in scope`. (New files are picked up by XcodeGen path globs; run `xcodegen generate` first so the new test file is in the project.)

- [ ] **Step 3: Write the implementation**

Create `DrivePeakKit/Sources/FetchQueue.swift`:

```swift
import Foundation
import CryptoKit

/// Marker-file queue in the App Group: the sandboxed Quick Look extension
/// cannot resolve DNS, so it enqueues "please fetch this doc" markers here and
/// the app (which can reach the network) drains them, writing PreviewCache.
///
/// A marker is `requests/<sha256(docID)>.req` whose contents are the raw docID.
/// The hashed filename means an untrusted docID can't escape the directory
/// (same trust-boundary scheme as PreviewCache.safeKey).
public struct FetchQueue {
    public let requestsDirectory: URL

    public init(directory: URL) {
        self.requestsDirectory = directory.appendingPathComponent("requests", isDirectory: true)
    }

    public static func groupContainerURL(groupID: String = "group.com.drivepeak.shared") -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// Writes (or overwrites — idempotent) the marker for this docID.
    public func enqueue(docID: String) throws {
        try FileManager.default.createDirectory(at: requestsDirectory, withIntermediateDirectories: true)
        try Data(docID.utf8).write(to: markerURL(docID), options: .atomic)
    }

    /// All currently requested docIDs (marker file contents).
    public func pending() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requestsDirectory, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "req" }.compactMap {
            (try? Data(contentsOf: $0)).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Removes the marker. Harmless if it's already gone.
    public func complete(docID: String) {
        try? FileManager.default.removeItem(at: markerURL(docID))
    }

    private func markerURL(_ docID: String) -> URL {
        let digest = SHA256.hash(data: Data(docID.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return requestsDirectory.appendingPathComponent("\(key).req")
    }
}
```

- [ ] **Step 4: Regenerate project, run tests to verify they pass**

Run:
```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeakKit -destination 'platform=macOS' test -derivedDataPath /tmp/drivepeak-dd 2>&1 | grep -E "error:|Test Suite.*(passed|failed)"
```

Expected: `Test Suite 'All tests' passed` (all existing suites + FetchQueueTests).

- [ ] **Step 5: Commit**

```bash
git add DrivePeakKit/Sources/FetchQueue.swift Tests/FetchQueueTests.swift
git commit -m "Add FetchQueue: App Group marker files for extension→app fetch requests"
```

---

### Task 2: FetchWorker (app-side drain + watch)

**Files:**
- Create: `App/FetchWorker.swift`
- Modify: none (wired into the app in Task 3)

**Interfaces:**
- Consumes (from Task 1): `FetchQueue(directory:)`, `.pending()`, `.complete(docID:)`, `.requestsDirectory`, `FetchQueue.groupContainerURL()`.
- Consumes (existing Kit API): `TokenStore().load()`, `DriveClient(store:clientID:clientSecret:)`, `client.metadata(docID:) -> DriveMetadata`, `client.exportPDF(docID:) -> Data`, `PreviewCache(directory:)`, `.cachedPDF(docID:modifiedTime:)`, `.store(docID:modifiedTime:pdf:)`, `OAuthConfig.clientID()`, `OAuthConfig.clientSecret()`.
- Produces (used by Task 3): `final class FetchWorker` with `init()` and `func start()`.

No unit test: the worker is a thin glue loop over already-tested parts
(`FetchQueue`, `PreviewCache`, `DriveClient`) plus keychain + real network,
which the test scheme can't exercise. Verified by build + manual acceptance
(Task 5).

- [ ] **Step 1: Write the implementation**

Create `App/FetchWorker.swift`:

```swift
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
```

- [ ] **Step 2: Regenerate project and build**

Run:
```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeak -configuration Release build -derivedDataPath /tmp/drivepeak-dd -allowProvisioningUpdates 2>&1 | grep -E "error:|SUCCEEDED|FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/FetchWorker.swift
git commit -m "Add FetchWorker: app-side drain/watch of fetch requests into the shared cache"
```

---

### Task 3: App becomes a menu-bar agent

**Files:**
- Modify: `App/Info.plist` (add `LSUIElement`)
- Modify: `App/DrivePeakApp.swift` (`Window` → `MenuBarExtra`, start worker)

**Interfaces:**
- Consumes (from Task 2): `FetchWorker()`, `.start()`.
- Produces: none consumed by later tasks.

- [ ] **Step 1: Add LSUIElement to Info.plist**

In `App/Info.plist`, insert directly after the `LSApplicationCategoryType` string line:

```xml
    <!-- Menu-bar agent: no Dock icon, no window on launch. The extension wakes
         this app headless to fetch previews; the UI lives in the MenuBarExtra. -->
    <key>LSUIElement</key>
    <true/>
```

- [ ] **Step 2: Replace the Window scene with MenuBarExtra**

Replace the whole body of `App/DrivePeakApp.swift` with:

```swift
import SwiftUI

@main
struct DrivePeakApp: App {
    @StateObject private var auth = GoogleAuth()
    // Held for the app's lifetime; starts draining/watching on launch, including
    // headless launches triggered by the Quick Look extension.
    private let worker = FetchWorker()

    init() {
        worker.start()
    }

    var body: some Scene {
        MenuBarExtra("DrivePeak", systemImage: "eye.circle.fill") {
            ContentView()
                .environmentObject(auth)
                .onAppear { auth.restore() }
        }
        .menuBarExtraStyle(.window)   // hosts the full ContentView as a popover
    }
}
```

- [ ] **Step 3: Build**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeak -configuration Release build -derivedDataPath /tmp/drivepeak-dd -allowProvisioningUpdates 2>&1 | grep -E "error:|SUCCEEDED|FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/Info.plist App/DrivePeakApp.swift
git commit -m "Make app a menu-bar agent (LSUIElement + MenuBarExtra), start FetchWorker on launch"
```

---

### Task 4: Extension goes network-free (cache + enqueue + wake + poll)

**Files:**
- Modify: `Preview/PreviewViewController.swift` (full-file replacement below)

**Interfaces:**
- Consumes (Task 1): `FetchQueue`, `.enqueue(docID:)`, `FetchQueue.groupContainerURL()`.
- Consumes (existing): `PreviewCache`, `.anyCachedPDF(docID:)`, `StubParser.parse(fileAt:)`, `Stub` (`.type.isExportable`, `.docID`), `StubCardView`.
- Produces: none consumed by later tasks.

Removes: DriveClient use, URLSession, the ephemeral-session workaround, the 12 s
timeout helper, the DNS diagnostic probe, and OAuthConfig/TokenStore checks (the
app owns auth now — an unauthenticated system simply never fills the cache).

- [ ] **Step 1: Replace `Preview/PreviewViewController.swift` with:**

```swift
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
```

- [ ] **Step 2: Verify no network symbols remain in the extension**

Run: `grep -nE "URLSession|DriveClient|withTimeout|DNSPROBE|OAuthConfig|TokenStore" Preview/PreviewViewController.swift`

Expected: no output.

- [ ] **Step 3: Build**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeak -configuration Release build -derivedDataPath /tmp/drivepeak-dd -allowProvisioningUpdates 2>&1 | grep -E "error:|SUCCEEDED|FAILED"
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Run the full Kit test suite (regression)**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeakKit -destination 'platform=macOS' test -derivedDataPath /tmp/drivepeak-dd 2>&1 | grep -E "error:|Test Suite.*(passed|failed)"
```

Expected: `Test Suite 'All tests' passed`.

- [ ] **Step 5: Commit**

```bash
git add Preview/PreviewViewController.swift
git commit -m "Extension: replace network fetch with cache read + fetch handoff to the app"
```

---

### Task 5: Install, manual acceptance, README

**Files:**
- Modify: `README.md` (Tier 1 section + limitations)

- [ ] **Step 1: Install the built app**

```bash
pkill -x DrivePeak 2>/dev/null
rm -rf /Applications/DrivePeak.app
xattr -cr /tmp/drivepeak-dd/Build/Products/Release/DrivePeak.app
cp -R /tmp/drivepeak-dd/Build/Products/Release/DrivePeak.app /Applications/
xattr -cr /Applications/DrivePeak.app
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f /Applications/DrivePeak.app
qlmanage -r; qlmanage -r cache
open /Applications/DrivePeak.app
```

Expected: an eye icon appears in the menu bar; NO Dock icon; NO window.

- [ ] **Step 2: Manual acceptance (user-driven — ask the user to confirm each)**

1. Click the menu-bar icon → popover shows ContentView; signed-in email visible
   (or sign in now).
2. Press Space on `test.gdoc` → either a real PDF within ~1.5 s, or the Tier 0
   card; press Space again → real PDF.
3. Quit the app (menu-bar popover → no quit button exists; use
   `pkill -x DrivePeak`). Press Space on the file → Tier 0 (cache already has
   this doc, so use a NEW Google Doc for the cold test) → app icon reappears in
   the menu bar (extension woke it) → second Space shows the real PDF.
4. Log check if anything fails:
   `log show --predicate 'subsystem BEGINSWITH "com.drivepeak"' --last 5m --info --style compact`

- [ ] **Step 3: Update README**

In `README.md`:

a. Replace the paid-account requirement bullet in **Requirements**:

```markdown
- **Tier 1 only:** a Google Cloud OAuth client (free) and a free Apple ID
  added to Xcode (personal team) for signing the shared App Group/Keychain
  entitlements. See below.
```

b. Replace section **“### 2. A paid Apple Developer account (for signing)”**
with:

```markdown
### 2. Signing with a free personal team

The app and the extension share the OAuth token (Keychain access group) and
the rendered-PDF cache (App Group). Both entitlements need a real Team ID —
Xcode's free personal team works.

1. Xcode → Settings → Accounts → add your Apple ID (creates a personal team).
2. Put the team ID in `Secrets.xcconfig` (gitignored):
   `DEVELOPMENT_TEAM = YOURTEAMID`
3. `xcodegen generate`, open the project in Xcode once and let it provision
   both targets (Signing & Capabilities), then build/install as above.
4. Open the app (menu-bar eye icon) and click **Sign in with Google**.

### How Tier 1 fetches work

The sandboxed Quick Look extension cannot reach the network, so it never
fetches. Instead it enqueues a request in the shared App Group and wakes the
app (a headless menu-bar agent), which fetches the PDF export and writes the
shared cache. The first Space on a never-seen document may show the offline
card; the render lands moments later, so the next Space (and every one after)
shows the real document.
```

c. In **Known limitations**, replace the paid-account bullet with:

```markdown
- The first preview of a never-fetched document may show the Tier 0 card while
  the app fetches in the background; press Space again for the rendered PDF.
- The sign-in flow has no wall-clock timeout for an abandoned browser tab yet.
```

(Keep the Forms/Sites bullet; drop the old “requires the paid Apple Developer
account” bullet.)

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "README: free personal-team signing; document fetch handoff and first-view behavior"
```
