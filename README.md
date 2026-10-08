# Spyglass

Quick Look for the files Finder can't show, including Google Drive documents.

Select a file in Finder and press Space. Instead of a big icon, Spyglass shows you the file: rendered Markdown, highlighted code, a notebook with its plots, the inside of a zip, the signing details of an app. For Google Docs, Sheets and Slides synced to your Mac, it shows the real document.

## What it previews

- Markdown: GitHub-style rendering with tables, task lists, footnotes, alerts, math and Mermaid diagrams. Images next to the file show up too.
- Code: about 190 languages with syntax highlighting and line numbers, including scripts without an extension.
- JSON, XML, plist, YAML, TOML: minified JSON is reformatted with its key order kept, binary plists show as XML, and signed configuration profiles are unwrapped.
- Jupyter notebooks: Markdown cells, highlighted code, plots, tables, LaTeX and colored error tracebacks.
- Diffs and patches: colored hunks with one tab per file.
- Tables: TSV and JSON Lines as a sortable table.
- SQLite databases: every table and view, with column types.
- Archives: zip, tar, gzip, bzip2, xz and ISO images, browsed without extracting. Java, Android, Python, NuGet, VS Code and Firefox packages also show their name and version.
- Apps and installers: `.app`, `.ipa`, `.pkg`, `.dmg` and frameworks, with version, bundle ID, signing and entitlements.
- Binaries: executables, dylibs, object files and static libraries, with their architectures, minimum macOS and linked libraries.
- Folders: a Finder-style list with icons, item count and total size.
- Torrents: files, trackers and the info hash.
- Google Drive: `.gdoc`, `.gsheet`, `.gslides`, `.gdraw`, `.gform` and `.gsite` files, plus the `.webloc` bookmarks some Drive clients write.

An open preview updates when you save the file. In Settings you can pick a light or dark theme, set the code font size, or switch off any format.

macOS keeps `.txt` and `.csv` for its own preview, so Spyglass leaves those alone. If you have another Quick Look app installed and it wins for some file type, choose which one handles it in System Settings > General > Login Items & Extensions > Quick Look.

## Pricing

Every format preview is free for 7 days, starting the first time you open the app. You don't need a card.

| Plan | Price | Includes |
|---|---|---|
| Spyglass Pro | $12 once | Every format preview, for good |
| Spyglass Pro + Drive | $4 a month or $36 a year | Everything in Pro, plus rendered Google Drive documents and their Finder thumbnails |

After the trial, files without a plan still open in Quick Look as plain text or a short file summary. The Google Drive info card (title, owner and a link to open the document) is always free.

If you bought Spyglass 1.0, your key still works and now includes Pro + Drive at no charge.

Buy at [magicelklabs.com/spyglass](https://magicelklabs.com/spyglass), then paste the license key from your Gumroad receipt into the Spyglass menu-bar window.

## Install

1. [Download Spyglass](https://github.com/magicelk235/spyglass/releases/latest/download/Spyglass.dmg), drag it to Applications and open it once. It runs from the menu bar.
2. Select a file in Finder and press Space.

Or with Homebrew:

```sh
brew install --cask magicelk235/magicelklabs/spyglass
```

Spyglass needs macOS 14 or later. It updates itself in the background; you can turn that off in Settings.

For Google Drive previews on the Drive plan, open the menu-bar window, sign in with Google, and give Spyglass Full Disk Access when it asks, so it can read your Drive folder.

## Privacy

Format previews happen entirely on your Mac and never touch the network. Spyglass reads the file you're previewing and, when needed, files next to it (images in a Markdown file, sizes inside a folder). It doesn't write anything.

Only the Drive plan talks to the network: Spyglass asks Google for your own documents with read-only access and keeps the sign-in token in your Keychain. There is no Spyglass server and no analytics.

## License

Licensed under the [PolyForm Shield License 1.0.0](LICENSE). Copyright (c) 2026 Yehonatan Cohen (magicelk235). You may use, modify, and share it, but you may not use it to build a product that competes with Spyglass.
