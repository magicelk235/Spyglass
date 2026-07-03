#!/bin/bash
# Build, sign, notarize, and package Spyglass as a distributable DMG.
#
# Prereqrequisites (fill in once your Apple Developer enrollment lands):
#   - A "Developer ID Application" certificate in your login keychain.
#   - A notarytool keychain profile:  xcrun notarytool store-credentials
#   Then set the three vars below.
#
# Why this script exists: the release chain is 6 ordered steps and skipping any
# one (especially notarize/staple) makes Gatekeeper block the app on other Macs.
# It also builds into /tmp — building inside an iCloud-synced folder (~/Desktop)
# stamps xattrs that make codesign fail with "resource fork ... not allowed".

set -euo pipefail

# --- fill these in -----------------------------------------------------------
SIGN_ID="Developer ID Application: YOUR NAME (TEAMID)"   # codesign identity
NOTARY_PROFILE="spyglass-notary"                         # notarytool profile name
# -----------------------------------------------------------------------------

PROJECT="Spyglass.xcodeproj"
SCHEME="Spyglass"
DD="/tmp/spyglass-release-dd"          # derived data OUTSIDE the synced tree
APP="$DD/Build/Products/Release/Spyglass.app"
DMG="Spyglass.dmg"

echo "==> Regenerating project"
xcodegen generate

echo "==> Building Release"
rm -rf "$DD"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  CODE_SIGN_STYLE=Manual \
  build

echo "==> Signing (deep, hardened runtime)"
codesign --force --deep --options runtime --timestamp \
  --sign "$SIGN_ID" "$APP"

echo "==> Packaging DMG"
rm -f "$DMG"
hdiutil create -volname "Spyglass" -srcfolder "$APP" -ov -format UDZO "$DMG"

echo "==> Signing DMG"
codesign --force --sign "$SIGN_ID" "$DMG"

echo "==> Notarizing (uploads to Apple, waits for result)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling ticket onto the DMG"
xcrun stapler staple "$DMG"

echo "==> Done: $DMG is signed, notarized, and stapled."
