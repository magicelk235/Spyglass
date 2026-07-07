#!/usr/bin/env bash
# Build a premium Spyglass.dmg from a Release build, then (optionally) notarize.
#
#   dmg/build-dmg.sh                 # build + package (unsigned dmg, Gatekeeper will warn)
#   NOTARIZE=1 dmg/build-dmg.sh      # also notarize + staple (needs paid Apple ID)
#
# Notarization env (only when NOTARIZE=1):
#   AC_PROFILE   keychain profile from `xcrun notarytool store-credentials`
# ponytail: no separate signing step — xcodebuild already signs the .app.
#
# Requires: dmgbuild (pip install --user dmgbuild). The background is applied by
# a minimal Finder AppleScript (style-dmg.applescript) because on macOS 26 both
# create-dmg (Finder -10000) and dmgbuild's own background (mac_alias overflow)
# fail to render it.
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

# Window + icon geometry (must match the 990x630 art from make-bg.swift;
# icon Y is top-origin for the AppleScript, which uses Finder coordinates).
# WIN_H pads the 630pt art by ~90: `set bounds` sizes the OUTER window, and the
# icon-view content sits below both the title bar and the (non-hideable on
# macOS 26) toolbar strip. 720 = 630 art + 90 chrome, so the whole background
# shows without the top being clipped.
VOL="Spyglass"; WIN_W=990; WIN_H=720; ICON_SIZE=165
APP_X=297; APP_Y=398; APPS_X=683; APPS_Y=398

# Step 1 — base image (app + Applications symlink + volume icon) via dmgbuild.
# dmgbuild's own background handling is skipped: on macOS 26 its legacy alias
# (mac_alias) overflows, so the bg never renders. We add the background below
# by letting Finder itself style a read-write copy.
DMGBUILD=$(command -v dmgbuild || echo "$HOME/Library/Python/3.14/bin/dmgbuild")
BASE=$(mktemp -d)/base.dmg
"$DMGBUILD" -s dmg/dmg-settings.py \
  -D app="$SRC/$APP" \
  -D bg="dmg/assets/dmg-bg.png" \
  -D icon="$SRC/$APP/Contents/Resources/AppIcon.icns" \
  "$VOL" "$BASE"

# Step 2 — mount a read-write copy and drop the background into a .background/
# FOLDER (Finder resolves the icvp alias to a folder, not a bare dotfile).
# @1x + @2x PNGs → Finder auto-picks the retina one; named to match the alias
# target the AppleScript sets.
RW=$(mktemp -d)/rw.dmg
hdiutil convert "$BASE" -format UDRW -o "$RW" >/dev/null
MOUNT=$(hdiutil attach "$RW" -nobrowse -noverify -noautoopen \
  | grep /Volumes/ | tail -1 | sed 's/.*\(\/Volumes\/.*\)/\1/')
cleanup() { hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT
rm -rf "$MOUNT/.background" "$MOUNT"/.background.* 2>/dev/null || true
mkdir -p "$MOUNT/.background"
cp dmg/assets/dmg-bg.png    "$MOUNT/.background/dmg-background.png"
cp dmg/assets/dmg-bg@2x.png "$MOUNT/.background/dmg-background@2x.png"

# Step 3 — a minimal Finder AppleScript sets the window bounds, background, and
# icon positions. Finder writes a LIVE-correct background alias (right cnid), so
# it renders on macOS 26 — unlike dmgbuild's overflowing one. This pared-down
# script avoids the command in create-dmg's template that trips a Finder -10000.
osascript dmg/style-dmg.applescript \
  "$VOL" "$WIN_W" "$WIN_H" "$ICON_SIZE" "$APP" \
  "$APP_X" "$APP_Y" "$APPS_X" "$APPS_Y"

chflags hidden "$MOUNT/.background"   # keep the bg folder out of the window
sync; sleep 1
cleanup; trap - EXIT

# Step 4 — compress to the final read-only DMG.
hdiutil convert "$RW" -format UDZO -o "$OUT" >/dev/null

echo "==> Wrote $OUT"

if [ "${NOTARIZE:-0}" = "1" ]; then
  : "${AC_PROFILE:?set AC_PROFILE to your notarytool keychain profile}"
  echo "==> Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$OUT" --keychain-profile "$AC_PROFILE" --wait
  xcrun stapler staple "$OUT"
  echo "==> Notarized + stapled"
fi
