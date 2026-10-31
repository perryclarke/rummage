import Cocoa
import CoreText

/// A Font Book–style sample of a font file: its names, characters and a sentence at several sizes.
/// Fonts are loaded straight from the file with CoreText, without installing them. Collections
/// (.ttc) get a menu to choose a style.
@MainActor
final class FontPreviewView: NSView {
    static let fileExtensions: Set<String> = ["ttf", "otf", "ttc", "otc", "woff", "woff2", "dfont"]

    private let faces: [CTFont]
    private let textView: NSTextView

    init?(url: URL) {
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
        guard !descriptors.isEmpty else { return nil }
        faces = descriptors
            .map { CTFontCreateWithFontDescriptor($0, 12, nil) }
            .sorted { Self.sortKey($0) < Self.sortKey($1) }
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init(frame: .zero)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 14)
        scroll.drawsBackground = false

        var views: [NSView] = [scroll]
        // Start with the regular upright style, as Font Book does.
        let initial = faces.indices.min { Self.distanceFromRegular(faces[$0]) < Self.distanceFromRegular(faces[$1]) } ?? 0
        if faces.count > 1 {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for face in faces {
                // Not addItems(withTitles:), which drops duplicate titles.
                popup.menu?.addItem(NSMenuItem(title: CTFontCopyFullName(face) as String, action: nil, keyEquivalent: ""))
            }
            popup.selectItem(at: initial)
            popup.target = self
            popup.action = #selector(selectFace(_:))
            let bar = NSStackView(views: [popup])
            bar.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 0, right: 16)
            views.insert(bar, at: 0)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        show(faces[initial])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func selectFace(_ sender: NSPopUpButton) {
        show(faces[sender.indexOfSelectedItem])
    }

    private func show(_ face: CTFont) {
        textView.textStorage?.setAttributedString(Self.sample(of: face))
        textView.scroll(.zero)
    }

    // MARK: - Sample

    private static let sentence = "The quick brown fox jumps over the lazy dog."
    private static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ\nabcdefghijklmnopqrstuvwxyz\n1234567890 .,:;!?&@#$%*()[]{}"

    private static func sample(of face: CTFont) -> NSAttributedString {
        let text = NSMutableAttributedString()
        func append(_ string: String, font: NSFont, color: NSColor = .labelColor, paragraph: NSParagraphStyle? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if let paragraph { attributes[.paragraphStyle] = paragraph }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        func sized(_ size: CGFloat) -> NSFont { CTFontCreateCopyWithAttributes(face, size, nil, nil) as NSFont }

        append((CTFontCopyFullName(face) as String) + "\n", font: .boldSystemFont(ofSize: 18))
        var details = [CTFontCopyFamilyName(face) as String]
        if let style = CTFontCopyName(face, kCTFontStyleNameKey) as String? { details.append(style) }
        details.append("\(CTFontGetGlyphCount(face).formatted()) glyphs")
        if let version = CTFontCopyName(face, kCTFontVersionNameKey) as String? {
            details.append(String(version.prefix { $0 != ";" && $0 != "\n" }))
        }
        append(details.joined(separator: " · ") + "\n\n", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)

        let (characters, line) = sampleText(for: face)
        append(characters + "\n\n", font: sized(28))

        // A waterfall of sizes, labelled in a margin.
        let waterfall = NSMutableParagraphStyle()
        waterfall.tabStops = [NSTextTab(textAlignment: .left, location: 32)]
        waterfall.headIndent = 32
        waterfall.paragraphSpacing = 6
        for size in [12, 18, 24, 36, 48, 72] {
            append("\(size)\t", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor, paragraph: waterfall)
            append(line + "\n", font: sized(CGFloat(size)), paragraph: waterfall)
        }
        if let copyright = CTFontCopyName(face, kCTFontCopyrightNameKey) as String? {
            append("\n" + copyright, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
        }
        return text
    }

    /// The alphabet and pangram for fonts with Latin letters; otherwise characters from the
    /// font itself (e.g. for Javanese, CJK or symbol fonts), so the sample isn't drawn in a
    /// fallback font.
    private static func sampleText(for face: CTFont) -> (characters: String, line: String) {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf16)
        let covered = letters.filter { character in
            var glyph: CGGlyph = 0
            return withUnsafePointer(to: character) { CTFontGetGlyphsForCharacters(face, $0, &glyph, 1) }
        }
        if covered.count >= letters.count * 9 / 10 {
            return (alphabet, sentence)
        }

        let characterSet = CTFontCopyCharacterSet(face) as CharacterSet
        var repertoire: [Unicode.Scalar] = []
        for value in 0xA0...0x2FFFF {
            if repertoire.count == 160 { break }
            // U+25CC is the dotted circle fonts show combining marks on, not a character of its own.
            guard value != 0x25CC, let scalar = Unicode.Scalar(value), characterSet.contains(scalar) else { continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .spaceSeparator, .lineSeparator, .paragraphSeparator,
                 .nonspacingMark, .spacingMark, .enclosingMark, .privateUse, .surrogate, .unassigned:
                continue
            default:
                repertoire.append(scalar)
            }
        }
        let characters = repertoire.map { String(Character($0)) }.joined(separator: " ")
        let lettersOnly = repertoire.filter { $0.properties.isAlphabetic }
        let line = String(String.UnicodeScalarView((lettersOnly.isEmpty ? repertoire : lettersOnly).prefix(24)))
        return (characters, line)
    }

    // MARK: - Ordering faces

    private static func traits(_ face: CTFont) -> (weight: Double, width: Double, italic: Bool) {
        let traits = CTFontCopyTraits(face) as? [CFString: Any] ?? [:]
        let italic = CTFontGetSymbolicTraits(face).contains(.traitItalic)
        return ((traits[kCTFontWeightTrait] as? Double) ?? 0, (traits[kCTFontWidthTrait] as? Double) ?? 0, italic)
    }

    private static func sortKey(_ face: CTFont) -> String {
        // Family, then width, weight and italic, as zero-padded numbers so strings sort numerically.
        let t = traits(face)
        let number = { (value: Double) in String(format: "%04d", Int((value + 1) * 1000)) }
        return [CTFontCopyFamilyName(face) as String, number(t.width), number(t.weight), t.italic ? "1" : "0"].joined(separator: "|")
    }

    private static func distanceFromRegular(_ face: CTFont) -> Double {
        let t = traits(face)
        return abs(t.weight) + abs(t.width) + (t.italic ? 1 : 0)
    }
}
