import Foundation

/// RFC 4180 CSV/TSV: quoted fields with embedded delimiters, quotes and line breaks, any line ending,
/// UTF-8/UTF-16 BOMs, legacy Windows-1252 files and delimiter detection (`,` `;` tab `|`).
enum SpreadsheetCSV {
    private static let quote = UInt8(ascii: "\"")
    private static let cr = UInt8(ascii: "\r")
    private static let lf = UInt8(ascii: "\n")

    /// - Parameter delimiter: nil to detect it from the first lines.
    static func read(_ url: URL, delimiter: UInt8?) throws -> SpreadsheetSheet {
        guard let data = try? Data(contentsOf: url), let text = decode(data) else {
            throw KlickError.unreadable(url.lastPathComponent)
        }
        let bytes = Array(text.utf8)
        let separator = delimiter ?? detectDelimiter(bytes)
        let rows = parse(bytes, delimiter: separator).map { $0.map(typedCell) }
        return SpreadsheetSheet(name: url.deletingPathExtension().lastPathComponent, rows: rows)
    }

    /// Text in the file's encoding, BOM removed.
    static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    static func parse(_ bytes: [UInt8], delimiter: UInt8) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var quoted = false   // the current field started with a quote
        var inQuotes = false
        var index = 0

        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            quoted = false
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < bytes.count, bytes[index + 1] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote && field.isEmpty && !quoted {
                inQuotes = true
                quoted = true
            } else if byte == delimiter {
                endField()
            } else if byte == cr || byte == lf {
                endRow()
                if byte == cr, index + 1 < bytes.count, bytes[index + 1] == lf { index += 1 }
            } else {
                field.append(byte) // stray quotes inside unquoted fields are kept literally
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty || quoted { endRow() }
        return rows
    }

    /// Picks the candidate that splits the first lines into the most consistent number (> 1) of columns.
    static func detectDelimiter(_ bytes: [UInt8]) -> UInt8 {
        let sample = Array(bytes.prefix(64 * 1024))
        let candidates: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: ";"), UInt8(ascii: "\t"), UInt8(ascii: "|")]
        var best: (delimiter: UInt8, score: Double) = (candidates[0], 0)
        for candidate in candidates {
            var rows = parse(sample, delimiter: candidate)
            if sample.count < bytes.count, rows.count > 1 { rows.removeLast() } // possibly cut in half
            let counts = rows.prefix(200).map(\.count).filter { $0 > 0 }
            guard !counts.isEmpty else { continue }
            let frequency = Dictionary(counts.map { ($0, 1) }, uniquingKeysWith: +)
            guard let (mode, hits) = frequency.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }),
                  mode > 1 else { continue }
            // Consistency first, then more columns.
            let score = Double(hits) / Double(counts.count) * 1000 + Double(min(mode, 999))
            if score > best.score { best = (candidate, score) }
        }
        return best.delimiter
    }

    /// Numbers become numbers (so XLSX/ODS can sum them); IDs like `007` or 16-digit codes stay text.
    static func typedCell(_ value: String) -> SpreadsheetCell {
        if value.isEmpty { return .empty }
        let bytes = Array(value.utf8)
        var index = 0
        if bytes[0] == UInt8(ascii: "-") { index = 1 }
        let integerStart = index
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
        let integerDigits = index - integerStart
        guard integerDigits > 0 else { return .text(value) }
        if integerDigits > 1 && bytes[integerStart] == UInt8(ascii: "0") { return .text(value) }
        var fractionDigits = 0
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { index += 1 }
            fractionDigits = index - fractionStart
            guard fractionDigits > 0 else { return .text(value) }
        }
        guard index == bytes.count, integerDigits + fractionDigits <= 15, let number = Double(value) else {
            return .text(value)
        }
        return .number(number)
    }

    /// Writes a rectangular table. CSV gets CRLF line endings (RFC 4180) and a UTF-8 BOM when the text
    /// isn't plain ASCII, so Excel picks the right encoding; TSV uses LF.
    static func write(_ sheet: SpreadsheetSheet, delimiter: UInt8, to url: URL) throws {
        let separator = String(UnicodeScalar(delimiter))
        let newline = delimiter == UInt8(ascii: "\t") ? "\n" : "\r\n"
        let columns = sheet.columnCount
        var output = ""
        for row in sheet.rows {
            var fields = row.map { escape($0.displayText, delimiter: separator) }
            if fields.count < columns { fields += Array(repeating: "", count: columns - fields.count) }
            output += fields.joined(separator: separator)
            output += newline
        }
        var data = Data()
        if delimiter != UInt8(ascii: "\t"), output.utf8.contains(where: { $0 >= 0x80 }) {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(Data(output.utf8))
        try data.write(to: url, options: .atomic)
    }

    private static func escape(_ value: String, delimiter: String) -> String {
        let special = Set((delimiter + "\"\r\n").unicodeScalars)
        let needsQuotes = value.unicodeScalars.contains { special.contains($0) }
            || value.first == " " || value.last == " "
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
