import AppKit

/// Colors for highlight.js scopes, modeled on Xcode's default light and dark themes.
/// Colors are dynamic, so previews follow the system appearance without re-highlighting.
@MainActor
enum SyntaxTheme {
    private struct Style {
        var color: NSColor?
        var bold = false
        var italic = false
    }

    private static func color(_ light: Int, _ dark: Int) -> NSColor {
        func make(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let light = make(light), dark = make(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static let keyword = color(0xAD3DA4, 0xFF7AB2)
    private static let string = color(0xD12F1B, 0xFF8170)
    private static let number = color(0x272AD8, 0xD9C97C)
    private static let comment = color(0x5D6C79, 0x7F8C98)
    private static let type = color(0x0B4F79, 0x5DD8FF)
    private static let declaration = color(0x0F68A0, 0x41A1C0)
    private static let builtIn = color(0x6C36A9, 0xA167E6)
    private static let attribute = color(0x815F03, 0xBF8555)
    private static let property = color(0x326D74, 0x67B7A4)
    private static let preprocessor = color(0x78492A, 0xFD8F3F)
    private static let addition = color(0x1C7A1C, 0x87D96C)
    private static let deletion = color(0xC41A16, 0xFF6B6B)

    /// Keyed by highlight.js scope; "title.function" falls back to "title" if not listed.
    private static let styles: [String: Style] = [
        "keyword": Style(color: keyword, bold: true),
        "literal": Style(color: keyword, bold: true),
        "variable.language": Style(color: keyword, bold: true),
        "built_in": Style(color: builtIn),
        "type": Style(color: type),
        "title": Style(color: declaration),
        "title.class": Style(color: type),
        "title.function.invoke": Style(color: property),
        "string": Style(color: string),
        "regexp": Style(color: string),
        "char.escape": Style(color: number),
        "subst": Style(color: .textColor), // interpolation inside a string
        "number": Style(color: number),
        "symbol": Style(color: number),
        "bullet": Style(color: number),
        "comment": Style(color: comment),
        "quote": Style(color: comment, italic: true),
        "doctag": Style(color: comment, bold: true),
        "meta": Style(color: preprocessor),
        "meta.keyword": Style(color: preprocessor, bold: true),
        "meta.string": Style(color: string),
        "attr": Style(color: attribute),
        "attribute": Style(color: attribute),
        "property": Style(color: property),
        "name": Style(color: keyword),
        "tag": Style(color: nil),
        "selector-tag": Style(color: keyword, bold: true),
        "selector-id": Style(color: type),
        "selector-class": Style(color: type),
        "selector-attr": Style(color: attribute),
        "selector-pseudo": Style(color: builtIn),
        "template-tag": Style(color: keyword),
        "template-variable": Style(color: property),
        "section": Style(color: declaration, bold: true),
        "link": Style(color: declaration),
        "code": Style(color: preprocessor),
        "emphasis": Style(color: nil, italic: true),
        "strong": Style(color: nil, bold: true),
        "addition": Style(color: addition),
        "deletion": Style(color: deletion),
    ]

    static func apply(_ spans: [SyntaxHighlighter.Span], to storage: NSTextStorage, font: NSFont) {
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let length = storage.length

        storage.beginEditing()
        for span in spans where NSMaxRange(span.range) <= length {
            guard let style = style(for: span.scope) else { continue }
            if let color = style.color {
                storage.addAttribute(.foregroundColor, value: color, range: span.range)
            }
            if style.bold {
                storage.addAttribute(.font, value: bold, range: span.range)
            } else if style.italic {
                storage.addAttribute(.font, value: italic, range: span.range)
            }
        }
        storage.endEditing()
    }

    private static func style(for scope: String) -> Style? {
        var scope = Substring(scope)
        while true {
            if let style = styles[String(scope)] { return style }
            guard let dot = scope.lastIndex(of: ".") else { return nil }
            scope = scope[..<dot]
        }
    }
}
