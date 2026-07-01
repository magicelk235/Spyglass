# DrivePeak

Good Quick Look previews for Google Workspace stub files on macOS.

When you sync Google Drive to your Mac, Docs / Sheets / Slides / Drawings /
Forms / Sites don't download as real files — they land as tiny "stub" files
(`.gdoc`, `.gsheet`, `.gslides`, `.gdraw`, `.gform`, `.gsite`) that hold only a
document ID. Pressing Space on one gives you a useless blob of JSON. DrivePeak
replaces that with a real preview.

## What it does

DrivePeak is a Quick Look Preview Extension plus a small host app. It previews in
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
- **Tier 1 only:** a Google Cloud OAuth client and (for the shared token between
  app and extension) a paid Apple Developer account. See below. Tier 0 needs
  neither.

## Build & install (Tier 0)

```sh
xcodegen generate

# Build to a clean location (avoids xattr/codesign issues from iCloud/Desktop):
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeak \
  -configuration Release build -derivedDataPath /tmp/drivepeak-dd

# Install:
rm -rf /Applications/DrivePeak.app
xattr -cr /tmp/drivepeak-dd/Build/Products/Release/DrivePeak.app
cp -R /tmp/drivepeak-dd/Build/Products/Release/DrivePeak.app /Applications/
xattr -cr /Applications/DrivePeak.app

# Register the extension with Quick Look and Launch Services:
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f /Applications/DrivePeak.app
```

Then **open DrivePeak.app once** so the system registers the embedded preview
extension. After that, press **Space** on a `.gdoc` (or any of the six types) in
Finder — you should see the DrivePeak card.

Not working? Open the app once more to re-register, or run
`qlmanage -r && qlmanage -r cache` to reset Quick Look.

## Running the tests

The pure logic (parsing, PKCE, token store, Drive client, cache) is unit-tested
and runs without any credentials or signing:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeakKit \
  -destination 'platform=macOS' test -derivedDataPath /tmp/drivepeak-dd
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

   No client secret is stored — DrivePeak uses the PKCE flow, which doesn't need
   one at runtime.

### 2. A paid Apple Developer account (for signing)

The app and the extension are separate sandboxed processes. They share the OAuth
token through a **shared Keychain access group** and the rendered-PDF cache
through an **App Group** — both require entitlements that macOS will only sign
with a real Team ID (ad-hoc signing is rejected). So Tier 1 needs a paid Apple
Developer account.

Once you have your Team ID:

1. Put it in `Secrets.xcconfig` (gitignored) at the repo root:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   ```

2. In `project.yml`, change `CODE_SIGN_IDENTITY` from `"-"` to
   `"Apple Development"`, then `xcodegen generate` and rebuild/reinstall.

3. Open the app and click **Sign in with Google**. A browser tab opens for
   consent; approve it, and the tab reports success. The signed-in email shows in
   the app.

Now Space on a Doc / Sheet / Slides / Drawing renders the real document. The
first open of a file waits on the network (falling back to the card if it's
slow); repeat opens are instant from the cache.

## How it works

- `WorkspaceType` is the single source of truth: one enum drives file extensions,
  the custom UTIs, Google URL paths, export capability, icons, and brand colors.
- The app declares custom UTIs (`com.drivepeak.*`) via `UTExportedTypeDeclarations`
  so macOS routes these otherwise-anonymous stub files to the extension.
- The extension is a modern **view-based** `QLPreviewingController`
  (`preparePreviewOfFile(at:)`), sandboxed — the sandbox is required for a
  preview extension to activate at all.
- Tier 1's token lives in the shared Keychain; the exported PDF is cached in the
  App Group container, keyed by the doc's `modifiedTime` so edits invalidate it.

## Known limitations

- Tier 1 requires the paid Apple Developer account (above).
- Forms and Sites can't be exported by the Drive API, so they always show the
  Tier 0 card.
- The sign-in flow has no wall-clock timeout for an abandoned browser tab yet;
  a malformed redirect resolves to an error, but simply never completing sign-in
  leaves the attempt pending.

## Project layout

```
App/                 Host app (status UI, Google sign-in)
Preview/             Quick Look preview extension
DrivePeakKit/        Shared, unit-tested logic (model, parsing, auth, Drive, cache)
Tests/               Unit tests for DrivePeakKit
docs/                Plan and design/spec documents
project.yml          XcodeGen project spec (source of the .xcodeproj)
```
