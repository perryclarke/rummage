import AVKit
import Cocoa
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

    static func makeView(for url: URL, scale: CGFloat) async -> NSView? {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data

        if type.conforms(to: .pdf) {
            return pdfView(url)
        }
        if type.conforms(to: .image), let view = imageView(url) {
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
        if let documentType = attributedDocumentType(for: type),
           let text = try? NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil) {
            return textView(text, monospaced: false)
        }
        if type.conforms(to: .text) || looksLikeText(url) {
            return plainTextView(url)
        }
        return await thumbnailView(url, scale: scale)
    }

    /// Releases resources held by a preview view (e.g. stops playback).
    static func tearDown(_ view: NSView) {
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

    private static func imageView(_ url: URL) -> NSView? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        view.isEditable = false
        return padded(view, inset: 12)
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
        let view = NSImageView()
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
