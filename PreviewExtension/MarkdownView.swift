import Cocoa

/// Renders a Markdown file (GitHub flavored) as formatted text. Foundation parses the Markdown;
/// `MarkdownRenderer` maps its block and inline intents to fonts, indents, text blocks and tables.
/// Fenced code blocks are syntax colored with the same highlighter as source files.
@MainActor
final class MarkdownView: NSView {
    static let fileExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdtext"]
    /// Larger files are shown as plain text.
    static let maxBytes = 1 << 20

    private let textView = NSTextView(usingTextLayoutManager: false) // TextKit 1, which supports tables

    /// Called when a link is clicked. The extension sandbox doesn't allow opening URLs, so
    /// clicking a link copies it instead.
    var onCopyLink: (() -> Void)?

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count <= Self.maxBytes,
              let rendered = MarkdownRenderer.render(String(decoding: data, as: UTF8.self)) else { return nil }
        super.init(frame: .zero)

        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 16)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(rendered.text)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        highlight(rendered.codeBlocks)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Colors fenced code blocks one at a time (the highlighter drops all but its latest request).
    private func highlight(_ blocks: [MarkdownRenderer.CodeBlock]) {
        guard !blocks.isEmpty else { return }
        Task { [weak self] in
            for block in blocks {
                guard let code = (self?.textView.string as NSString?)?.substring(with: block.range),
                      let spans = await SyntaxHighlighter.shared.highlight(code, fileName: "code." + block.language),
                      let self, let storage = self.textView.textStorage else { continue }
                let shifted = spans.map { span in
                    var span = span
                    span.range.location += block.range.location
                    return span
                }
                SyntaxTheme.apply(shifted, to: storage, font: MarkdownRenderer.codeFont)
            }
        }
    }
}

extension MarkdownView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let address = (link as? URL)?.absoluteString ?? String(describing: link)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        onCopyLink?()
        return true
    }
}

/// Converts Markdown to an attributed string for a TextKit 1 text view. Raw HTML is left out, and
/// images show their description, since neither relative nor remote images can be loaded here.
@MainActor
struct MarkdownRenderer {
    struct CodeBlock {
        let range: NSRange
        let language: String
    }

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let bodyFont = NSFont.systemFont(ofSize: 14)
    private static let fill = NSColor.quaternarySystemFill
    private static let border = NSColor.separatorColor

    static func render(_ markdown: String) -> (text: NSAttributedString, codeBlocks: [CodeBlock])? {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return nil }
        var renderer = MarkdownRenderer()
        for run in parsed.runs {
            renderer.append(String(parsed[run.range].characters), intent: run.presentationIntent,
                            inline: run.inlinePresentationIntent ?? [], link: run.link, isImage: run.imageURL != nil)
        }
        return (renderer.output, renderer.codeBlocks)
    }

    // MARK: - State

    private struct BlockStyle {
        var paragraph = NSParagraphStyle.default
        var font = NSFont.systemFont(ofSize: 14)
        var color = NSColor.labelColor
        /// Set for fenced code blocks that name their language.
        var codeLanguage: String?
    }

    private let output = NSMutableAttributedString()
    private var codeBlocks: [CodeBlock] = []
    private var block = BlockStyle()
    private var blockIdentity: Int?
    private var startedListItems = Set<Int>()
    private var previousListDepth = 0
    /// The code block or table the previous block belonged to.
    private var previousBox: Int?
    private var tables: [Int: NSTextTable] = [:]
    private var quoteBlocks: [Int: NSTextBlock] = [:]

    private mutating func append(_ text: String, intent: PresentationIntent?, inline: InlinePresentationIntent, link: URL?, isImage: Bool) {
        if inline.contains(.blockHTML) || inline.contains(.inlineHTML) { return }
        var text = text
        let components = intent?.components ?? []

        // Each block is its own paragraph; the newline ending the previous one takes its style.
        if components.first?.identity != blockIdentity {
            if output.length > 0 {
                output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: block.paragraph, .font: block.font]))
            }
            blockIdentity = components.first?.identity
            block = style(for: components, text: &text)
        }

        var font = block.font
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: block.color, .paragraphStyle: block.paragraph]
        if inline.contains(.code) {
            font = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            attributes[.backgroundColor] = Self.fill
        }
        if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if inline.contains(.lineBreak) { text = "\u{2028}" } // a hard line break within the paragraph
        if let link {
            attributes[.link] = link
            attributes[.toolTip] = link.absoluteString // where it goes, since it can't be opened
        }
        attributes[.font] = font

        if let language = block.codeLanguage {
            if text.hasSuffix("\n") { text.removeLast() } // the next block's separator ends it
            codeBlocks.append(CodeBlock(range: NSRange(location: output.length, length: (text as NSString).length), language: language))
        }
        output.append(isImage ? Self.image(described: text, attributes: attributes) : NSAttributedString(string: text, attributes: attributes))
    }

    /// The paragraph style, font and color for a new block. For the first paragraph of a list
    /// item this also writes the list marker, taking a task list checkbox out of `text`.
    private mutating func style(for components: [PresentationIntent.IntentType], text: inout String) -> BlockStyle {
        var style = BlockStyle()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        paragraph.lineHeightMultiple = 1.1
        var textBlocks: [NSTextBlock] = []

        // Lists indent; quotes get a bar on the left. Components run from innermost to outermost.
        let listDepth = components.filter(\.kind.isList).count
        let indent = CGFloat(listDepth) * 22
        paragraph.headIndent = indent
        paragraph.firstLineHeadIndent = indent
        if listDepth > 0 { paragraph.paragraphSpacing = 4 }
        // List items are close together, so leave a gap where a list ends.
        if listDepth == 0 && previousListDepth > 0 { paragraph.paragraphSpacingBefore = 8 }
        previousListDepth = listDepth
        // Code blocks and tables have no paragraph spacing of their own (and bottom margins on
        // text blocks are ignored), so space the block after them.
        let box: Int? = switch components.first?.kind {
        case .codeBlock?: components.first?.identity
        case .tableCell?: components.first(where: \.kind.isTable)?.identity
        default: nil
        }
        if previousBox != nil && box == nil { paragraph.paragraphSpacingBefore = max(paragraph.paragraphSpacingBefore, 10) }
        let followsOtherBox = previousBox != nil && box != nil && box != previousBox
        previousBox = box
        let quotes = components.reversed().filter { $0.kind == .blockQuote }
        if !quotes.isEmpty { style.color = .secondaryLabelColor }
        // AppKit throws when it draws a table nested in another text block, so a table in a
        // quote draws the quote's bar itself (see the table cell case below).
        if case .tableCell? = components.first?.kind {} else {
            for quote in quotes {
                textBlocks.append(quoteBlocks[quote.identity] ?? {
                    let block = Self.fullWidthBlock()
                    Self.addQuoteBar(to: block)
                    quoteBlocks[quote.identity] = block
                    return block
                }())
            }
        }
        // Paragraph spacing can't separate two boxes either (e.g. a table right after a code
        // block), so put an empty paragraph between them.
        if followsOtherBox {
            let spacer = NSMutableParagraphStyle()
            spacer.minimumLineHeight = 10
            spacer.maximumLineHeight = 10
            spacer.textBlocks = textBlocks // only the enclosing quotes' blocks at this point
            output.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: spacer, .font: Self.bodyFont]))
        }

        if let item = components.first(where: \.kind.isListItem), case .listItem(let ordinal) = item.kind,
           startedListItems.insert(item.identity).inserted {
            let isOrdered = components.first(where: \.kind.isList)?.kind == .orderedList
            var marker = isOrdered ? "\(ordinal)." : ["•", "◦", "▪"][min(listDepth, 3) - 1]
            for (box, symbol) in [("[ ] ", "☐"), ("[x] ", "☑"), ("[X] ", "☑")] where text.hasPrefix(box) {
                marker = symbol // GitHub task list item
                text.removeFirst(box.count)
            }
            paragraph.firstLineHeadIndent = indent - 18
            paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            output.append(NSAttributedString(string: marker + "\t", attributes: [
                .font: Self.bodyFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
            ]))
        }

        switch components.first?.kind {
        case .header(let level)?:
            let sizes: [CGFloat] = [26, 21, 17, 15, 14, 13]
            style.font = .systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: level <= 2 ? .bold : .semibold)
            if level == 6 { style.color = .secondaryLabelColor }
            paragraph.paragraphSpacingBefore = level <= 2 ? 14 : 8
            paragraph.paragraphSpacing = 8
            if level <= 2 {
                textBlocks.append(Self.rule(padding: 4))
            }
        case .codeBlock(let language)?:
            style.font = Self.codeFont
            // A block's background covers its margins too, so the margins go on an outer block.
            let outer = Self.fullWidthBlock()
            outer.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
            let block = Self.fullWidthBlock()
            block.backgroundColor = Self.fill
            block.setWidth(10, type: .absoluteValueType, for: .padding)
            textBlocks += [outer, block]
            paragraph.headIndent = 0
            paragraph.firstLineHeadIndent = 0
            paragraph.lineHeightMultiple = 1
            paragraph.paragraphSpacing = 0 // each line is a paragraph; the block's margin spaces it
            if let language = language?.split(separator: " ").first {
                style.codeLanguage = language.lowercased()
            }
        case .thematicBreak?:
            text = " "
            style.font = .systemFont(ofSize: 4)
            textBlocks.append(Self.rule(padding: 0))
        case .tableCell(let column)?:
            guard let tableComponent = components.first(where: \.kind.isTable),
                  case .table(let columns) = tableComponent.kind else { break }
            let table = tables[tableComponent.identity] ?? {
                let table = NSTextTable()
                table.numberOfColumns = columns.count
                // Paragraph indents don't move tables, so list indents become a margin. Only the
                // innermost quote's bar is drawn beside the table; outer quotes add to the margin.
                let margin = indent + CGFloat(max(quotes.count - 1, 0)) * Self.quoteIndent
                table.setWidth(margin, type: .absoluteValueType, for: .margin, edge: .minX)
                if !quotes.isEmpty { Self.addQuoteBar(to: table) }
                tables[tableComponent.identity] = table
                return table
            }()
            var row = 0 // the header row, which has no index of its own
            for component in components {
                if case .tableRow(let index) = component.kind { row = index }
            }
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            // Not collapsesBorders, which ignores the table's own padding (the gap after a quote's
            // bar): each cell draws its right and bottom edges, the first row and column also the rest.
            var edges: [NSRectEdge] = [.maxX, .maxY]
            if column == 0 { edges.append(.minX) }
            if row == 0 { edges.append(.minY) }
            for edge in edges {
                cell.setWidth(1, type: .absoluteValueType, for: .border, edge: edge)
                cell.setBorderColor(Self.border, for: edge)
            }
            cell.setWidth(6, type: .absoluteValueType, for: .padding)
            if components.contains(where: { $0.kind == .tableHeaderRow }) {
                cell.backgroundColor = Self.fill
                style.font = .boldSystemFont(ofSize: Self.bodyFont.pointSize)
            }
            textBlocks.append(cell)
            paragraph.headIndent = 0
            paragraph.firstLineHeadIndent = 0
            paragraph.paragraphSpacing = 0
            if column < columns.count {
                switch columns[column].alignment {
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                default: break
                }
            }
        default:
            break
        }
        paragraph.textBlocks = textBlocks
        style.paragraph = paragraph
        return style
    }

    /// The width of a quote's bar plus the padding after it.
    private static let quoteIndent: CGFloat = 15

    private static func addQuoteBar(to block: NSTextBlock) {
        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
        block.setBorderColor(border, for: .minX)
        block.setWidth(quoteIndent - 3, type: .absoluteValueType, for: .padding, edge: .minX)
    }

    /// Plain text blocks shrink to their narrowest line unless given a width.
    private static func fullWidthBlock() -> NSTextBlock {
        let block = NSTextBlock()
        block.setValue(100, type: .percentageValueType, for: .width)
        return block
    }

    /// A text block drawing a line under its paragraph (for headings and horizontal rules).
    private static func rule(padding: CGFloat) -> NSTextBlock {
        let block = Self.fullWidthBlock()
        block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
        block.setBorderColor(border, for: .maxY)
        block.setWidth(padding, type: .absoluteValueType, for: .padding, edge: .maxY)
        return block
    }

    /// A picture symbol followed by the image's description.
    private static func image(described description: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = attributes
        attributes[.foregroundColor] = NSColor.secondaryLabelColor
        let result = NSMutableAttributedString()
        if let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: "Image") {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
            result.append(string)
            result.append(NSAttributedString(string: " ", attributes: attributes))
        }
        result.append(NSAttributedString(string: description.isEmpty ? "Image" : description, attributes: attributes))
        return result
    }
}

private extension PresentationIntent.Kind {
    var isList: Bool { self == .orderedList || self == .unorderedList }
    var isListItem: Bool {
        if case .listItem = self { return true }
        return false
    }
    var isTable: Bool {
        if case .table = self { return true }
        return false
    }
}
