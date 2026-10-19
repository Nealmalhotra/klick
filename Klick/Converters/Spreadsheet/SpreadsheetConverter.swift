import Foundation

/// Spreadsheet targets offered on the spreadsheet wheel (XLS is read-only, like Tangerine).
enum SpreadsheetFormat: String, CaseIterable {
    case xlsx, ods, csv, tsv, pdf

    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }
}

/// One value of a sheet. Dates keep their spreadsheet serial so XLSX/ODS can write them back as real dates.
enum SpreadsheetCell: Equatable {
    enum DateStyle { case date, dateTime, time }

    case empty
    case text(String)
    case number(Double)
    case bool(Bool)
    /// Days since 1899-12-30 (the 1900 date system), fraction = time of day.
    case date(Double, DateStyle)

    var isEmpty: Bool {
        if case .empty = self { return true }
        if case .text(let string) = self { return string.isEmpty }
        return false
    }

    var isText: Bool {
        if case .text = self { return true }
        return false
    }

    /// Plain text as written to CSV/TSV and drawn in the PDF.
    var displayText: String {
        switch self {
        case .empty: return ""
        case .text(let string): return string
        case .number(let value): return SpreadsheetCell.format(value)
        case .bool(let value): return value ? "TRUE" : "FALSE"
        case .date(let serial, let style): return SpreadsheetCell.format(serial: serial, style: style)
        }
    }

    /// `3` rather than `3.0`, and no binary noise (`0.30000000000000004` → `0.3`).
    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        let short = String(format: "%.15g", value)
        return short.contains("e") ? "\(value)" : short
    }

    /// Exact value for XML number attributes (shortest form that round-trips).
    static func xmlNumber(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return "\(value)"
    }

    private static let epoch: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 1899, month: 12, day: 30))!
    }()

    /// Splits a serial into calendar fields (UTC, so no daylight-saving surprises).
    static func components(serial: Double) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let seconds = (serial * 86_400).rounded()
        let date = epoch.addingTimeInterval(seconds)
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    /// Inverse of `components(serial:)`.
    static func serial(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Double = 0) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let seconds = date.timeIntervalSince(epoch) + Double(hour * 3600 + minute * 60) + second
        return seconds / 86_400
    }

    /// ISO-like text: `2024-01-15`, `2024-01-15 13:45`, `13:45:10`.
    static func format(serial: Double, style: DateStyle) -> String {
        let c = components(serial: serial)
        let date = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let seconds = c.second ?? 0
        let time = seconds == 0 && style == .dateTime
            ? String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            : String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, seconds)
        switch style {
        case .date: return date
        case .dateTime: return "\(date) \(time)"
        case .time: return time
        }
    }
}

struct SpreadsheetSheet {
    var name: String
    var rows: [[SpreadsheetCell]]

    var columnCount: Int { rows.map(\.count).max() ?? 0 }
    var isEmpty: Bool { rows.allSatisfy { $0.allSatisfy(\.isEmpty) } }

    /// Drops trailing empty cells and rows (ODS and XLSX files often carry thousands of styled blanks).
    mutating func trim() {
        for index in rows.indices {
            while let last = rows[index].last, last.isEmpty { rows[index].removeLast() }
        }
        while let last = rows.last, last.isEmpty { rows.removeLast() }
    }

    /// Whether the first row looks like column titles: only text, with something below it.
    var hasHeaderRow: Bool {
        guard rows.count > 1, let first = rows.first, first.contains(where: { !$0.isEmpty }) else { return false }
        return first.allSatisfy { $0.isEmpty || $0.isText }
    }
}

struct SpreadsheetWorkbook {
    var sheets: [SpreadsheetSheet]
}

/// Spreadsheet conversions between XLSX, XLS (read only), ODS, CSV and TSV, plus a paginated PDF table.
/// Everything is read and written natively; XLSX/ODS go through `ZipPackage`.
enum SpreadsheetConverter {
    /// Numbers documents are protobuf archives Klick can't read, so they get no convert page.
    static func canRead(_ item: FileItem) -> Bool {
        ["csv", "tsv", "xlsx", "xlsm", "xls", "ods"].contains(item.ext)
    }

    /// `Budget.xlsx` → `Budget.csv`. Multi-sheet workbooks become one CSV/TSV per sheet
    /// (`Budget - Sheet2.csv`); XLSX, ODS and PDF keep every sheet in one file.
    static func convert(_ item: FileItem, to format: SpreadsheetFormat, progress: JobProgress) async throws -> [URL] {
        progress.report(0.05)
        var workbook = try read(item)
        for index in workbook.sheets.indices { workbook.sheets[index].trim() }
        let sheets = workbook.sheets.filter { !$0.isEmpty }
        guard !sheets.isEmpty else { throw KlickError.failed("\(item.name) has no data") }
        workbook.sheets = sheets
        try progress.checkCancelled()
        progress.report(0.4)

        var outputs: [URL] = []
        switch format {
        case .csv, .tsv:
            let delimiter: UInt8 = format == .csv ? UInt8(ascii: ",") : UInt8(ascii: "\t")
            for sheet in sheets {
                let name = sheets.count == 1 ? item.baseName : "\(item.baseName) - \(fileSafe(sheet.name))"
                let output = OutputNaming.url(named: name, ext: format.ext, in: item.directory)
                try write { try SpreadsheetCSV.write(sheet, delimiter: delimiter, to: output) }
                outputs.append(output)
            }
        case .xlsx:
            let output = OutputNaming.url(for: item.url, ext: format.ext)
            try write { try SpreadsheetXLSX.write(workbook, to: output) }
            outputs.append(output)
        case .ods:
            let output = OutputNaming.url(for: item.url, ext: format.ext)
            try write { try SpreadsheetODS.write(workbook, to: output) }
            outputs.append(output)
        case .pdf:
            let output = OutputNaming.url(for: item.url, ext: format.ext)
            do {
                try SpreadsheetPDF.write(workbook, title: item.baseName, to: output, progress: progress)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
            outputs.append(output)
        }
        progress.report(1)
        return outputs
    }

    static func read(_ item: FileItem) throws -> SpreadsheetWorkbook {
        switch item.ext {
        case "csv":
            return SpreadsheetWorkbook(sheets: [try SpreadsheetCSV.read(item.url, delimiter: nil)])
        case "tsv":
            return SpreadsheetWorkbook(sheets: [try SpreadsheetCSV.read(item.url, delimiter: UInt8(ascii: "\t"))])
        case "xlsx", "xlsm":
            return try SpreadsheetXLSX.read(item.url)
        case "xls":
            return try SpreadsheetXLS.read(item.url)
        case "ods":
            return try SpreadsheetODS.read(item.url)
        default:
            throw KlickError.unsupported("Reading .\(item.ext) files")
        }
    }

    /// Wraps writer errors into a readable message.
    private static func write(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let error as KlickError {
            throw error
        } catch {
            throw KlickError.failed("Couldn't write the spreadsheet")
        }
    }

    private static func fileSafe(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Sheet" : cleaned
    }
}

/// Small XML helpers shared by the spreadsheet readers/writers (namespace prefixes vary between producers,
/// so lookups go by local name).
enum SpreadsheetXML {
    static func document(_ data: Data) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        } catch {
            throw KlickError.failed("The spreadsheet is damaged")
        }
    }

    static func elements(_ node: XMLNode?) -> [XMLElement] {
        (node?.children ?? []).compactMap { $0 as? XMLElement }
    }

    static func child(_ node: XMLNode?, _ localName: String) -> XMLElement? {
        elements(node).first { $0.localName == localName }
    }

    static func children(_ node: XMLNode?, _ localName: String) -> [XMLElement] {
        elements(node).filter { $0.localName == localName }
    }

    /// First descendant (depth first) with that local name.
    static func descendant(_ node: XMLNode?, _ localName: String) -> XMLElement? {
        for element in elements(node) {
            if element.localName == localName { return element }
            if let found = descendant(element, localName) { return found }
        }
        return nil
    }

    /// Attribute by local name, preferring `prefix:` when several namespaces define it.
    static func attribute(_ element: XMLElement, _ localName: String, prefix: String? = nil) -> String? {
        if let prefix, let value = element.attribute(forName: "\(prefix):\(localName)")?.stringValue { return value }
        if let value = element.attribute(forName: localName)?.stringValue { return value }
        return element.attributes?.first { $0.localName == localName }?.stringValue
    }

    /// Escapes text for element content/attributes, dropping characters XML 1.0 can't carry.
    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.utf8.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            default:
                let value = scalar.value
                if value < 0x20 || value == 0xFFFE || value == 0xFFFF { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Unique sheet names (Excel limits: 31 characters, no `[]:*?/\`).
    static func sheetNames(_ sheets: [SpreadsheetSheet]) -> [String] {
        var used = Set<String>()
        return sheets.enumerated().map { index, sheet in
            var name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "' "))
            if name.isEmpty { name = "Sheet\(index + 1)" }
            var candidate = name
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " \(counter)"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    /// Rough column width in characters, from the longest value in the first rows.
    static func columnWidths(_ sheet: SpreadsheetSheet) -> [Int] {
        var widths = Array(repeating: 0, count: sheet.columnCount)
        for row in sheet.rows.prefix(2000) {
            for (column, cell) in row.enumerated() {
                let longest = cell.displayText.split(separator: "\n").map(\.count).max() ?? 0
                widths[column] = max(widths[column], longest)
            }
        }
        return widths.map { min(max($0 + 2, 9), 60) }
    }
}
