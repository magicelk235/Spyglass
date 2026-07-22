# Spyglass

Real Quick Look previews for Google Workspace files on macOS.

When you sync Google Drive to your Mac, your Docs, Sheets, Slides, Drawings,
Forms, and Sites don't come down as real files. They land as tiny stub files
(`.gdoc`, `.gsheet`, `.gslides`, `.gdraw`, `.gform`, `.gsite`) that hold nothing
but a document ID. Press Space on one in Finder and Quick Look shows you a
useless blob of JSON. Spyglass fixes that and shows you the actual document
instead.

## Previews

Spyglass previews your files two ways.

The offline card works instantly for all six types, with no sign-in. Press Space
and you get a clean card with the document's icon, its title, the owner, and a
link that opens the file on Google. It works with no network and no account.

The rendered preview is optional and needs a one-time Google sign-in. For Docs,
Sheets, Slides, and Drawings, Spyglass pulls the real document from Google Drive
and shows it the way it actually looks. If you're offline, not signed in, or the
document can't be rendered, Spyglass falls back to the offline card. The preview
is never blank and never hangs. Forms and Sites can't be exported by Google, so
they always show the card.

## Requirements

- macOS 14 or later.
- A Google account, if you want the rendered previews. The offline card needs no
  account at all.

## Getting started

1. Install Spyglass and open it once. It runs quietly from the menu bar.
2. Press Space on any Google stub file (`.gdoc`, `.gsheet`, `.gslides`,
   `.gdraw`, `.gform`, `.gsite`) in Finder. You'll see the Spyglass card right
   away.
3. To turn on rendered previews, click the eye icon in the menu bar and sign in
   with Google. From then on, Docs, Sheets, Slides, and Drawings show the real
   document when you preview them.

Spyglass keeps your rendered previews ready in the background so they come up
fast. Nothing leaves your Mac except the request to Google Drive for your own
documents.

## Privacy

Spyglass talks only to Google, and only to fetch your own files. It reads your
Drive with read-only access, stores its sign-in token in your Mac's Keychain,
and keeps rendered previews in a local cache on your machine. There is no
Spyglass server and no analytics.

## License

Licensed under the [PolyForm Shield License 1.0.0](LICENSE). Copyright (c) 2026
Yehonatan Cohen (magicelk235). You may use, modify, and share it, but you may
not use it to build a product that competes with Spyglass.
