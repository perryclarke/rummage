import Foundation

/// Reads the cell values of an .xlsx workbook, which is a zip of XML parts (Office Open XML).
/// Values are shown as Excel last saved them (formulas aren't recalculated), using each cell's
/// number format; of the other formatting only bold text and column widths are kept.
enum XLSXReader {
    static func read(_ url: URL) throws -> Spreadsheet {
        let parts = try ArchiveReader(url: url).readEntries(maxTotalBytes: 256 << 20) {
            $0.hasSuffix(".xml") || $0.hasSuffix(".rels")
        }
        let workbookPath = relationships(in: parts["_rels/.rels"], relativeTo: "")
            .first { $0.type.hasSuffix("/officeDocument") }?.target ?? "xl/workbook.xml"
        guard let workbook = parts[workbookPath] else { throw ArchiveError(message: "Not an Excel workbook.") }

        let directory = (workbookPath as NSString).deletingLastPathComponent
        let relationshipsPath = (directory as NSString).appendingPathComponent(
            "_rels/" + (workbookPath as NSString).lastPathComponent + ".rels")
        let workbookRelationships = relationships(in: parts[relationshipsPath], relativeTo: directory)
        func part(ofType type: String, default name: String) -> Data? {
            let path = workbookRelationships.first { $0.type.hasSuffix(type) }?.target
            return parts[path ?? (directory as NSString).appendingPathComponent(name)]
        }
        let strings = sharedStrings(part(ofType: "/sharedStrings", default: "sharedStrings.xml"))
        let styles = cellStyles(part(ofType: "/styles", default: "styles.xml"))

        // Sheet names and order come from the workbook; their XML from its relationships.
        var sheetRefs: [(name: String, id: String)] = []
        var date1904 = false
        let walker = XMLWalker()
        walker.didStart = { element, attributes in
            switch element {
            case "sheet":
                let isHidden = attributes["state"].map { $0 != "visible" } ?? false
                guard !isHidden, let id = attributes.first(where: { $0.key.hasSuffix(":id") })?.value else { return }
                sheetRefs.append((attributes["name"] ?? "Sheet \(sheetRefs.count + 1)", id))
            case "workbookPr":
                date1904 = ["1", "true"].contains(attributes["date1904"] ?? "")
            default:
                break
            }
        }
        guard walker.parse(workbook) else { throw ArchiveError(message: "Unreadable workbook.") }

        let sheets = sheetRefs.compactMap { ref -> Spreadsheet.Sheet? in
            guard let path = workbookRelationships.first(where: { $0.id == ref.id })?.target,
                  let data = parts[path] else { return nil }
            return sheet(named: ref.name, data: data, strings: strings, styles: styles, date1904: date1904)
        }
        guard !sheets.isEmpty else { throw ArchiveError(message: "The workbook has no sheets.") }
        return Spreadsheet(sheets: sheets)
    }

    // MARK: - Parts

    private struct Relationship {
        let id: String
        let type: String
        /// Path of the target part inside the package.
        let target: String
    }

    private static func relationships(in data: Data?, relativeTo directory: String) -> [Relationship] {
        guard let data else { return [] }
        var result: [Relationship] = []
        let walker = XMLWalker()
        walker.didStart = { element, attributes in
            guard element == "Relationship", attributes["TargetMode"] != "External",
                  let id = attributes["Id"], let target = attributes["Target"] else { return }
            result.append(Relationship(id: id, type: attributes["Type"] ?? "", target: resolve(target, relativeTo: directory)))
        }
        walker.parse(data)
        return result
    }

    /// "worksheets/sheet1.xml" relative to "xl" → "xl/worksheets/sheet1.xml"; "/xl/…" is absolute.
    private static func resolve(_ target: String, relativeTo directory: String) -> String {
        var components = target.hasPrefix("/") ? [] : directory.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            if component == ".." {
                _ = components.popLast()
            } else if component != "." {
                components.append(String(component))
            }
        }
        return components.joined(separator: "/")
    }

    private static func sharedStrings(_ data: Data?) -> [String] {
        guard let data else { return [] }
        var strings: [String] = []
        var current = ""
        var inText = false
        var phoneticDepth = 0 // <rPh> holds pronunciation hints, not part of the text
        let walker = XMLWalker()
        walker.didStart = { element, _ in
            switch element {
            case "si": current = ""
            case "t": inText = phoneticDepth == 0
            case "rPh": phoneticDepth += 1
            default: break
            }
        }
        walker.didEnd = { element in
            switch element {
            case "si": strings.append(current)
            case "t": inText = false
            case "rPh": phoneticDepth -= 1
            default: break
            }
        }
        walker.foundText = { if inText { current += $0 } }
        walker.parse(data)
        return strings
    }

    private struct CellStyle {
        let format: NumberFormat
        let isBold: Bool
    }

    /// The styles cells refer to by index (`<c s="3">`).
    private static func cellStyles(_ data: Data?) -> [CellStyle] {
        guard let data else { return [] }
        var customFormats: [Int: String] = [:]
        var boldFonts: [Bool] = []
        var formats: [(numberFormat: Int, font: Int)] = []
        var section = "" // the list being read: fonts, cellXfs, … (<font> and <xf> also occur elsewhere)
        let walker = XMLWalker()
        walker.didStart = { element, attributes in
            switch element {
            case "numFmts", "fonts", "cellXfs", "cellStyleXfs", "dxfs":
                section = element
            case "numFmt" where section == "numFmts":
                if let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"] {
                    customFormats[id] = code
                }
            case "font" where section == "fonts":
                boldFonts.append(false)
            case "b" where section == "fonts" && !boldFonts.isEmpty:
                boldFonts[boldFonts.count - 1] = !["0", "false"].contains(attributes["val"] ?? "true")
            case "xf" where section == "cellXfs":
                formats.append((Int(attributes["numFmtId"] ?? "") ?? 0, Int(attributes["fontId"] ?? "") ?? 0))
            default:
                break
            }
        }
        walker.didEnd = { element in
            if element == section { section = "" }
        }
        walker.parse(data)

        var parsed: [Int: NumberFormat] = [:]
        return formats.map { xf in
            let format = parsed[xf.numberFormat]
                ?? NumberFormat(code: customFormats[xf.numberFormat] ?? NumberFormat.builtIn[xf.numberFormat] ?? "General")
            parsed[xf.numberFormat] = format
            return CellStyle(format: format, isBold: boldFonts.indices.contains(xf.font) && boldFonts[xf.font])
        }
    }

    private static func sheet(named name: String, data: Data, strings: [String], styles: [CellStyle], date1904: Bool) -> Spreadsheet.Sheet {
        var sheet = Spreadsheet.Sheet(name: name)
        var row = -1
        var column = -1
        var type = ""
        var style = 0
        var value = ""
        var hasValue = false
        var inValue = false
        var phoneticDepth = 0
        let walker = XMLWalker()
        walker.didStart = { [unowned walker] element, attributes in
            switch element {
            case "row":
                row = (attributes["r"].flatMap(Int.init) ?? row + 2) - 1
                column = -1
                if row >= Spreadsheet.maxRows {
                    sheet.isTruncated = true
                    walker.stop()
                }
            case "c":
                if let reference = attributes["r"].flatMap(cellReference) {
                    (row, column) = reference
                } else {
                    column += 1
                }
                type = attributes["t"] ?? "n"
                style = attributes["s"].flatMap(Int.init) ?? 0
                value = ""
                hasValue = false
            case "v":
                inValue = true
                hasValue = true
            case "t" where type == "inlineStr":
                inValue = phoneticDepth == 0
                hasValue = true
            case "rPh":
                phoneticDepth += 1
            case "col":
                // Excel widths are in characters of the default font.
                if let first = attributes["min"].flatMap(Int.init), let last = attributes["max"].flatMap(Int.init),
                   let width = attributes["width"].flatMap(Double.init), first >= 1, first <= min(last, Spreadsheet.maxColumns) {
                    for c in first...min(last, Spreadsheet.maxColumns) {
                        sheet.columnWidths[c - 1] = width * 7
                    }
                }
            default:
                break
            }
        }
        walker.didEnd = { element in
            switch element {
            case "v", "t":
                inValue = false
            case "rPh":
                phoneticDepth -= 1
            case "c":
                guard hasValue, row >= 0, column >= 0 else { return }
                let cellStyle = styles.indices.contains(style) ? styles[style] : nil
                if var cell = Self.cell(type: type, value: value, strings: strings, format: cellStyle?.format, date1904: date1904) {
                    cell.isBold = cellStyle?.isBold ?? false
                    sheet.set(cell, row: row, column: column)
                }
            default:
                break
            }
        }
        walker.foundText = { if inValue { value += $0 } }
        walker.parse(data)
        return sheet
    }

    private static func cell(type: String, value: String, strings: [String], format: NumberFormat?, date1904: Bool) -> Spreadsheet.Cell? {
        switch type {
        case "s":
            guard let index = Int(value), strings.indices.contains(index) else { return nil }
            return .init(text: strings[index])
        case "str", "inlineStr":
            return .init(text: value)
        case "b":
            return .init(text: value == "1" ? "TRUE" : "FALSE", alignment: .center)
        case "e":
            return .init(text: value, alignment: .center)
        default:
            guard let number = Double(value) else { return value.isEmpty ? nil : .init(text: value) }
            return .init(text: (format ?? .general).string(for: number, date1904: date1904), alignment: .right)
        }
    }

    /// "B3" → (row: 2, column: 1). Absurdly long references (far past Excel's own limits) return
    /// nil rather than overflowing; ordinary out-of-range cells still parse and are counted as truncated.
    private static func cellReference(_ reference: String) -> (Int, Int)? {
        var column = 0
        var row = 0
        for byte in reference.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z") where row == 0:
                column = column * 26 + Int(byte - UInt8(ascii: "A")) + 1
                if column > 1 << 40 { return nil }
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                row = row * 10 + Int(byte - UInt8(ascii: "0"))
                if row > 1 << 40 { return nil }
            case UInt8(ascii: "$"):
                continue
            default:
                return nil
            }
        }
        return column > 0 && row > 0 ? (row - 1, column - 1) : nil
    }
}

/// The parts of an Excel number format code needed to show a value legibly: the kind of value,
/// decimals, thousands separators and literal text such as a currency symbol. Colors, conditions,
/// fractions and exact date layouts aren't reproduced; dates use the system's short format.
struct NumberFormat: Sendable {
    private enum Kind: Sendable { case general, number, percent, scientific, date, time, dateTime, duration }

    static let general = NumberFormat(code: "General")

    /// Formats Excel defines by ID instead of storing them in the file.
    static let builtIn: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 5: "#,##0", 6: "#,##0", 7: "#,##0.00", 8: "#,##0.00",
        9: "0%", 10: "0.00%", 11: "0.00E+00", 12: "General", 13: "General",
        14: "m/d/yy", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM", 19: "h:mm:ss AM/PM",
        20: "h:mm", 21: "h:mm:ss", 22: "m/d/yy h:mm",
        37: "#,##0", 38: "#,##0", 39: "#,##0.00", 40: "#,##0.00",
        45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss", 48: "0.0E+00", 49: "@",
    ]

    private var kind = Kind.general
    private var decimals = 0
    private var grouping = false
    private var showsSeconds = false
    private var prefix = ""
    private var suffix = ""

    init(code: String) {
        let chars = Array(code)
        var literal = ""
        var placeholders = 0
        var afterPoint = false
        var percent = false, scientific = false, duration = false
        var hasDate = false, hasTime = false, hasM = false
        var i = 0
        func next(_ offset: Int = 1) -> Character? { i + offset < chars.count ? chars[i + offset] : nil }

        scan: while i < chars.count {
            let c = chars[i]
            switch c {
            case ";":
                break scan // only the first section (positive numbers) is used
            case "\"":
                while let n = next(), n != "\"" { literal.append(n); i += 1 }
                i += 1
            case "\\":
                if let n = next() { literal.append(n); i += 1 }
            case "_", "*":
                i += 1 // padding and fill characters
            case "[":
                var content = ""
                while let n = next(), n != "]" { content.append(n); i += 1 }
                i += 1
                if content.hasPrefix("$") {
                    literal += content.dropFirst().prefix { $0 != "-" } // [$€-407] → €
                } else if let first = content.lowercased().first, "hms".contains(first) {
                    duration = true
                    hasTime = true
                }
            case "0", "#", "?":
                if placeholders == 0 {
                    prefix = literal
                    literal = ""
                }
                placeholders += 1
                if afterPoint && !scientific { decimals += 1 } // not the exponent's digits
            case ".":
                if placeholders > 0 || next().map({ "0#?".contains($0) }) == true { afterPoint = true } else { literal.append(c) }
            case ",":
                if placeholders > 0 && !afterPoint { grouping = true }
            case "%":
                percent = true
            case "E", "e":
                if let n = next(), n == "+" || n == "-" { scientific = true; i += 1 } else { hasDate = hasDate || c == "e" }
            case "y", "Y", "d", "D":
                hasDate = true
            case "h", "H":
                hasTime = true
            case "s", "S":
                hasTime = true
                showsSeconds = true
            case "m", "M":
                hasM = true
            case "@":
                break
            default:
                let rest = String(chars[i...]).uppercased()
                if rest.hasPrefix("AM/PM") || rest.hasPrefix("A/P") {
                    hasTime = true
                    i += rest.hasPrefix("AM/PM") ? 4 : 2
                } else if rest.hasPrefix("GENERAL") {
                    i += 6
                } else {
                    literal.append(c)
                }
            }
            i += 1
        }

        // "m" is minutes next to hours or seconds, otherwise months.
        let isDate = hasDate || (hasM && !hasTime)
        if duration {
            kind = .duration
        } else if isDate || hasTime {
            kind = isDate && hasTime ? .dateTime : isDate ? .date : .time
        } else if scientific {
            kind = .scientific
        } else if percent {
            kind = .percent
        } else if placeholders > 0 {
            kind = .number
            suffix = literal
        }
        if placeholders == 0 { prefix = "" }
    }

    func string(for value: Double, date1904: Bool) -> String {
        switch kind {
        case .general:
            let style = FloatingPointFormatStyle<Double>.number.precision(.significantDigits(1...11)).grouping(.never)
            return abs(value) >= 1e11 ? value.formatted(style.notation(.scientific)) : value.formatted(style)
        case .number:
            let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(decimals))
                .grouping(grouping ? .automatic : .never)
            let number = abs(value).formatted(style)
            return (value < 0 && number.contains { $0.isNumber && $0 != "0" } ? "-" : "") + prefix + number + suffix
        case .percent:
            return value.formatted(.percent.precision(.fractionLength(decimals)))
        case .scientific:
            return value.formatted(.number.notation(.scientific).precision(.fractionLength(decimals)))
        case .duration:
            // A duration longer than a million days isn't one; also catches NaN and infinity.
            guard value.isFinite, abs(value) < 1_000_000 else { return NumberFormat.general.string(for: value, date1904: false) }
            let seconds = Int((abs(value) * 86400).rounded())
            let hm = "\(seconds / 3600):" + String(format: "%02d", seconds / 60 % 60)
            return (value < 0 ? "-" : "") + (showsSeconds ? hm + String(format: ":%02d", seconds % 60) : hm)
        case .date, .time, .dateTime:
            // Serial day numbers count from 1899-12-30 (or 1904-01-01 for old Mac workbooks).
            guard value >= 0, value < 2_958_466 else { return NumberFormat.general.string(for: value, date1904: false) }
            let date = Date(timeIntervalSince1970: (value - (date1904 ? 24107 : 25569)) * 86400)
            var style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
            if kind != .time { style = style.year().month(.defaultDigits).day() }
            if kind != .date {
                style = style.hour().minute()
                if showsSeconds { style = style.second() }
            }
            return date.formatted(style)
        }
    }
}

/// Calls back for each element of an XML document, with namespace prefixes removed from
/// element names ("x:row" → "row").
final class XMLWalker: NSObject, XMLParserDelegate {
    var didStart: (_ element: String, _ attributes: [String: String]) -> Void = { _, _ in }
    var didEnd: (_ element: String) -> Void = { _ in }
    var foundText: (_ text: String) -> Void = { _ in }
    private var parser: XMLParser?
    private var stopped = false

    /// Returns false if the document isn't well-formed XML. Stopping early isn't a failure.
    @discardableResult
    func parse(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        self.parser = parser
        defer {
            // Releases whatever the handlers captured.
            self.parser = nil
            didStart = { _, _ in }
            didEnd = { _ in }
            foundText = { _ in }
        }
        return parser.parse() || stopped
    }

    func stop() {
        stopped = true
        parser?.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        didStart(Self.localName(elementName), attributeDict)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        didEnd(Self.localName(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        foundText(string)
    }

    private static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }
}
