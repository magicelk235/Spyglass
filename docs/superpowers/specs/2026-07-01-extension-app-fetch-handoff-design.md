# DrivePeak — Extension→App Fetch Handoff

**Date:** 2026-07-01
**Status:** Design (pending user review)

## Problem

Tier 1 rendered previews never appear. The sandboxed Quick Look preview
extension **cannot resolve DNS** — confirmed by a diagnostic probe: every host
(`apple.com`, `dns.google`, `www.googleapis.com`) fails instantly with
`NSURLErrorDomain -1003`, "Resolved 0 endpoints in 0ms". The extension's
sandbox has no usable network resolution path on this system, regardless of the
`com.apple.security.network.client` entitlement (which is present and correctly
signed).

The **app process resolves DNS fine** (OAuth sign-in and token exchange succeed
from the app). So the fix is architectural: the extension must never touch the
network. The app does all fetching; the extension only reads the shared cache.

## Constraints (established this session)

- App Group `group.com.drivepeak.shared` is provisioned and shared between app
  and extension (verified in signed entitlements).
- The data-protection keychain group `<prefix>.com.drivepeak.shared` is shared
  and readable from both processes (token sharing now works after adding
  `kSecUseDataProtectionKeychain`).
- `PreviewCache` already caches exported PDFs in the App Group container, keyed
  by `docID` + `modifiedTime`, with a SHA-256 filename (no path traversal).
- The app is currently a plain windowed SwiftUI app (`Window` scene, no
  `LSUIElement`); it quits when its window closes. It is therefore usually **not
  running** when the user presses Space on a stub file.

## Goals

- Any exportable Google Workspace stub (Docs/Sheets/Slides/Drawings) shows a
  **real rendered PDF preview**, not just the Tier 0 card — for *any* doc, not
  only pre-warmed ones.
- No window ever pops when the extension triggers a fetch.
- The preview is never blank and never hangs (existing invariant preserved).
- Minimal moving parts. No XPC service, no bundled CLI helper.

## Non-goals

- Forms/Sites (not exportable) — always Tier 0, unchanged.
- Offline first-view of a never-seen doc — impossible without a prior fetch.
- Cache eviction policy — out of scope (existing `ponytail:` note stands).

## Approach

**Extension reads cache; app fetches on request via an App Group marker file;
extension wakes the app headless on a cache miss.**

Rejected alternatives:
- *Bundled CLI helper* — the extension sandbox can't reliably `exec` a helper,
  and the helper would need its own keychain access. More parts, more failure
  modes.
- *App pre-warms only* — no on-demand trigger means unseen docs stay Tier 0
  until the user manually opens the app. Worse coverage, worse UX.

## Architecture

### 1. App becomes a menu-bar background agent

- Add `LSUIElement = YES` to `App/Info.plist` → no Dock icon, no window on
  launch.
- Replace the `Window` scene with a `MenuBarExtra` scene. The popover holds the
  existing `ContentView` (sign-in button, signed-in email, status). This keeps
  sign-in always reachable without a Dock presence or a window pop.
- The app is launchable two ways with identical behavior: user clicks the menu
  bar item (popover), or the extension wakes it headless (it just runs the
  request watcher and stays idle in the menu bar). No launch-mode flag needed —
  the menu-bar app is always "headless" in the window sense.

### 2. Request markers (extension → app)

A new small type in `DrivePeakKit`, `FetchQueue`, owns a `requests/`
subdirectory of the App Group container:

- `FetchQueue.enqueue(docID:)` — writes `requests/<sha256(docID)>.req`
  containing the raw `docID`. Atomic write. Idempotent (same doc → same file).
- `FetchQueue.pending()` — lists `.req` files, returns their `docID` contents.
- `FetchQueue.complete(docID:)` — deletes the marker.

`docID` is untrusted (from the stub file). The filename is a SHA-256 hex digest
(same scheme as `PreviewCache.safeKey`) so a marker can't escape `requests/`.
The `docID` used for the actual Drive call is the file *contents*, read back and
used only as a Drive API path component — the existing `DriveClient` already
percent-encodes / path-scopes it.

### 3. App-side fetch worker

A new `FetchWorker` (app target), started when the app launches:

- On launch, drains `FetchQueue.pending()` once (handles markers written while
  the app was dead).
- Watches `requests/` with a `DispatchSource` file-system monitor for new
  markers while running.
- For each pending `docID`: run the existing `DriveClient.metadata` +
  `exportPDF`, write to `PreviewCache`, then `FetchQueue.complete(docID:)`.
- Requires a signed-in token (reads via `TokenStore`). No token → drain the
  queue silently (delete markers, write nothing); the extension stays Tier 0.
- Fetch failure → delete the marker (so the dir doesn't grow) but write no
  cache; the next Space re-enqueues and retries.
- Runs off the main actor; failures are logged, never fatal.

### 4. Extension: cache-read + wake + short poll

`PreviewViewController.fetchPDF` is rewritten to **never call the network**:

1. Compute cache lookup. On a **hit** (any cached PDF for the doc — freshness
   can't be validated without metadata, and the app already validated it on
   write), return it → render real PDF.
2. On a **miss**:
   a. `FetchQueue.enqueue(docID:)`.
   b. Wake the app headless: `NSWorkspace.openApplication(at: appURL,
      configuration:)` with `activates = false` and `addsToRecentItems = false`.
      Locate the app bundle from the extension's own bundle path
      (`.../DrivePeak.app/Contents/PlugIns/DrivePeakPreview.appex` → three
      parents up).
   c. Poll the cache for up to ~1.5 s (e.g. 6 × 250 ms). If the app fetches
      fast, the **first** Space already upgrades to a real preview.
   d. If still no cache after the poll → return nil → Tier 0 card. The marker
      remains; the fetch usually completes moments later, so the **next** Space
      is a real preview.

All extension DNS/network code (ephemeral session, DriveClient construction,
metadata/export calls, the DNS diagnostic probe) is **removed** from the
extension. `DriveClient` stays in `DrivePeakKit`, now used only by the app.

## Data flow

```
Space on stub
  └─ extension: PreviewCache hit?
       ├─ yes → render PDF                                  [instant]
       └─ no  → FetchQueue.enqueue(docID)
                NSWorkspace wake app (hidden, no activate)
                poll cache ≤1.5s
                  ├─ appeared → render PDF                  [first-view upgrade]
                  └─ timeout  → Tier 0 card                 [next Space real]

App (menu bar, woken or already running)
  └─ FetchWorker: drain + watch requests/
       └─ per docID: metadata + exportPDF → PreviewCache.store → marker delete
```

## Error handling

| Situation | Behavior |
|-----------|----------|
| Not signed in | Worker drains markers, writes nothing. Extension shows Tier 0. |
| Fetch fails (network/401/export) | Marker deleted, no cache write. Next Space retries. |
| App won't launch | Extension poll times out → Tier 0. No hang. |
| Non-exportable type (Forms/Sites) | Extension never enqueues → Tier 0 (unchanged). |
| Marker dir grows | Every processed marker is deleted (success or fail). |
| Stale cache | App writes cache keyed by fresh `modifiedTime`; extension serves whatever is cached. Doc edited → app re-exports on next enqueue (new modifiedTime), overwrites. |

## Testing

Unit-testable in `DrivePeakKit` (no signing, no network), matching the existing
test style:

- `FetchQueue`: enqueue writes a marker; `pending()` returns the docID;
  `complete()` removes it; enqueue is idempotent; a malicious docID
  (`../../etc`) stays inside `requests/`.
- `PreviewCache` round-trip (already covered) still holds.

Manual acceptance (documented in README):
1. Signed in, app running. Space a fresh Doc → within ~1.5 s shows real PDF (or
   Tier 0 then real on second Space).
2. App quit. Space a fresh Doc → extension wakes app headless (no window/Dock),
   second Space shows real PDF.
3. Sign out → previews fall back to Tier 0.

## Files touched

- `App/Info.plist` — add `LSUIElement`.
- `App/DrivePeakApp.swift` — `Window` → `MenuBarExtra`; start `FetchWorker`.
- `App/FetchWorker.swift` — **new**, app-side fetch loop + dir watcher.
- `DrivePeakKit/Sources/FetchQueue.swift` — **new**, marker enqueue/pending/complete.
- `Preview/PreviewViewController.swift` — strip all network code; cache-read +
  enqueue + wake + poll.
- `Tests/FetchQueueTests.swift` — **new**.
- `README.md` — update Tier 1 section: no paid account needed (personal team +
  handoff), document the first-view-Tier-0 behavior.

## UX cost (accepted)

The very first Space on a never-fetched doc may show the Tier 0 card if the
fetch doesn't finish within ~1.5 s. Every subsequent Space on that doc is an
instant real preview. This is the irreducible cost of the extension having no
network — deemed acceptable for best achievable UX.
