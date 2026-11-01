import AVKit
import Cocoa
import CoreImage
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Builds a view that previews an extracted file.
///
/// QLPreviewView only draws a generic icon when hosted inside a Quick Look extension, so common
/// types are rendered natively and everything else falls back to a Quick Look thumbnail.
@MainActor
enum EntryPreview {
    /// Text files larger than this are truncated for display.
    private static let maxTextBytes = 2 << 20
    /// Rich documents (HTML, RTF, Word, OpenDocument) larger than this get a thumbnail instead:
    /// the importers are synchronous and slow, and HTML's has to run on the main thread.
    private static let maxRichDocumentBytes = 4 << 20

    static func makeView(for url: URL, scale: CGFloat) async -> NSView? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data

        if type.conforms(to: .pdf) {
            return pdfView(url)
        }
        if type.conforms(to: .image), let view = await imageView(url) {
            return view
        }
        if type.conforms(to: .font) || FontPreviewView.fileExtensions.contains(url.pathExtension.lowercased()),
           let view = FontPreviewView(url: url) {
            return view
        }
        // Before plain text, since CSV and Markdown are text too.
        if Spreadsheet.canRead(url),
           let spreadsheet = try? await Task.detached(priority: .userInitiated, operation: { try Spreadsheet.read(url) }).value {
            return SpreadsheetView(spreadsheet)
        }
        if MarkdownView.fileExtensions.contains(url.pathExtension.lowercased()), let view = MarkdownView(url: url) {
            return view
        }
        // Some code extensions collide with media types (.ts is also MPEG transport stream video).
        if type.conforms(to: .audiovisualContent), !looksLikeText(url) {
            return playerView(url)
        }
        // HTML that comes out blank is usually a page built by JavaScript, which the importer doesn't
        // run (e.g. the "Your archive.html" in a Twitter archive); its source, below, says more.
        if let documentType = attributedDocumentType(for: type), fileSize(url) <= maxRichDocumentBytes,
           let text = await richText(url, documentType: documentType),
           documentType != .html || !text.string.allSatisfy(\.isWhitespace) {
            return textView(text, monospaced: false)
        }
        if type.conforms(to: .text) || looksLikeText(url) {
            return plainTextView(url)
        }
        return await thumbnailView(url, scale: scale)
    }

    /// Video and audio players, which must leave Quick Look's window before it closes.
    static func isPlayer(_ view: NSView) -> Bool {
        view is AVPlayerView
    }

    /// Calls `action` when a preview that's only a picture of the file (an image, or the Quick Look
    /// thumbnail standing in for one) is double-clicked. Other previews keep their own double-click
    /// (selecting a word, say).
    static func onDoubleClick(in view: NSView, perform action: @escaping () -> Void) {
        (view as? PreviewImageView)?.onDoubleClick = action
        for subview in view.subviews { onDoubleClick(in: subview, perform: action) }
    }

    /// Releases resources held by a preview view (e.g. stops playback or thumbnail extraction).
    static func tearDown(_ view: NSView) {
        (view as? FolderView)?.cancel()
        if let player = view as? AVPlayerView {
            player.player?.pause()
            player.player = nil
        }
    }

    // MARK: - Renderers

    private static func pdfView(_ url: URL) -> NSView? {
        guard let document = PDFDocument(url: url) else { return nil }
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.backgroundColor = .clear
        return view
    }

    private static func imageView(_ url: URL) async -> NSView? {
        let maxPixelSize = screenPixelSize
        let decoded = await Task.detached(priority: .userInitiated) {
            CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                .flatMap { decodeForScreen($0, maxPixelSize: maxPixelSize) }
        }.value
        if let decoded { return imageView(NSImage(cgImage: decoded.image, size: decoded.size)) }
        // Animated images, which NSImageView animates, and types ImageIO can't read (e.g. SVG).
        guard let image = NSImage(contentsOf: url) else { return nil }
        return imageView(image)
    }

    /// The JPEG preview a camera RAW file embeds, shown with the RAW's orientation (if given).
    static func imageView(jpeg: Data, orientation: Int?) async -> NSView? {
        let maxPixelSize = screenPixelSize
        let decoded = await Task.detached(priority: .userInitiated) {
            CGImageSourceCreateWithData(jpeg as CFData, nil)
                .flatMap { decodeForScreen($0, maxPixelSize: maxPixelSize, orientation: orientation) }
        }.value
        return decoded.map { imageView(NSImage(cgImage: $0.image, size: $0.size)) }
    }

    private static func imageView(_ image: NSImage) -> NSView {
        let view = PreviewImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        view.isEditable = false
        return padded(view, inset: 12)
    }

    /// The longest side of the largest screen, in pixels: the most an image is ever shown at.
    static var screenPixelSize: CGFloat {
        NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 4096
    }

    /// A still image decoded (off the main thread) to at most `maxPixelSize`, and its size in points
    /// as NSImage would give it. Decoding it ahead matters: NSImage decodes when first drawn, on the
    /// main thread, and a camera RAW file takes seconds to decode in full. With `orientation`, the
    /// image is turned that way (a RAW file's, for the preview it embeds), else by its own.
    /// Nil for animated images and types ImageIO can't read.
    nonisolated private static func decodeForScreen(_ source: CGImageSource, maxPixelSize: CGFloat,
                                                    orientation: Int? = nil) -> (image: CGImage, size: CGSize)? {
        guard CGImageSourceGetCount(source) == 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: orientation == nil,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if let orientation, orientation != 1, let turn = CGImagePropertyOrientation(rawValue: UInt32(orientation)) {
            let turned = CIImage(cgImage: image).oriented(turn)
            guard let rendered = CIContext().createCGImage(turned, from: turned.extent) else { return nil }
            image = rendered
        }
        let points = source.longestSideInPoints ?? CGFloat(max(image.width, image.height))
        let factor = points / CGFloat(max(image.width, image.height, 1))
        return (image, CGSize(width: CGFloat(image.width) * factor, height: CGFloat(image.height) * factor))
    }

    private static func playerView(_ url: URL) -> NSView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        return view
    }

    private static func plainTextView(_ url: URL) -> NSView? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxTextBytes + 1)) ?? Data()
        let content = String(decoding: data.prefix(maxTextBytes), as: UTF8.self)
        let truncated = data.count > maxTextBytes
        let scroll = textView(NSAttributedString(string: truncated ? content + "\n\n… (truncated)" : content), monospaced: true)

        // Show plain text right away and color it once highlighting finishes in the background.
        if data.count <= SyntaxHighlighter.maxBytes, let textView = scroll.documentView as? NSTextView {
            let fileName = url.lastPathComponent
            Task { [weak textView] in
                guard let spans = await SyntaxHighlighter.shared.highlight(content, fileName: fileName),
                      let textView, let storage = textView.textStorage, let font = textView.font else { return }
                SyntaxTheme.apply(spans, to: storage, font: font)
            }
        }
        return scroll
    }

    /// The document at `url` as attributed text. The HTML importer goes through WebKit and must
    /// run on the main thread; the others are read in the background.
    private static func richText(_ url: URL, documentType: NSAttributedString.DocumentType) async -> NSAttributedString? {
        if documentType == .html {
            return try? NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil)
        }
        let rawType = documentType.rawValue
        return await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<NSAttributedString?> in
            let type = NSAttributedString.DocumentType(rawValue: rawType)
            return UncheckedSendable(try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil))
        }.value.value
    }

    /// Carries an immutable Foundation object (which isn't marked Sendable) out of a background task.
    private struct UncheckedSendable<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private static func textView(_ text: NSAttributedString, monospaced: Bool) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        // Rich documents carry their own (usually black) text colors, so show them on a white page.
        scroll.drawsBackground = !monospaced
        scroll.backgroundColor = .white
        textView.drawsBackground = !monospaced
        textView.backgroundColor = .white
        if monospaced {
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = .textColor
            textView.string = text.string
        } else {
            textView.textStorage?.setAttributedString(text)
        }
        return scroll
    }

    private static func thumbnailView(_ url: URL, scale: CGFloat) async -> NSView? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 512, height: 512), scale: scale, representationTypes: .thumbnail)
        guard let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let view = PreviewImageView()
        view.image = thumbnail.nsImage
        view.imageScaling = .scaleProportionallyDown
        return padded(view, inset: 24)
    }

    // MARK: - Helpers

    private static func attributedDocumentType(for type: UTType) -> NSAttributedString.DocumentType? {
        // WKWebView can't run in the extension sandbox, so HTML is rendered as a static attributed string.
        if type.conforms(to: .html) { return .html }
        if type.conforms(to: .rtf) { return .rtf }
        if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .rtfd }
        switch type.identifier {
        case "org.openxmlformats.wordprocessingml.document": return .officeOpenXML
        case "com.microsoft.word.doc": return .docFormat
        case "org.oasis-open.opendocument.text": return .openDocument
        default: return nil
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    }

    /// Treats files with unknown extensions (Makefile, LICENSE, .conf, ...) as text if they decode as UTF-8.
    private static func looksLikeText(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard var sample = try? handle.read(upToCount: 8192), !sample.isEmpty else { return false }
        if sample.contains(0) { return false }
        // Don't reject a valid file just because the sample cut a multi-byte character in half.
        for _ in 0..<3 where String(data: sample, encoding: .utf8) == nil {
            sample = sample.dropLast()
        }
        return String(data: sample, encoding: .utf8) != nil
    }

    private static func padded(_ view: NSView, inset: CGFloat) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
        // Let the image shrink with the pane instead of forcing the pane to the image's size.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return container
    }
}

/// An image preview that reports double-clicks.
private final class PreviewImageView: NSImageView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let onDoubleClick {
            onDoubleClick()
        } else {
            super.mouseDown(with: event)
        }
    }
}
