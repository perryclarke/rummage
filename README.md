# QLZip

A Quick Look extension for macOS that lets you browse archives without extracting them.
Select an archive in Finder and press Space: the left side shows the contents as an expandable
tree, and the right side previews whichever file is selected.

Supported archives: `.zip` (and zip-based files), `.tar`, `.tar.gz`/`.tgz`, `.tar.bz2`, `.tar.xz`,
and bare `.gz`/`.bz2`/`.xz` files. Archives are read with the system's libarchive.

## Previews

Selecting a file extracts just that entry to the extension's sandboxed temp folder and renders it:

| Type | Rendered with |
| --- | --- |
| Images (PNG, JPEG, HEIC, GIF, TIFF, …) | `NSImageView` |
| PDF | `PDFView` |
| Text, source code, CSV, JSON, Markdown, extension-less text files | monospaced text view |
| RTF, HTML, Word (`.docx`, `.doc`), OpenDocument text | `NSAttributedString` |
| Audio & video | `AVPlayerView` |
| Anything else | Quick Look thumbnail, or icon + details |

`QLPreviewView` (the system's full Quick Look view) only draws a generic icon when nested
inside a Quick Look extension, which is why previews are rendered natively. Entries over
1 GB and encrypted entries aren't previewed.

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
- `PreviewExtension/EntryPreview.swift` – per-type preview views
- `CArchive/` – declarations for the libarchive functions used (the SDK ships the library but not its headers)
