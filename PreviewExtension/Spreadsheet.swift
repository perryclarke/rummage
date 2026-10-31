import Foundation
import UniformTypeIdentifiers

/// The cell text of a workbook (.xlsx) or a CSV/TSV file, ready to show in a grid.
struct Spreadsheet: Sendable {
    /// Larger sheets are cut off so that previews stay fast.
    static let maxRows = 20_000
    static let maxColumns = 200

    enum Alignment: Sendable { case left, center, right }

    struct Cell: Sendable {
        var text: String
        var alignment = Alignment.left
        var isBold = false
    }

    struct Sheet: Sendable {
        var name: String
        /// Rows hold cells up to their last non-empty column; empty cells are nil.
        var rows: [[Cell?]] = []
        var columnCount = 0
        /// Widths in points, for columns whose width the file specifies.
        var columnWidths: [Int: Double] = [:]
        /// True if rows or columns beyond the limits were left out.
        var isTruncated = false

        /// Sets the cell at zero-based `row` and `column`.
        mutating func set(_ cell: Cell, row: Int, column: Int) {
            guard row < Spreadsheet.maxRows, column < Spreadsheet.maxColumns else {
                isTruncated = true
                return
            }
            if rows.count <= row {
                rows.append(contentsOf: repeatElement([], count: row - rows.count + 1))
            }
            if rows[row].count <= column {
                rows[row].append(contentsOf: repeatElement(nil, count: column - rows[row].count + 1))
            }
            rows[row][column] = cell
            columnCount = max(columnCount, column + 1)
        }
    }

    var sheets: [Sheet]

    static func canRead(_ url: URL) -> Bool {
        switch url.pathExtension.lowercased() {
        case "xlsx", "xlsm", "csv", "tsv", "tab": return true
        default:
            let type = UTType(filenameExtension: url.pathExtension)
            return type?.conforms(to: .commaSeparatedText) == true || type?.conforms(to: .tabSeparatedText) == true
        }
    }

    static func read(_ url: URL) throws -> Spreadsheet {
        switch url.pathExtension.lowercased() {
        case "xlsx", "xlsm": return try XLSXReader.read(url)
        default: return try CSVReader.read(url)
        }
    }

    /// 0 → "A", 25 → "Z", 26 → "AA".
    static func columnName(_ index: Int) -> String {
        var name = ""
        var n = index + 1
        while n > 0 {
            name.insert(Character(Unicode.Scalar(UInt8(65 + (n - 1) % 26))), at: name.startIndex)
            n = (n - 1) / 26
        }
        return name
    }
}

/// Comma-, semicolon- or tab-separated values, following RFC 4180 quoting.
enum CSVReader {
    private static let maxBytes = 16 << 20

    static func read(_ url: URL) throws -> Spreadsheet {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        let isCut = data.count > maxBytes
        if isCut { data = data.prefix(maxBytes) }

        var bytes: [UInt8]
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            // Excel's "Unicode Text" export is UTF-16 with tabs.
            bytes = Array((String(data: data, encoding: .utf16) ?? "").utf8)
        } else {
            bytes = Array(data)
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }

        let ext = url.pathExtension.lowercased()
        let delimiter = ext == "tsv" || ext == "tab" ? UInt8(ascii: "\t") : guessDelimiter(bytes)
        var sheet = Spreadsheet.Sheet(name: url.lastPathComponent)
        parse(bytes, delimiter: delimiter, into: &sheet)
        if isCut {
            // The last row was probably cut in half.
            if !sheet.rows.isEmpty { sheet.rows.removeLast() }
            sheet.isTruncated = true
        }
        return Spreadsheet(sheets: [sheet])
    }

    /// The most common of comma, semicolon (used where the comma is the decimal separator) and tab
    /// in the first line.
    private static func guessDelimiter(_ bytes: [UInt8]) -> UInt8 {
        let firstLine = bytes.prefix { $0 != UInt8(ascii: "\n") }
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t")]
        let counts = candidates.map { c in firstLine.reduce(0) { $1 == c ? $0 + 1 : $0 } }
        return counts.max() == 0 ? candidates[0] : candidates[counts.firstIndex(of: counts.max()!)!]
    }

    private static func parse(_ bytes: [UInt8], delimiter: UInt8, into sheet: inout Spreadsheet.Sheet) {
        let quote = UInt8(ascii: "\""), newline = UInt8(ascii: "\n"), carriageReturn = UInt8(ascii: "\r")
        var field: [UInt8] = []
        var inQuotes = false
        var row = 0
        var column = 0

        func endField() {
            if !field.isEmpty {
                let text = String(decoding: field, as: UTF8.self)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let isNumber = Double(trimmed) != nil && trimmed.contains { $0.isNumber }
                sheet.set(.init(text: text, alignment: isNumber ? .right : .left), row: row, column: column)
            }
            field.removeAll(keepingCapacity: true)
            column += 1
        }

        var i = 0
        while i < bytes.count, row < Spreadsheet.maxRows {
            let byte = bytes[i]
            if inQuotes {
                if byte == quote {
                    if i + 1 < bytes.count, bytes[i + 1] == quote {
                        field.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote, field.isEmpty {
                inQuotes = true
            } else if byte == delimiter {
                endField()
            } else if byte == newline || byte == carriageReturn {
                endField()
                row += 1
                column = 0
                if byte == carriageReturn, i + 1 < bytes.count, bytes[i + 1] == newline { i += 1 }
            } else {
                field.append(byte)
            }
            i += 1
        }
        if row >= Spreadsheet.maxRows {
            sheet.isTruncated = true
        } else {
            endField()
        }
    }
}
