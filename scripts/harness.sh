#!/bin/bash
# Build PreviewHarness and render files to PNGs (see Tools/PreviewHarness).
#
#   scripts/harness.sh [--dark|--light] [--size WxH] [--wait S] [--code-size PT] [--out DIR] FILE...
#
# Set DD to use a different derived-data folder (parallel worktrees).

set -euo pipefail

ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dark|--light) ARGS+=("$1") ;;
    --size|--wait|--code-size) ARGS+=("$1" "$2"); shift ;;
    --out) ARGS+=("$1" "$(mkdir -p "$2" && cd "$2" && pwd)"); shift ;;
    *) ARGS+=("$(cd "$(dirname "$1")" && pwd)/$(basename "$1")") ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
DD="${DD:-/tmp/spyglass-dd}"
PATH=/opt/homebrew/bin:$PATH xcodegen generate -q
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Spyglass.xcodeproj \
  -scheme PreviewHarness -configuration Debug -derivedDataPath "$DD" build -quiet
"$DD/Build/Products/Debug/PreviewHarness.app/Contents/MacOS/PreviewHarness" "${ARGS[@]+"${ARGS[@]}"}"
