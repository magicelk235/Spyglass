#!/bin/bash
# Debug build + relaunch for local development. For distribution use release.sh.
#
# Builds into /tmp — building inside an iCloud-synced folder (~/Desktop) stamps
# xattrs that make codesign fail with "resource fork ... not allowed".

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="Spyglass.xcodeproj"
SCHEME="Spyglass"
DD="/tmp/spyglass-dd"
APP="$DD/Build/Products/Debug/Spyglass.app"

if [ ! -d "$PROJECT" ]; then
  echo "==> Generating project"
  xcodegen generate
fi

echo "==> Building Debug"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -derivedDataPath "$DD" build

echo "==> Installing to /Applications"
osascript -e 'quit app "Spyglass"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Spyglass.app
cp -R "$APP" /Applications/
open /Applications/Spyglass.app
echo "==> Done: /Applications/Spyglass.app"
