import Foundation

/// OpenDocument spreadsheets (LibreOffice, Google Sheets, Numbers export): values from `content.xml`,
/// written back as a package with the uncompressed `mimetype` entry first.
enum SpreadsheetODS {
    private static let mimeType = "application/vnd.oasis.opendocument.spreadsheet"

    // MARK: - Reading

    static func read(_ url: URL) throws -> SpreadsheetWorkbook {
        guard let data = ZipPackage.read("content.xml", from: url) else { throw KlickError.unreadable(url.lastPathComponent) }
        let document = try SpreadsheetXML.document(data)
        guard let spreadsheet = SpreadsheetXML.descendant(document.rootElement(), "spreadsheet") else {
            throw KlickError.unreadable(url.lastPathComponent)
        }
        let sheets = SpreadsheetXML.children(spreadsheet, "table").enumerated().map { index, table in
            SpreadsheetSheet(
                name: SpreadsheetXML.attribute(table, "name", prefix: "table") ?? "Sheet\(index + 1)",
                rows: rows(of: table)
            )
        }
        guard !sheets.isEmpty else { throw KlickError.unreadable(url.lastPathComponent) }
        return SpreadsheetWorkbook(sheets: sheets)
    }

    /// Rows and cells may be "repeated" thousands of times to fill the grid; empty runs are only
    /// materialized when real content follows them.
    private static func rows(of table: XMLElement) -> [[SpreadsheetCell]] {
        var rows: [[SpreadsheetCell]] = []
        var pendingEmptyRows = 0

        func visit(_ container: XMLElement) {
            for element in SpreadsheetXML.elements(container) {
                switch element.localName {
                case "table-row":
                    let repeated = max(SpreadsheetXML.attribute(element, "number-rows-repeated", prefix: "table").flatMap(Int.init) ?? 1, 1)
                    let row = cells(of: element)
                    if row.isEmpty {
                        pendingEmptyRows += repeated
                    } else {
                        rows += Array(repeating: [], count: pendingEmptyRows)
                        pendingEmptyRows = 0
                        rows += Array(repeating: row, count: min(repeated, 10_000))
                    }
                case "table-header-rows", "table-row-group", "table-rows":
                    visit(element)
                default:
                    break
                }
            }
        }
        visit(table)
        return rows
    }

    private static func cells(of row: XMLElement) -> [SpreadsheetCell] {
        var cells: [SpreadsheetCell] = []
        var pendingEmpty = 0
        for element in SpreadsheetXML.elements(row) where element.localName == "table-cell" || element.localName == "covered-table-cell" {
            let repeated = max(SpreadsheetXML.attribute(element, "number-columns-repeated", prefix: "table").flatMap(Int.init) ?? 1, 1)
            let cell = value(of: element)
            if cell.isEmpty {
                pendingEmpty += repeated
            } else {
                cells += Array(repeating: .empty, count: pendingEmpty)
                pendingEmpty = 0
                cells += Array(repeating: cell, count: min(repeated, 1024))
            }
        }
        return cells
    }

    private static func value(of cell: XMLElement) -> SpreadsheetCell {
        let type = SpreadsheetXML.attribute(cell, "value-type", prefix: "office") ?? ""
        switch type {
        case "float", "percentage", "currency":
            if let number = SpreadsheetXML.attribute(cell, "value", prefix: "office").flatMap(Double.init) { return .number(number) }
        case "boolean":
            if let flag = SpreadsheetXML.attribute(cell, "boolean-value", prefix: "office") { return .bool(flag == "true") }
        case "date":
            if let date = SpreadsheetXML.attribute(cell, "date-value", prefix: "office"), let parsed = parseDate(date) { return parsed }
        case "time":
            if let time = SpreadsheetXML.attribute(cell, "time-value", prefix: "office"), let serial = parseDuration(time) {
                return .date(serial, .time)
            }
        default:
            break
        }
        let paragraphs = SpreadsheetXML.children(cell, "p").map(text)
        return paragraphs.isEmpty ? .empty : .text(paragraphs.joined(separator: "\n"))
    }

    /// Paragraph text with `<text:s c="3"/>` spaces, tabs, line breaks and nested spans; comments are skipped.
    private static func text(_ node: XMLNode) -> String {
        var result = ""
        for child in node.children ?? [] {
            if child.kind == .text {
                result += child.stringValue ?? ""
                continue
            }
            guard let element = child as? XMLElement else { continue }
            switch element.localName {
            case "s":
                let count = SpreadsheetXML.attribute(element, "c", prefix: "text").flatMap(Int.init) ?? 1
                result += String(repeating: " ", count: max(count, 1))
            case "tab": result += "\t"
            case "line-break": result += "\n"
            case "annotation", "note": break
            default: result += text(element)
            }
        }
        return result
    }

    /// `2024-01-15` or `2024-01-15T13:45:00(.5)`.
    private static func parseDate(_ string: String) -> SpreadsheetCell? {
        let parts = string.split(separator: "T", maxSplits: 1)
        let date = parts[0].split(separator: "-").compactMap { Int($0) }
        guard date.count == 3 else { return nil }
        var hour = 0, minute = 0, second = 0.0
        if parts.count == 2 {
            let time = parts[1].split(separator: ":")
            hour = time.count > 0 ? Int(time[0]) ?? 0 : 0
            minute = time.count > 1 ? Int(time[1]) ?? 0 : 0
            second = time.count > 2 ? Double(time[2].prefix { $0.isNumber || $0 == "." }) ?? 0 : 0
        }
        guard let serial = SpreadsheetCell.serial(year: date[0], month: date[1], day: date[2], hour: hour, minute: minute, second: second) else {
            return nil
        }
        return .date(serial, parts.count == 2 && (hour, minute, second) != (0, 0, 0) ? .dateTime : .date)
    }

    /// ISO 8601 duration `PT13H45M10S` → fraction of a day.
    private static func parseDuration(_ string: String) -> Double? {
        guard string.hasPrefix("PT") || string.hasPrefix("P") else { return nil }
        var seconds = 0.0
        var number = ""
        var inTime = false
        for character in string.dropFirst() {
            switch character {
            case "T": inTime = true
            case "D": seconds += (Double(number) ?? 0) * 86_400; number = ""
            case "H": seconds += (Double(number) ?? 0) * 3600; number = ""
            case "M" where inTime: seconds += (Double(number) ?? 0) * 60; number = ""
            case "S": seconds += Double(number) ?? 0; number = ""
            default: number.append(character)
            }
        }
        return seconds / 86_400
    }

    // MARK: - Writing

    static func write(_ workbook: SpreadsheetWorkbook, to url: URL) throws {
        let names = SpreadsheetXML.sheetNames(workbook.sheets)
        let header = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
        let namespaces = [
            #"xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0""#,
            #"xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0""#,
            #"xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0""#,
            #"xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0""#,
            #"xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0""#,
            #"xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0""#,
            #"xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0""#,
        ].joined(separator: " ")

        // One column style per distinct width (1 character ≈ 0.19 cm).
        var columnStyles: [Int: String] = [:]
        var tables = ""
        for (index, sheet) in workbook.sheets.enumerated() {
            tables += #"<table:table table:name="\#(SpreadsheetXML.escape(names[index]))">"#
            for width in SpreadsheetXML.columnWidths(sheet) {
                let style = columnStyles[width] ?? "co\(columnStyles.count + 1)"
                columnStyles[width] = style
                tables += #"<table:table-column table:style-name="\#(style)" table:default-cell-style-name="Default"/>"#
            }
            let bold = sheet.hasHeaderRow
            for (rowIndex, row) in sheet.rows.enumerated() {
                tables += "<table:table-row>"
                for cell in row {
                    tables += self.cell(cell, bold: bold && rowIndex == 0)
                }
                if row.isEmpty { tables += "<table:table-cell/>" }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }

        let columnStyleXML = columnStyles.sorted { $0.value.count == $1.value.count ? $0.value < $1.value : $0.value.count < $1.value.count }
            .map { width, name in
                let centimeters = String(format: "%.3fcm", Double(width) * 0.19)
                return #"<style:style style:name="\#(name)" style:family="table-column"><style:table-column-properties style:column-width="\#(centimeters)"/></style:style>"#
            }.joined()

        let content = header + """
        <office:document-content \(namespaces) office:version="1.2">\
        <office:automatic-styles>\
        <number:date-style style:name="N1"><number:year number:style="long"/><number:text>-</number:text>\
        <number:month number:style="long"/><number:text>-</number:text><number:day number:style="long"/></number:date-style>\
        <number:date-style style:name="N2"><number:year number:style="long"/><number:text>-</number:text>\
        <number:month number:style="long"/><number:text>-</number:text><number:day number:style="long"/>\
        <number:text> </number:text><number:hours number:style="long"/><number:text>:</number:text>\
        <number:minutes number:style="long"/></number:date-style>\
        <number:time-style style:name="N3"><number:hours number:style="long"/><number:text>:</number:text>\
        <number:minutes number:style="long"/><number:text>:</number:text><number:seconds number:style="long"/></number:time-style>\
        \(columnStyleXML)\
        <style:style style:name="ce1" style:family="table-cell" style:parent-style-name="Default">\
        <style:text-properties fo:font-weight="bold" style:font-weight-asian="bold" style:font-weight-complex="bold"/></style:style>\
        <style:style style:name="ce2" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N1"/>\
        <style:style style:name="ce3" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N2"/>\
        <style:style style:name="ce4" style:family="table-cell" style:parent-style-name="Default" style:data-style-name="N3"/>\
        </office:automatic-styles>\
        <office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
        """

        let styles = header + """
        <office:document-styles \(namespaces) office:version="1.2"><office:styles>\
        <style:style style:name="Default" style:family="table-cell"/></office:styles></office:document-styles>
        """
        let meta = header + """
        <office:document-meta \(namespaces) office:version="1.2"><office:meta><meta:generator>Klick</meta:generator></office:meta></office:document-meta>
        """
        let manifest = header + """
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
        <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="\(mimeType)"/>\
        <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
        <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>\
        <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>\
        </manifest:manifest>
        """

        try ZipPackage.write([
            "mimetype": Data(mimeType.utf8),
            "content.xml": Data(content.utf8),
            "styles.xml": Data(styles.utf8),
            "meta.xml": Data(meta.utf8),
            "META-INF/manifest.xml": Data(manifest.utf8),
        ], to: url, storedFirst: "mimetype")
    }

    private static func cell(_ cell: SpreadsheetCell, bold: Bool) -> String {
        let style = bold ? #" table:style-name="ce1""# : ""
        switch cell {
        case .empty:
            return "<table:table-cell/>"
        case .text(let string):
            return #"<table:table-cell\#(style) office:value-type="string">\#(paragraphs(string))</table:table-cell>"#
        case .number(let value):
            let number = SpreadsheetCell.xmlNumber(value)
            return #"<table:table-cell\#(style) office:value-type="float" office:value="\#(number)"><text:p>\#(SpreadsheetCell.format(value))</text:p></table:table-cell>"#
        case .bool(let value):
            return #"<table:table-cell\#(style) office:value-type="boolean" office:boolean-value="\#(value)"><text:p>\#(value ? "TRUE" : "FALSE")</text:p></table:table-cell>"#
        case .date(let serial, let kind):
            let display = SpreadsheetXML.escape(cell.displayText)
            let c = SpreadsheetCell.components(serial: serial)
            switch kind {
            case .time:
                let value = String(format: "PT%02dH%02dM%02dS", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
                return #"<table:table-cell table:style-name="ce4" office:value-type="time" office:time-value="\#(value)"><text:p>\#(display)</text:p></table:table-cell>"#
            case .date, .dateTime:
                var value = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
                if kind == .dateTime { value += String(format: "T%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0) }
                let style = kind == .date ? "ce2" : "ce3"
                return #"<table:table-cell table:style-name="\#(style)" office:value-type="date" office:date-value="\#(value)"><text:p>\#(display)</text:p></table:table-cell>"#
            }
        }
    }

    /// One `<text:p>` per line; runs of spaces and tabs use ODF's `<text:s/>` / `<text:tab/>`.
    private static func paragraphs(_ string: String) -> String {
        string.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: CharacterSet.newlines).map { line in
            if !line.contains("  "), !line.contains("\t"), line.first != " " {
                return "<text:p>" + SpreadsheetXML.escape(line) + "</text:p>"
            }
            var xml = "<text:p>"
            var spaces = 0
            func flushSpaces() {
                guard spaces > 0 else { return }
                // A single space between words is plain text; leading or repeated spaces collapse in XML.
                if spaces == 1 && !xml.hasSuffix("<text:p>") { xml += " " } else {
                    xml += spaces == 1 ? "<text:s/>" : #"<text:s text:c="\#(spaces)"/>"#
                }
                spaces = 0
            }
            for character in line {
                switch character {
                case " ": spaces += 1
                case "\t": flushSpaces(); xml += "<text:tab/>"
                default: flushSpaces(); xml += SpreadsheetXML.escape(String(character))
                }
            }
            flushSpaces()
            return xml + "</text:p>"
        }.joined()
    }
}
