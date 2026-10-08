#!/bin/bash
# Rebuilds Preview/Web/vendor from pinned npm tarballs, checking each one
# against its SHA-256. Bump a version here and in Preview/Web/vendor/VERSIONS.md
# together, then rerun.
#
#   scripts/vendor-web.sh

set -euo pipefail
cd "$(dirname "$0")/.."

OUT=Preview/Web/vendor
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# fetch NAME VERSION SHA256 -> unpacks into $WORK/<basename of NAME>/package
fetch() {
  local name=$1 version=$2 sha=$3
  local base=${name##*/}
  curl -sSfL -o "$WORK/$base.tgz" "https://registry.npmjs.org/$name/-/$base-$version.tgz"
  echo "$sha  $WORK/$base.tgz" | shasum -a 256 -c --quiet
  mkdir -p "$WORK/$base"
  tar -xzf "$WORK/$base.tgz" -C "$WORK/$base"
}

fetch @highlightjs/cdn-assets 11.12.0 b8a006d30f45afe783072569f3d69c5b60c0e7b9ca28cd474e12f2584e2a3bd9
fetch markdown-it 15.0.2 3237f5ecac432f99453e6d8d345b6e4764a22f1781c96e02dc9e89777b9c23c1
fetch markdown-it-footnote 4.0.0 319e1c784b74a73b473e76a1bb725d3770c5a2e409dfd8c30c504f3a2712e272
fetch markdown-it-task-lists 2.1.1 8e9ed515296f11d716a6460c0bd35ffa163003a373a6d8f65d53ea9f8aec667e
fetch markdown-it-github-alerts 1.0.1 14e3314c7092c981224ddba616807977bb8f8fee7b5afd7f06af4f443a595711
fetch markdown-it-dollarmath 0.5.0 226d138dc84291afcd686956f364c2dc69669630f30c0bb92849cd607b3587a0
fetch katex 0.19.0 d8e49f2fea6eeed7cdae2cf4fd48e2f1d348758aa9e5740715e4533c2c96d1ee
fetch mermaid 12.1.0 3e516f33246e1a6a5bc5ebcabd35434669b487c3b3791f9b0466aa2c254d004a

for dir in highlight markdown-it markdown-it-footnote markdown-it-task-lists \
           markdown-it-github-alerts markdown-it-dollarmath katex mermaid; do
  rm -rf "${OUT:?}/$dir"
  mkdir -p "$OUT/$dir"
done

# highlight.js: the CDN build carries the common languages; every other
# language goes into one extra file that the shell loads only when needed.
H=$WORK/cdn-assets/package
cp "$H/LICENSE" "$H/highlight.min.js" "$H/styles/github.min.css" "$H/styles/github-dark.min.css" "$OUT/highlight/"
common=$(grep -o 'grmr_[a-z0-9_]*:' "$H/highlight.min.js" | sed -e 's/^grmr_//' -e 's/:$//' -e 's/_/-/')
for file in "$H"/languages/*.min.js; do
  id=$(basename "$file" .min.js)
  if ! grep -qx "$id" <<<"$common"; then
    cat "$file"
    echo
  fi
done > "$OUT/highlight/languages.min.js"

cp "$WORK/markdown-it/package/LICENSE" "$OUT/markdown-it/"
cp "$WORK/markdown-it/package/dist/browser/markdown-it.umd.min.js" "$OUT/markdown-it/markdown-it.min.js"

cp "$WORK/markdown-it-footnote/package/LICENSE" \
   "$WORK/markdown-it-footnote/package/dist/markdown-it-footnote.min.js" "$OUT/markdown-it-footnote/"

cp "$WORK/markdown-it-task-lists/package/LICENSE" \
   "$WORK/markdown-it-task-lists/package/dist/markdown-it-task-lists.min.js" "$OUT/markdown-it-task-lists/"

cp "$WORK/markdown-it-dollarmath/package/LICENSE" "$OUT/markdown-it-dollarmath/"
cp "$WORK/markdown-it-dollarmath/package/dist/index.umd.min.js" "$OUT/markdown-it-dollarmath/markdown-it-dollarmath.min.js"

# The alerts plugin ships only as an ES module, and module scripts can't load
# from file: URLs. Wrap it as a classic script exposing one global.
A=$WORK/markdown-it-github-alerts/package
cp "$A/LICENSE" "$OUT/markdown-it-github-alerts/"
{
  echo "/*! markdown-it-github-alerts 1.0.1 (MIT), wrapped as a classic script by scripts/vendor-web.sh */"
  echo "(function () {"
  grep -v '^export ' "$A/dist/index.mjs"
  echo "globalThis.markdownitGitHubAlerts = MarkdownItGitHubAlerts;"
  echo "})();"
} > "$OUT/markdown-it-github-alerts/markdown-it-github-alerts.js"

# KaTeX: WebKit always takes the first (woff2) source in each @font-face, so
# the woff and ttf copies are left out.
K=$WORK/katex/package
cp "$K/LICENSE" "$K/dist/katex.min.js" "$K/dist/katex.min.css" "$OUT/katex/"
mkdir -p "$OUT/katex/fonts"
cp "$K"/dist/fonts/*.woff2 "$OUT/katex/fonts/"

cp "$WORK/mermaid/package/LICENSE" "$WORK/mermaid/package/dist/mermaid.min.js" "$OUT/mermaid/"

du -sh "$OUT"
