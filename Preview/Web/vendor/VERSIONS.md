# Vendored web libraries

The web previews (code, structured text, Markdown, diffs, notebooks) load
these from the extension bundle; nothing is fetched at run time. Versions are
pinned. To update one, change its version and SHA-256 in
`scripts/vendor-web.sh`, rerun the script, and update this file. Each folder
keeps the library's LICENSE.

| Library | Version | License | Source |
|---|---|---|---|
| highlight.js (CDN build) | 11.12.0 | BSD-3-Clause | https://registry.npmjs.org/@highlightjs/cdn-assets/-/cdn-assets-11.12.0.tgz |
| markdown-it | 15.0.2 | MIT | https://registry.npmjs.org/markdown-it/-/markdown-it-15.0.2.tgz |
| markdown-it-footnote | 4.0.0 | MIT | https://registry.npmjs.org/markdown-it-footnote/-/markdown-it-footnote-4.0.0.tgz |
| markdown-it-task-lists | 2.1.1 | ISC | https://registry.npmjs.org/markdown-it-task-lists/-/markdown-it-task-lists-2.1.1.tgz |
| markdown-it-github-alerts | 1.0.1 | MIT | https://registry.npmjs.org/markdown-it-github-alerts/-/markdown-it-github-alerts-1.0.1.tgz |
| markdown-it-dollarmath | 0.5.0 | MIT | https://registry.npmjs.org/markdown-it-dollarmath/-/markdown-it-dollarmath-0.5.0.tgz |
| KaTeX | 0.19.0 | MIT | https://registry.npmjs.org/katex/-/katex-0.19.0.tgz |
| Mermaid | 12.1.0 | MIT | https://registry.npmjs.org/mermaid/-/mermaid-12.1.0.tgz |

What is taken from each package:

- **highlight.js**: `highlight.min.js` (the 36 common grammars),
  `languages.min.js` (the other 157 grammars from `languages/*.min.js`,
  concatenated; the page loads it only when a file needs one of them), and
  the `github` / `github-dark` themes.
- **markdown-it**: `dist/browser/markdown-it.umd.min.js`, which bundles its
  own dependencies (entities, linkify-it, mdurl, uc.micro, punycode.js).
- **markdown-it-footnote**, **markdown-it-task-lists**: their minified UMD
  builds. The task-lists build's banner says 2.1.0; its code is the same as
  the 2.1.1 package's `index.js`.
- **markdown-it-github-alerts**: ships as an ES module only, and module
  scripts can't load from `file:` URLs, so `dist/index.mjs` is wrapped as a
  classic script exposing `markdownitGitHubAlerts`. Its CSS is replaced by
  the alert styles in `app.css`.
- **markdown-it-dollarmath**: `dist/index.umd.min.js`, for `$…$` and `$$…$$`.
- **KaTeX**: `katex.min.js`, `katex.min.css` and the `.woff2` fonts. WebKit
  always uses the first (`woff2`) source in each `@font-face`, so the `woff`
  and `ttf` copies are left out.
- **Mermaid**: `dist/mermaid.min.js`. It bundles d3, dagre, cytoscape,
  DOMPurify (Apache-2.0 / MPL-2.0) and others; their notices are kept in the
  "Bundled license information" comment at the end of the file.

Tarball SHA-256 sums are checked by `scripts/vendor-web.sh`.

Size: 7.1 MB in total, of which Mermaid is 5.2 MB, highlight.js 1.0 MB and
KaTeX 0.6 MB. Mermaid and the extra highlight.js grammars load only when a
preview needs them.
