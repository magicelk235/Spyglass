# Spyglass

Good Quick Look previews for Google Workspace stub files on macOS.

When you sync Google Drive to your Mac, Docs / Sheets / Slides / Drawings /
Forms / Sites don't download as real files — they land as tiny "stub" files
(`.gdoc`, `.gsheet`, `.gslides`, `.gdraw`, `.gform`, `.gsite`) that hold only a
document ID. Pressing Space on one gives you a useless blob of JSON. Spyglass
replaces that with a real preview.

## What it does

Spyglass is a Quick Look Preview Extension plus a small host app. It previews in
two tiers:

- **Tier 0 — offline card (always works, no sign-in).** A branded card per type:
  document icon, title (from the filename), owner email, and a click-to-open
  link to the file on Google. Works instantly, offline, for all six types.
- **Tier 1 — rendered preview (optional, needs Google sign-in).** For the
  exportable types (Docs, Sheets, Slides, Drawings) the extension fetches a PDF
  export from Google Drive and renders the actual document. Forms and Sites
  aren't exportable, so they always show the Tier 0 card.

Tier 1 degrades gracefully: no sign-in, a network error, a slow response
(> ~2 s), or a document that won't render all fall back to the Tier 0 card. The
preview is never blank and never hangs.

## Requirements

- macOS 14 or later.
- Xcode (full install, not just Command Line Tools).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) —
  the `.xcodeproj` is generated from `project.yml`, not committed.
- **Tier 1 only:** a Google Cloud OAuth client (free) and a free Apple ID added
  to Xcode (personal team) to sign the shared App Group/Keychain entitlements.
  See below. Tier 0 needs neither.

## Build & install (Tier 0)

```sh
# Copy the OAuth plist template so the build can find the resource reference.
# Tier 0 works fine with the placeholder — no real client id needed.
cp GoogleOAuth.plist.example GoogleOAuth.plist

xcodegen generate

# Build to a clean location (avoids xattr/codesign issues from iCloud/Desktop):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Spyglass.xcodeproj -scheme Spyglass \
  -configuration Release build -derivedDataPath /tmp/spyglass-dd

# Install:
rm -rf /Applications/Spyglass.app
xattr -cr /tmp/spyglass-dd/Build/Products/Release/Spyglass.app
cp -R /tmp/spyglass-dd/Build/Products/Release/Spyglass.app /Applications/
xattr -cr /Applications/Spyglass.app

# Register the extension with Quick Look and Launch Services:
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f /Applications/Spyglass.app
```

Then **open Spyglass.app once** so the system registers the embedded preview
extension. After that, press **Space** on a `.gdoc` (or any of the six types) in
Finder — you should see the Spyglass card.

Not working? Open the app once more to re-register, or run
`qlmanage -r && qlmanage -r cache` to reset Quick Look.

## Running the tests

The pure logic (parsing, PKCE, token store, Drive client, cache) is unit-tested
and runs without any credentials or signing:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Spyglass.xcodeproj -scheme SpyglassKit \
  -destination 'platform=macOS' test -derivedDataPath /tmp/spyglass-dd
```

## Enabling Tier 1 (Google-authenticated previews)

Tier 1 is optional. It needs two things Tier 0 doesn't.

### 1. A Google OAuth client (free)

1. In the [Google Cloud Console](https://console.cloud.google.com/), create a
   project and **enable the Google Drive API** (APIs & Services → Library).
2. Configure the OAuth consent screen: **External**, leave it in **Testing**
   (no verification needed), add your Google account as a **test user**. No logo
   required. Add the scope
   `https://www.googleapis.com/auth/drive.readonly`.
3. Create an **OAuth client ID** of type **Desktop app**. Download the JSON.
4. Create `GoogleOAuth.plist` at the repo root (it's gitignored) containing the
   client ID from that JSON:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>CLIENT_ID</key>
       <string>YOUR-CLIENT-ID.apps.googleusercontent.com</string>
   </dict>
   </plist>
   ```

   No client secret is stored — Spyglass uses the PKCE flow, which doesn't need
   one at runtime.

### 2. Signing with a free personal team

The app and the extension share the OAuth token (Keychain access group) and the
rendered-PDF cache (App Group). Both entitlements need a real Team ID — Xcode's
free personal team works (apps re-sign after 7 days).

1. Xcode → Settings → Accounts → add your Apple ID (creates a personal team).
2. Put the team ID in `Secrets.xcconfig` (gitignored):
   `DEVELOPMENT_TEAM = YOURTEAMID`
3. `xcodegen generate`, open the project in Xcode once and let it provision
   both targets (Signing & Capabilities), then build/install as above.
4. Click the menu-bar eye icon and click **Sign in with Google**. A browser tab
   opens for consent; approve it and the signed-in email shows in the popover.

Now Space on a Doc / Sheet / Slides / Drawing renders the real document.

### How Tier 1 fetches work

The Quick Look extension's sandbox is write-locked and cannot reach the network
(DNS resolution is denied), so it never fetches anything — it only reads the
shared cache. The app is a menu-bar agent (no Dock icon) that discovers stub
files on disk (a Spotlight live query plus a sweep of the Google Drive mounts
under `~/Library/CloudStorage`), pre-fetches each document's PDF export, and
keeps the cache warm. New or edited documents are re-fetched automatically when
the scanner re-encounters them (the worker skips docs whose `modifiedTime` is
unchanged). The app registers itself as a login item so previews stay warm.

## How it works

- `WorkspaceType` is the single source of truth: one enum drives file extensions,
  the custom UTIs, Google URL paths, export capability, icons, and brand colors.
- The app declares custom UTIs (`com.spyglass.*`) via `UTExportedTypeDeclarations`
  so macOS routes these otherwise-anonymous stub files to the extension.
- The extension is a modern **view-based** `QLPreviewingController`
  (`preparePreviewOfFile(at:)`), sandboxed — required for a preview extension
  to activate. The host app is deliberately NOT sandboxed: the extension's
  sandbox is write-locked, so the app must scan the disk for stubs and do all
  fetching itself.
- Tier 1's token lives in the shared Keychain; the exported PDF is cached in the
  App Group container, keyed by the doc's `modifiedTime` so edits invalidate it.

## Known limitations

- A document synced *after* the last scan pass shows the Tier 0 card until the
  scanner re-encounters it (Spotlight updates usually land within seconds).
- The extension can't validate cache freshness itself (no network); a just-
  edited doc may render one revision stale until the worker revalidates it.
- Forms and Sites can't be exported by the Drive API, so they always show the
  Tier 0 card.
- The sign-in flow has no wall-clock timeout for an abandoned browser tab yet;
  a malformed redirect resolves to an error, but simply never completing sign-in
  leaves the attempt pending.

## Project layout

```
App/                 Host app (status UI, Google sign-in)
Preview/             Quick Look preview extension
SpyglassKit/        Shared, unit-tested logic (model, parsing, auth, Drive, cache)
Tests/               Unit tests for SpyglassKit
docs/                Plan and design/spec documents
project.yml          XcodeGen project spec (source of the .xcodeproj)
```

## License

Licensed under the [PolyForm Shield License 1.0.0](LICENSE). Copyright (c) 2026
Yehonatan Cohen (magicelk235). You may freely use, modify, and share it — but
you may not use it to build a product that competes with Spyglass.
