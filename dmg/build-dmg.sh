#!/usr/bin/env bash
# Build a premium DrivePeak.dmg from a Release build, then (optionally) notarize.
#
#   dmg/build-dmg.sh                 # build + package (unsigned dmg, Gatekeeper will warn)
#   NOTARIZE=1 dmg/build-dmg.sh      # also notarize + staple (needs paid Apple ID)
#
# Notarization env (only when NOTARIZE=1):
#   AC_PROFILE   keychain profile from `xcrun notarytool store-credentials`
# ponytail: no separate signing step — xcodebuild already signs the .app.
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

APP="DrivePeak.app"
DD=/tmp/drivepeak-dd
SRC="$DD/Build/Products/Release"
OUT="dmg/DrivePeak.dmg"

echo "==> Building Release"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project DrivePeak.xcodeproj -scheme DrivePeak \
  -configuration Release build -derivedDataPath "$DD" >/dev/null
xattr -cr "$SRC/$APP"

echo "==> Packaging DMG"
rm -f "$OUT"
# Staging dir so the dmg holds ONLY the app (bg/arrow come from --background).
STAGE=$(mktemp -d)
cp -R "$SRC/$APP" "$STAGE/"

create-dmg \
  --volname "DrivePeak" \
  --background "dmg/assets/dmg-bg.png" \
  --window-pos 200 120 \
  --window-size 660 420 \
  --icon-size 120 \
  --text-size 13 \
  --icon "$APP" 150 210 \
  --hide-extension "$APP" \
  --app-drop-link 510 210 \
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
