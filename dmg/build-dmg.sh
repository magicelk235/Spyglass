#!/usr/bin/env bash
# Build a premium Spyglass.dmg from a Release build, then (optionally) notarize.
#
#   dmg/build-dmg.sh                 # build + package (unsigned dmg, Gatekeeper will warn)
#   NOTARIZE=1 dmg/build-dmg.sh      # also notarize + staple (needs paid Apple ID)
#
# Notarization env (only when NOTARIZE=1):
#   AC_PROFILE   keychain profile from `xcrun notarytool store-credentials`
# ponytail: no separate signing step — xcodebuild already signs the .app.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP="Spyglass.app"
DD=/tmp/spyglass-dd
SRC="$DD/Build/Products/Release"
OUT="dmg/Spyglass.dmg"

echo "==> Building Release"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Spyglass.xcodeproj -scheme Spyglass \
  -configuration Release build -derivedDataPath "$DD" >/dev/null
xattr -cr "$SRC/$APP"

echo "==> Packaging DMG"
rm -f "$OUT"
# Staging dir so the dmg holds ONLY the app (bg/arrow come from --background).
STAGE=$(mktemp -d)
cp -R "$SRC/$APP" "$STAGE/"

# Multi-res tiff so the background is retina-sharp (@1x + @2x from make-bg.swift).
BG=$(mktemp -d)/dmg-bg.tiff
tiffutil -cathidpicheck dmg/assets/dmg-bg.png dmg/assets/dmg-bg@2x.png -out "$BG"

# Icon coords must match the fake-QL-window layout in make-bg.swift
# (icons at x 198/455, y 265; app icon nudged left of symmetric 205 so the
# visible artwork gaps to the window edges match).
create-dmg \
  --volname "Spyglass" \
  --volicon "$SRC/$APP/Contents/Resources/AppIcon.icns" \
  --background "$BG" \
  --window-pos 200 120 \
  --window-size 660 420 \
  --icon-size 110 \
  --text-size 13 \
  --icon "$APP" 198 265 \
  --hide-extension "$APP" \
  --app-drop-link 455 265 \
  --no-internet-enable \
  "$OUT" "$STAGE"

rm -rf "$STAGE"
echo "==> Wrote $OUT"

if [ "${NOTARIZE:-0}" = "1" ]; then
  : "${AC_PROFILE:?set AC_PROFILE to your notarytool keychain profile}"
  echo "==> Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$OUT" --keychain-profile "$AC_PROFILE" --wait
  xcrun stapler staple "$OUT"
  echo "==> Notarized + stapled"
fi
