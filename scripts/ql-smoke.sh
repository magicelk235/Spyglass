#!/bin/bash
# Smoke-test the installed Quick Look extension without touching the screen.
#
#   scripts/ql-smoke.sh [--dark|--light] [--show] FILE...
#
# --show keeps each preview visible behind every other window for 8 seconds,
# long enough to capture it with a window screenshot tool.
#
# For each file, prints which Quick Look extension the system launched and the
# path Spyglass took (rendered / plain-text fallback / file card / Drive).
# Other previewers that claim the same types (Looq) would win some files, so
# they are switched off for the run and restored to their exact previous state
# on exit, even if the run fails.

set -euo pipefail

# Resolve file arguments before changing directory.
OPTS=()
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dark|--light) OPTS+=("$1") ;;
    --show) OPTS+=(--show --wait 8) ;;
    *) FILES+=("$(cd "$(dirname "$1")" && pwd)/$(basename "$1")") ;;
  esac
  shift
done

cd "$(dirname "$0")/.."

HOST=/tmp/spyglass-ql-smoke
if [ ! -x "$HOST" ] || [ scripts/ql-smoke.swift -nt "$HOST" ]; then
  swiftc -O scripts/ql-smoke.swift -o "$HOST"
fi

COMPETITORS=(com.parcse.looq.LooqQuickLook)
declare -a RESTORE=()
for id in "${COMPETITORS[@]}"; do
  line=$(pluginkit -m -i "$id" 2>/dev/null || true)
  [ -z "$line" ] && continue
  case "${line:0:1}" in
    +) RESTORE+=("use $id") ;;
    -) RESTORE+=("ignore $id") ;;
    *) RESTORE+=("default $id") ;;
  esac
  pluginkit -e ignore -i "$id"
done
restore() {
  for entry in "${RESTORE[@]+"${RESTORE[@]}"}"; do
    pluginkit -e ${entry% *} -i "${entry#* }"
  done
}
trap restore EXIT
trap 'exit 130' INT TERM HUP

for f in "${FILES[@]}"; do
  start=$(date '+%Y-%m-%d %H:%M:%S')
  "$HOST" "${OPTS[@]+"${OPTS[@]}"}" "$f" >/dev/null
  sleep 1
  logs=$(log show --start "$start" --style compact \
    --predicate 'process == "runningboardd" OR subsystem == "com.spyglass.app.preview"' 2>/dev/null)
  ext=$(echo "$logs" | grep -o 'Launch request for xpcservice<[^(]*' | sed 's/.*xpcservice<//' \
    | grep -i 'quicklook\|preview' | sort -u | tr '\n' ' ' || true)
  path=$(echo "$logs" | grep -oE 'Rendered .*|Plain-text fallback|File-card fallback|Renderer failed.*|Parse failed|Webloc points outside' \
    | sort -u | tr '\n' ';' || true)
  if [ -z "$path" ] && echo "$logs" | grep -q 'Preview invoked'; then path="Drive path"; fi
  printf '%-28s ext=[%s] spyglass=[%s]\n' "$(basename "$f")" "${ext% }" "${path%;}"
done
