# QLZip

A Quick Look extension for macOS that lets you browse archives without extracting them.
Select an archive in Finder and press Space: the left side shows the contents as an expandable
tree, and the right side previews whichever file is selected.

Supported archives: `.zip` (and zip-based files), `.tar`, `.tar.gz`/`.tgz`, `.tar.bz2`, `.tar.xz`,
and bare `.gz`/`.bz2`/`.xz` files. Archives are read with the system's libarchive.

Browse with the mouse: Quick Look keeps keyboard focus in Finder, so ↑/↓ move between files in
Finder rather than within the archive. (They do work in `qlmanage -p`.)

## Uncompressing items

Double-click an item in the list, or Control-click it and choose **Uncompress**, then pick a
destination folder. Folders come out with their contents. ⌘- or ⇧-click to select several items,
then Control-click the selection to uncompress them together. Existing files are never replaced
(a numbered name like "notes 2.txt" is used instead); permissions, dates and symlinks are kept, and
encrypted entries are skipped. Progress and the result appear under the list.

By default Quick Look opens the whole archive in Archive Utility when a preview is double-clicked;
QLZip turns that off inside its own preview so that a double-click affects only the item clicked.

## Previews

Selecting a file extracts just that entry to the extension's sandboxed temp folder and renders it:

| Type | Rendered with |
| --- | --- |
| Images (PNG, JPEG, HEIC, GIF, TIFF, …) | `NSImageView` |
| PDF | `PDFView` |
| Text, source code, CSV, JSON, Markdown, extension-less text files | monospaced text view, syntax-colored (see below) |
| RTF, HTML, Word (`.docx`, `.doc`), OpenDocument text | `NSAttributedString` |
| Audio & video | `AVPlayerView` |
| Anything else | Quick Look thumbnail, or icon + details |

`QLPreviewView` (the system's full Quick Look view) only draws a generic icon when nested
inside a Quick Look extension, which is why previews are rendered natively. Entries over
1 GB and encrypted entries aren't previewed.

## Syntax coloring

Source files up to 512 KB are colored with [highlight.js](https://highlightjs.org) running in
JavaScriptCore: the plain text appears immediately and colors are applied when ready
(about 1 ms per KB). The language comes from the file name or extension, or from the `#!` line for
extension-less scripts; content-based auto-detection is too slow and unreliable to use.
Colors follow Xcode's default light and dark themes (`SyntaxTheme.swift`).

The bundle in `PreviewExtension/Vendor/highlightjs/` is highlight.js's common build (36 languages)
plus the extra grammars listed in `scripts/update-highlightjs.sh` (72 in total). To upgrade or
change languages, edit the script and run `./scripts/update-highlightjs.sh [version]`.
highlight.js is BSD-3-Clause; its license ships inside the extension.

## Building

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The Xcode project is generated from `project.yml`; edit that, not the `.xcodeproj`.

```sh
./scripts/install.sh   # build, install to ~/Applications/QLZip.app, register the extension
```

If Finder still shows the built-in archive preview, enable **QLZip Preview** in
System Settings › General › Login Items & Extensions › Quick Look. Running `qlmanage -p some.zip`
is a quick way to test without Finder.

## Releasing

`./scripts/release.sh` archives with a Developer ID certificate, notarizes, staples and writes
`build/release/QLZip.zip`. See the comments at the top of the script for one-time setup
(Developer ID certificate and a `notarytool` keychain profile).

## Layout

- `App/` – minimal host app (Quick Look extensions must ship inside an app)
- `PreviewExtension/ArchiveReader.swift` – libarchive wrapper: listing and single-entry extraction
- `PreviewExtension/ArchiveTree.swift` – builds the folder tree from flat archive paths
- `PreviewExtension/PreviewViewController.swift` – split view UI, selection, extraction
- `PreviewExtension/Uncompressor.swift` – copies selected items into a folder the user chooses
- `PreviewExtension/EntryPreview.swift` – per-type preview views
- `PreviewExtension/SyntaxHighlighter.swift` – runs highlight.js and converts its output to text ranges
- `PreviewExtension/SyntaxTheme.swift` – colors for each highlight.js scope
- `PreviewExtension/Vendor/highlightjs/` – vendored highlight.js bundle and license
- `CArchive/` – declarations for the libarchive functions used (the SDK ships the library but not its headers)
