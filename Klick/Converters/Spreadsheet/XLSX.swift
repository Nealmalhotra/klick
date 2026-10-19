import Foundation

/// Office Open XML workbooks: reads values (shared/inline strings, numbers, booleans, dates by number
/// format, cached formula results) from every worksheet; writes a minimal, valid package that Excel,
/// Numbers and Quick Look open.
enum SpreadsheetXLSX {
    // MARK: - Reading

    static func read(_ url: URL) throws -> SpreadsheetWorkbook {
        let folder = try ZipPackage.extract(url)
        defer { try? FileManager.default.removeItem(at: folder) }
        func load(_ path: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent(path)) }

        guard let workbookData = load("xl/workbook.xml") else { throw KlickError.unreadable(url.lastPathComponent) }
        let workbook = try SpreadsheetXML.document(workbookData)
        let relationships = load("xl/_rels/workbook.xml.rels").flatMap { try? SpreadsheetXML.document($0) }
        var targets: [String: String] = [:]
        var sharedStringsPath = "xl/sharedStrings.xml"
        var stylesPath = "xl/styles.xml"
        for relationship in SpreadsheetXML.children(relationships?.rootElement(), "Relationship") {
            guard let id = SpreadsheetXML.attribute(relationship, "Id"),
                  let target = SpreadsheetXML.attribute(relationship, "Target") else { continue }
            let path = resolve(target)
            targets[id] = path
            let type = SpreadsheetXML.attribute(relationship, "Type") ?? ""
            if type.hasSuffix("/sharedStrings") { sharedStringsPath = path }
            if type.hasSuffix("/styles") { stylesPath = path }
        }

        let root = workbook.rootElement()
        let properties = SpreadsheetXML.child(root, "workbookPr")
        let date1904 = properties.flatMap { SpreadsheetXML.attribute($0, "date1904") }.map { $0 == "1" || $0 == "true" } ?? false
        let strings = load(sharedStringsPath).map(sharedStrings) ?? []
        let dateStyles = load(stylesPath).map(dateStyles) ?? [:]

        var sheets: [SpreadsheetSheet] = []
        for (index, sheet) in SpreadsheetXML.children(SpreadsheetXML.child(root, "sheets"), "sheet").enumerated() {
            let name = SpreadsheetXML.attribute(sheet, "name") ?? "Sheet\(index + 1)"
            let path = SpreadsheetXML.attribute(sheet, "id", prefix: "r").flatMap { targets[$0] }
                ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let data = load(path), let document = try? SpreadsheetXML.document(data) else { continue }
            let rows = cells(document, strings: strings, dateStyles: dateStyles, date1904: date1904)
            sheets.append(SpreadsheetSheet(name: name, rows: rows))
        }
        guard !sheets.isEmpty else { throw KlickError.unreadable(url.lastPathComponent) }
        return SpreadsheetWorkbook(sheets: sheets)
    }

    /// Relationship targets are relative to `xl/` unless absolute.
    private static func resolve(_ target: String) -> String {
        var parts = target.hasPrefix("/") ? [] : ["xl"]
        for component in target.split(separator: "/") {
            if component == ".." { _ = parts.popLast() } else if component != "." { parts.append(String(component)) }
        }
        return parts.joined(separator: "/")
    }

    private static func sharedStrings(_ data: Data) -> [String] {
        guard let document = try? SpreadsheetXML.document(data) else { return [] }
        return SpreadsheetXML.children(document.rootElement(), "si").map(text)
    }

    /// Text of a string item (`<t>` or rich-text runs), skipping phonetic hints.
    private static func text(_ element: XMLElement) -> String {
        var result = ""
        for child in SpreadsheetXML.elements(element) {
            switch child.localName {
            case "t": result += child.stringValue ?? ""
            case "r": result += text(child)
            default: break // rPh, phoneticPr
            }
        }
        return decodeEscapes(result)
    }

    /// OOXML encodes control characters as `_x000D_`.
    private static func decodeEscapes(_ string: String) -> String {
        guard string.contains("_x") else { return string }
        var result = ""
        var rest = Substring(string)
        while let range = rest.range(of: "_x") {
            result += rest[..<range.lowerBound]
            let hex = rest[range.upperBound...].prefix(5)
            if hex.count == 5, hex.last == "_", let code = UInt32(hex.dropLast(), radix: 16), let scalar = UnicodeScalar(code) {
                result.unicodeScalars.append(scalar)
                rest = rest[rest.index(range.upperBound, offsetBy: 5)...]
            } else {
                result += "_x"
                rest = rest[range.upperBound...]
            }
        }
        return result + rest
    }

    /// Cell style index → date style, for styles whose number format shows a date or time.
    private static func dateStyles(_ data: Data) -> [Int: SpreadsheetCell.DateStyle] {
        guard let document = try? SpreadsheetXML.document(data) else { return [:] }
        let root = document.rootElement()
        var custom: [Int: String] = [:]
        for format in SpreadsheetXML.children(SpreadsheetXML.child(root, "numFmts"), "numFmt") {
            if let id = SpreadsheetXML.attribute(format, "numFmtId").flatMap(Int.init),
               let code = SpreadsheetXML.attribute(format, "formatCode") {
                custom[id] = code
            }
        }
        var styles: [Int: SpreadsheetCell.DateStyle] = [:]
        for (index, xf) in SpreadsheetXML.children(SpreadsheetXML.child(root, "cellXfs"), "xf").enumerated() {
            let id = SpreadsheetXML.attribute(xf, "numFmtId").flatMap(Int.init) ?? 0
            if let style = dateStyle(formatID: id, code: custom[id]) { styles[index] = style }
        }
        return styles
    }

    /// Built-in date formats plus a scan of custom format codes (shared with XLS).
    static func dateStyle(formatID id: Int, code: String?) -> SpreadsheetCell.DateStyle? {
        switch id {
        case 14...17, 27...31, 34...36, 50...58: return .date
        case 22: return .dateTime
        case 18...21, 32, 33, 45...47: return .time
        default: break
        }
        guard let code else { return nil }
        // Ignore quoted text, escapes and [colour]/[$-locale] sections, then look for date/time letters.
        var plain = ""
        var inQuotes = false
        var inBrackets = false
        var escaped = false
        for character in code.lowercased() {
            if escaped { escaped = false; continue }
            switch character {
            case "\"": inQuotes.toggle()
            case "\\": escaped = !inQuotes
            case "[" where !inQuotes: inBrackets = true
            case "]" where !inQuotes: inBrackets = false
            default: if !inQuotes && !inBrackets { plain.append(character) }
            }
        }
        plain = plain.split(separator: ";").first.map(String.init) ?? ""
        let hasDate = plain.contains("y") || plain.contains("d") || (plain.contains("m") && !plain.contains("h") && !plain.contains("s"))
        let hasTime = plain.contains("h") || plain.contains("s")
        if hasDate { return hasTime ? .dateTime : .date }
        return hasTime ? .time : nil
    }

    private static func cells(
        _ document: XMLDocument, strings: [String], dateStyles: [Int: SpreadsheetCell.DateStyle], date1904: Bool
    ) -> [[SpreadsheetCell]] {
        var rows: [[SpreadsheetCell]] = []
        let data = SpreadsheetXML.child(document.rootElement(), "sheetData")
        var nextRow = 0
        for row in SpreadsheetXML.children(data, "row") {
            let rowIndex = SpreadsheetXML.attribute(row, "r").flatMap(Int.init).map { $0 - 1 } ?? nextRow
            nextRow = rowIndex + 1
            guard rowIndex >= 0, rowIndex < 1_048_576 else { continue }
            var values: [SpreadsheetCell] = []
            for cell in SpreadsheetXML.children(row, "c") {
                let column = SpreadsheetXML.attribute(cell, "r").flatMap(columnIndex) ?? values.count
                guard column < 16_384 else { continue }
                let value = self.value(cell, strings: strings, dateStyles: dateStyles, date1904: date1904)
                guard !value.isEmpty else { continue }
                if values.count <= column { values += Array(repeating: .empty, count: column + 1 - values.count) }
                values[column] = value
            }
            guard !values.isEmpty else { continue }
            if rows.count <= rowIndex { rows += Array(repeating: [], count: rowIndex + 1 - rows.count) }
            rows[rowIndex] = values
        }
        return rows
    }

    private static func value(
        _ cell: XMLElement, strings: [String], dateStyles: [Int: SpreadsheetCell.DateStyle], date1904: Bool
    ) -> SpreadsheetCell {
        let type = SpreadsheetXML.attribute(cell, "t") ?? "n"
        if type == "inlineStr" {
            return SpreadsheetXML.child(cell, "is").map { .text(text($0)) } ?? .empty
        }
        guard let raw = SpreadsheetXML.child(cell, "v")?.stringValue else { return .empty }
        switch type {
        case "s":
            guard let index = Int(raw.trimmingCharacters(in: .whitespaces)), strings.indices.contains(index) else { return .empty }
            return .text(strings[index])
        case "b":
            return .bool(raw.trimmingCharacters(in: .whitespaces) == "1")
        case "str", "e", "d":
            return .text(decodeEscapes(raw))
        default:
            guard let number = Double(raw.trimmingCharacters(in: .whitespaces)) else { return .text(raw) }
            let style = SpreadsheetXML.attribute(cell, "s").flatMap(Int.init) ?? 0
            if let dateStyle = dateStyles[style], number >= 0 {
                return .date(date1904 ? number + 1462 : number, dateStyle)
            }
            return .number(number)
        }
    }

    /// `"BC12"` → 54 (0-based column).
    static func columnIndex(_ reference: String) -> Int? {
        var column = 0
        var sawLetter = false
        for scalar in reference.unicodeScalars {
            let value = Int(scalar.value)
            switch value {
            case 65...90: column = column * 26 + value - 64; sawLetter = true
            case 97...122: column = column * 26 + value - 96; sawLetter = true
            default:
                return sawLetter ? column - 1 : nil
            }
        }
        return sawLetter ? column - 1 : nil
    }

    /// 0 → `A`, 27 → `AB`.
    static func columnName(_ index: Int) -> String {
        var name = ""
        var value = index + 1
        while value > 0 {
            let remainder = (value - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            value = (value - 1) / 26
        }
        return name
    }

    // MARK: - Writing

    /// Cell style indices in `styles.xml` below.
    private enum Style: Int { case normal = 0, bold, date, dateTime, time }

    static func write(_ workbook: SpreadsheetWorkbook, to url: URL) throws {
        var strings: [String] = []
        var stringIndex: [String: Int] = [:]
        func shared(_ string: String) -> Int {
            if let index = stringIndex[string] { return index }
            strings.append(string)
            stringIndex[string] = strings.count - 1
            return strings.count - 1
        }

        let names = SpreadsheetXML.sheetNames(workbook.sheets)
        var entries: [String: Data] = [:]
        for (index, sheet) in workbook.sheets.enumerated() {
            entries["xl/worksheets/sheet\(index + 1).xml"] = Data(worksheet(sheet, shared: shared).utf8)
        }

        let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let relationshipNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let sheetIndices = workbook.sheets.indices

        entries["[Content_Types].xml"] = Data((header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        \(sheetIndices.map { #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined())\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        <Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """).utf8)

        entries["_rels/.rels"] = Data((header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(relationshipNS)/officeDocument" Target="xl/workbook.xml"/>\
        <Relationship Id="rId2" Type="\(relationshipNS)/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """).utf8)

        entries["docProps/app.xml"] = Data((header + """
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Klick</Application></Properties>
        """).utf8)

        entries["xl/workbook.xml"] = Data((header + """
        <workbook xmlns="\(main)" xmlns:r="\(relationshipNS)">\
        <bookViews><workbookView activeTab="0"/></bookViews><sheets>\
        \(sheetIndices.map { #"<sheet name="\#(SpreadsheetXML.escape(names[$0]))" sheetId="\#($0 + 1)" r:id="rId\#($0 + 1)"/>"# }.joined())\
        </sheets></workbook>
        """).utf8)

        let count = workbook.sheets.count
        entries["xl/_rels/workbook.xml.rels"] = Data((header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        \(sheetIndices.map { #"<Relationship Id="rId\#($0 + 1)" Type="\#(relationshipNS)/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"# }.joined())\
        <Relationship Id="rId\(count + 1)" Type="\(relationshipNS)/styles" Target="styles.xml"/>\
        <Relationship Id="rId\(count + 2)" Type="\(relationshipNS)/sharedStrings" Target="sharedStrings.xml"/>\
        </Relationships>
        """).utf8)

        entries["xl/styles.xml"] = Data((header + """
        <styleSheet xmlns="\(main)">\
        <numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd\\ hh:mm"/></numFmts>\
        <fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>\
        <font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="5">\
        <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="21" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        </cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """).utf8)

        var sharedXML = header + #"<sst xmlns="\#(main)" count="\#(strings.count)" uniqueCount="\#(strings.count)">"#
        for string in strings {
            let space = string.first?.isWhitespace == true || string.last?.isWhitespace == true || string.contains("\n")
            sharedXML += space ? #"<si><t xml:space="preserve">"# : "<si><t>"
            sharedXML += SpreadsheetXML.escape(string) + "</t></si>"
        }
        sharedXML += "</sst>"
        entries["xl/sharedStrings.xml"] = Data(sharedXML.utf8)

        try ZipPackage.write(entries, to: url)
    }

    private static func worksheet(_ sheet: SpreadsheetSheet, shared: (String) -> Int) -> String {
        let bold = sheet.hasHeaderRow
        let columns = sheet.columnCount
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        xml += #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
        if columns > 0, !sheet.rows.isEmpty {
            xml += #"<dimension ref="A1:\#(columnName(columns - 1))\#(sheet.rows.count)"/>"#
        }
        xml += bold
            ? #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
            : #"<sheetViews><sheetView workbookViewId="0"/></sheetViews>"#
        xml += #"<sheetFormatPr defaultRowHeight="15"/>"#
        if columns > 0 {
            xml += "<cols>"
            for (index, width) in SpreadsheetXML.columnWidths(sheet).enumerated() {
                xml += #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(width)" customWidth="1"/>"#
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (rowIndex, row) in sheet.rows.enumerated() where !row.isEmpty {
            xml += #"<row r="\#(rowIndex + 1)">"#
            for (column, cell) in row.enumerated() {
                let reference = "\(columnName(column))\(rowIndex + 1)"
                let style = rowIndex == 0 && bold ? Style.bold.rawValue : Style.normal.rawValue
                let styleAttribute = style == 0 ? "" : #" s="\#(style)""#
                switch cell {
                case .empty:
                    continue
                case .text(let string):
                    xml += #"<c r="\#(reference)" t="s"\#(styleAttribute)><v>\#(shared(string))</v></c>"#
                case .number(let value):
                    xml += #"<c r="\#(reference)"\#(styleAttribute)><v>\#(SpreadsheetCell.xmlNumber(value))</v></c>"#
                case .bool(let value):
                    xml += #"<c r="\#(reference)" t="b"\#(styleAttribute)><v>\#(value ? 1 : 0)</v></c>"#
                case .date(let serial, let kind):
                    let dateStyle: Style = kind == .date ? .date : kind == .time ? .time : .dateTime
                    xml += #"<c r="\#(reference)" s="\#(dateStyle.rawValue)"><v>\#(SpreadsheetCell.xmlNumber(serial))</v></c>"#
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }
}
