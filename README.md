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
| Text, source code, JSON, extension-less text files | monospaced text view, syntax-colored (see below) |
| Markdown | formatted text: headings, lists, quotes, tables, syntax-colored code blocks |
| Excel (`.xlsx`, `.xlsm`), CSV, TSV | spreadsheet grid with a tab per sheet (see below) |
| Fonts (`.ttf`, `.otf`, `.ttc`, `.woff`) | sample sheet drawn with CoreText; collections get a style menu |
| RTF, HTML, Word (`.docx`, `.doc`), OpenDocument text (up to 4 MB) | `NSAttributedString` |
| Audio & video | `AVPlayerView` |
| Anything else | Quick Look thumbnail, or icon + details |

`QLPreviewView` (the system's full Quick Look view) only draws a generic icon when nested
inside a Quick Look extension, which is why previews are rendered natively. Entries over
1 GB and encrypted entries aren't previewed.

Markdown is parsed by Foundation (`AttributedString(markdown:)`, GitHub flavored) and laid out
with TextKit 1 text blocks and tables. Raw HTML is left out, and images show their description,
since the extension can't load them. The sandbox doesn't let Quick Look extensions open URLs, so
clicking a link copies it instead (hovering shows where it goes). Files over 1 MB are shown as
plain text.

Big compressed tarballs have to be decompressed in full just to list them; if that takes more
than 0.4 s the preview shows "Reading archive…" until the list is ready. Files that iCloud has
evicted from the Mac are a different case: Finder downloads them before it contacts QLZip at all,
so QLZip can't show progress for them. Choosing **Keep Downloaded** on a file or folder in Finder
avoids the wait.

## Spreadsheets

An `.xlsx` file is itself a zip of XML, which QLZip reads with libarchive and `XMLParser`. Cells
show the values Excel last saved (formulas aren't recalculated) using each cell's number format:
dates, times, durations, percentages, currency and thousands separators. Bold text and column
widths are kept; colors, borders, merged cells, charts and images aren't. Hidden sheets are skipped.
CSV and TSV files use the same grid; semicolon-separated files and Excel's UTF-16 "Unicode Text"
export are detected. Each sheet shows at most 20,000 rows and 200 columns, and CSV files are read
up to 16 MB. Legacy `.xls` and Numbers files aren't supported.

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

```sh
./scripts/release.sh              # Developer ID–signed, notarized build/release/QLZip-<version>.dmg
./scripts/release.sh --unsigned   # the same disk image signed for this Mac only, to try the installer
```

The disk image holds `Install QLZip.pkg`. It installs QLZip.app in /Applications, or in
~/Applications with "Install for me only" (no administrator password needed), and registers the
Quick Look extension for the user installing it, so previews work without opening the app first.
Signed releases need "Developer ID Application" and "Developer ID Installer" certificates and a
`notarytool` keychain profile; see the comments at the top of the script for the one-time setup.
The package and the disk image are each notarized and stapled.

## Uninstalling

Drag QLZip.app to the Trash from /Applications or ~/Applications, wherever it was installed.
Finder stops using the extension once macOS notices the app is gone, which can take until Finder
relaunches or you log out. To turn the previews off without uninstalling, switch off
**QLZip Preview** in System Settings › General › Login Items & Extensions › Quick Look.

To remove it right away from Terminal (for an install in /Applications, use that path and `sudo rm`):

```sh
app=~/Applications/QLZip.app
pluginkit -r "$app/Contents/PlugIns/QLZipPreview.appex"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app"
rm -rf "$app"
qlmanage -r && qlmanage -r cache
```

Afterwards, the sandbox folders `~/Library/Containers/com.perryclarke.QLZip` and
`~/Library/Containers/com.perryclarke.QLZip.Preview` can be deleted; they hold only preview temp
files. The installer package also leaves a receipt, which `pkgutil --forget com.perryclarke.QLZip`
removes (with `sudo` if QLZip was installed for all users).

## Layout

- `App/` – host app (Quick Look extensions must ship inside an app); its window explains how to use, enable and uninstall QLZip
- `App/AppIcon.icon` – the app icon, an Icon Composer document (open it in Icon Composer, which ships with Xcode, to edit)
- `Installer/` – installer package post-install script and conclusion page (used by `release.sh`)
- `PreviewExtension/ArchiveReader.swift` – libarchive wrapper: listing and single-entry extraction
- `PreviewExtension/ArchiveTree.swift` – builds the folder tree from flat archive paths
- `PreviewExtension/PreviewViewController.swift` – split view UI, selection, extraction
- `PreviewExtension/Uncompressor.swift` – copies selected items into a folder the user chooses
- `PreviewExtension/EntryPreview.swift` – per-type preview views
- `PreviewExtension/Spreadsheet.swift` – spreadsheet model and CSV/TSV parser
- `PreviewExtension/XLSXReader.swift` – reads `.xlsx` workbooks, including Excel number formats
- `PreviewExtension/SpreadsheetView.swift` – the spreadsheet grid
- `PreviewExtension/FontPreviewView.swift` – font sample sheet
- `PreviewExtension/MarkdownView.swift` – Markdown rendering
- `PreviewExtension/SyntaxHighlighter.swift` – runs highlight.js and converts its output to text ranges
- `PreviewExtension/SyntaxTheme.swift` – colors for each highlight.js scope
- `PreviewExtension/Vendor/highlightjs/` – vendored highlight.js bundle and license
- `CArchive/` – declarations for the libarchive functions used (the SDK ships the library but not its headers)
