import Foundation
import JavaScriptCore
import os

/// Finds syntax-highlighting spans in source code using the bundled highlight.js
/// (see scripts/update-highlightjs.sh), run in JavaScriptCore.
actor SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    /// Larger files are shown without coloring; highlight.js takes roughly 1 ms per KB.
    static let maxBytes = 512 * 1024

    struct Span: Sendable {
        /// UTF-16 range in the highlighted code, i.e. directly usable on an NSTextStorage.
        var range: NSRange
        /// highlight.js scope, e.g. "keyword", "string" or "title.function".
        let scope: String
    }

    private var hljs: JSValue?
    private var didLoad = false
    private let latestRequest = OSAllocatedUnfairLock(initialState: 0)

    /// Returns spans for `code`, or nil if the file's language isn't known, highlighting failed,
    /// or a newer request arrived first (the user has already moved on to another file).
    nonisolated func highlight(_ code: String, fileName: String) async -> [Span]? {
        let request = latestRequest.withLock { $0 += 1; return $0 }
        return await highlight(code, fileName: fileName, request: request)
    }

    private func highlight(_ code: String, fileName: String, request: Int) -> [Span]? {
        guard request == latestRequest.withLock({ $0 }),
              let hljs = loadHighlightJS(),
              let language = language(forFileNamed: fileName, code: code, hljs: hljs) else { return nil }

        let options: [String: Any] = ["language": language, "ignoreIllegals": true]
        guard let result = hljs.invokeMethod("highlight", withArguments: [code, options]),
              let value = result.objectForKeyedSubscript("value"), value.isString,
              let html = value.toString() else { return nil }
        return Self.spans(fromHTML: html, expectedLength: (code as NSString).length)
    }

    // MARK: - Language detection

    /// Languages for names highlight.js doesn't recognize as an alias on its own.
    private static let languagesByFileName: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile",
        "dockerfile": "dockerfile", "containerfile": "dockerfile",
        "cmakelists.txt": "cmake",
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "fastfile": "ruby", "brewfile": "ruby",
        "jenkinsfile": "groovy",
        ".bashrc": "bash", ".bash_profile": "bash", ".zshrc": "bash", ".zprofile": "bash", ".profile": "bash",
        ".gitconfig": "ini", ".editorconfig": "ini",
    ]

    private static let languagesByExtension: [String: String] = [
        "m": "objectivec",
        "plist": "xml", "entitlements": "xml", "xib": "xml", "storyboard": "xml", "svg": "xml",
        "csproj": "xml", "vcxproj": "xml", "vue": "xml", "svelte": "xml",
        "ipynb": "json", "geojson": "json", "webmanifest": "json", "jsonc": "json", "json5": "json",
        "mts": "typescript", "cts": "typescript",
        "pyi": "python", "pyw": "python",
        "gemspec": "ruby", "podspec": "ruby", "rake": "ruby",
        "command": "bash",
        "bat": "dos", "cmd": "dos",
        "ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
        "cfg": "ini",
    ]

    /// Interpreters named on a "#!" line, for scripts without an extension.
    private static let languagesByInterpreter: [String: String] = [
        "sh": "bash", "bash": "bash", "zsh": "bash", "ksh": "bash", "dash": "bash",
        "python": "python", "ruby": "ruby", "node": "javascript", "perl": "perl", "php": "php",
        "lua": "lua", "rscript": "r", "swift": "swift", "tclsh": "tcl", "awk": "awk", "pwsh": "powershell",
    ]

    private func language(forFileNamed fileName: String, code: String, hljs: JSValue) -> String? {
        let name = fileName.lowercased()
        if let language = Self.languagesByFileName[name] { return language }

        let ext = (name as NSString).pathExtension
        if let language = Self.languagesByExtension[ext] { return language }
        if !ext.isEmpty, isHighlightable(ext, hljs: hljs) { return ext }

        // Auto-detection is slow and unreliable, so only trust an explicit interpreter line.
        guard code.hasPrefix("#!"), let line = code.split(separator: "\n", maxSplits: 1).first else { return nil }
        // "#!/usr/bin/env -S python3 -u" → ["python3", "-u"]
        var words = line.dropFirst(2).split(separator: " ").map { String($0.split(separator: "/").last ?? $0) }
        if words.first == "env" { words.removeFirst() }
        while words.first?.hasPrefix("-") == true { words.removeFirst() }
        guard let interpreter = words.first?.lowercased() else { return nil }
        // Strip versions: python3.12 → python.
        let base = String(interpreter.prefix { $0.isLetter })
        return Self.languagesByInterpreter[interpreter] ?? Self.languagesByInterpreter[base]
    }

    /// True if highlight.js knows `alias` as a language other than plain text.
    private func isHighlightable(_ alias: String, hljs: JSValue) -> Bool {
        guard let language = hljs.invokeMethod("getLanguage", withArguments: [alias]), language.isObject,
              let name = language.objectForKeyedSubscript("name")?.toString() else { return false }
        return name != "Plain text"
    }

    // MARK: - Loading

    private func loadHighlightJS() -> JSValue? {
        if didLoad { return hljs }
        didLoad = true
        guard let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(source)
        guard let value = context.objectForKeyedSubscript("hljs"), value.isObject else { return nil }
        hljs = value // keeps the context alive
        return value
    }

    // MARK: - HTML → spans

    /// Converts highlight.js's HTML output (`<span class="hljs-keyword">let</span> x`) into
    /// ranges in the original text. Spans are returned outermost-first, so applying them in
    /// order lets nested scopes override their parents.
    static func spans(fromHTML html: String, expectedLength: Int) -> [Span]? {
        func code(_ c: Unicode.Scalar) -> UInt16 { UInt16(UInt8(ascii: c)) }
        let lt = code("<"), gt = code(">"), slash = code("/"), amp = code("&"), semicolon = code(";")
        let chars = Array(html.utf16)
        var spans: [Span] = []
        var open: [Int?] = [] // index into `spans` for each open tag; nil for unstyled tags
        var offset = 0
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case lt:
                guard let end = chars[i...].firstIndex(of: gt), i + 1 < end else { return nil }
                if chars[i + 1] == slash {
                    if let popped = open.popLast(), let index = popped {
                        spans[index].range.length = offset - spans[index].range.location
                    }
                } else if let scope = scope(fromTag: String(decoding: chars[(i + 1)..<end], as: UTF16.self)) {
                    open.append(spans.count)
                    spans.append(Span(range: NSRange(location: offset, length: 0), scope: scope))
                } else {
                    open.append(nil)
                }
                i = end + 1
            case amp:
                // highlight.js only escapes & < > " and ', each of which is one character.
                guard let end = chars[i...].firstIndex(of: semicolon) else { return nil }
                offset += 1
                i = end + 1
            default:
                offset += 1
                i += 1
            }
        }
        guard offset == expectedLength else { return nil }
        return spans.filter { $0.range.length > 0 }
    }

    /// `span class="hljs-title class_ inherited__"` → "title.class.inherited". Sub-language
    /// wrappers (`class="language-xml"`) have no scope of their own.
    private static func scope(fromTag tag: String) -> String? {
        guard let start = tag.range(of: "class=\""), let end = tag.range(of: "\"", options: .backwards),
              start.upperBound < end.lowerBound else { return nil }
        let classes = tag[start.upperBound..<end.lowerBound].split(separator: " ")
        guard let first = classes.first, first.hasPrefix("hljs-") else { return nil }
        let rest = classes.dropFirst().map { String($0.prefix { $0 != "_" }) }
        return ([String(first.dropFirst(5))] + rest).joined(separator: ".")
    }
}
