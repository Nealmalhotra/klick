import AppKit
import CoreText

/// Renders sheets as clean, paginated PDF tables with Core Text: header row repeated on every page,
/// zebra striping, numbers right-aligned, landscape when the table is wide. Tables too wide even at a
/// smaller size wrap long columns, and as a last resort continue on extra pages (columns split into groups).
enum SpreadsheetPDF {
    private static let margin: CGFloat = 36
    private static let paddingX: CGFloat = 5
    private static let paddingY: CGFloat = 3
    private static let baseFontSize: CGFloat = 9
    private static let maxColumnWidth: CGFloat = 260
    private static let minColumnWidth: CGFloat = 24
    private static let wrappedColumnWidth: CGFloat = 70
    private static let maxLines: CGFloat = 6
    private static let minScale: CGFloat = 0.72
    private static let titleHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 22

    private struct Page {
        let group: Int
        let rows: [Int]
        let showsTitle: Bool
    }

    private struct Layout {
        let sheet: SpreadsheetSheet
        let title: String
        let pageSize: CGSize
        let fontSize: CGFloat
        let widths: [CGFloat]
        let groups: [[Int]]
        /// Row heights for each column group.
        let heights: [[CGFloat]]
        let header: Bool
        let pages: [Page]
    }

    static func write(_ workbook: SpreadsheetWorkbook, title: String, to url: URL, progress: JobProgress) throws {
        let paper = paperSize()
        let layouts = try workbook.sheets.map { sheet -> Layout in
            try progress.checkCancelled()
            return layout(sheet, title: workbook.sheets.count > 1 ? sheet.name : title, paper: paper)
        }
        progress.report(0.6)

        var mediaBox = CGRect(origin: .zero, size: paper)
        let info = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Klick"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info) else {
            throw KlickError.failed("Couldn't create \(url.lastPathComponent)")
        }
        let total = layouts.reduce(0) { $0 + $1.pages.count }
        var number = 0
        for layout in layouts {
            for page in layout.pages {
                try progress.checkCancelled()
                number += 1
                var box = CGRect(origin: .zero, size: layout.pageSize)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                draw(page, of: layout, number: number, total: total, document: title, in: context)
                context.endPDFPage()
                progress.report(0.6 + 0.4 * Double(number) / Double(max(total, 1)))
            }
        }
        context.closePDF()
    }

    /// Letter in the US & co., A4 elsewhere (portrait).
    private static func paperSize() -> CGSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR"]
        return letterRegions.contains(Locale.current.region?.identifier ?? "") ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    // MARK: - Layout

    private static func layout(_ sheet: SpreadsheetSheet, title: String, paper: CGSize) -> Layout {
        let header = sheet.hasHeaderRow
        var natural = naturalWidths(sheet, header: header, fontSize: baseFontSize)
        let initialTotal = natural.reduce(0, +)
        let landscape = initialTotal > paper.width - margin * 2
        let pageSize = landscape ? CGSize(width: paper.height, height: paper.width) : paper
        let available = pageSize.width - margin * 2

        // Shrink the type a little (re-measuring: small optical sizes are relatively wider than a
        // scaled-down base size), then wrap the widest columns, then split into column groups.
        var scale: CGFloat = 1
        var total = initialTotal
        let padding = CGFloat(natural.count) * (paddingX * 2 + 1) // doesn't shrink with the type
        for _ in 0..<6 where total > available && scale > minScale {
            scale = max(scale * max(available - padding, 1) / max(total - padding, 1), minScale)
            natural = naturalWidths(sheet, header: header, fontSize: baseFontSize * scale)
            total = natural.reduce(0, +)
        }
        var widths = natural
        if total > available {
            var low: CGFloat = 0, high = widths.max() ?? 0
            for _ in 0..<30 {
                let cap = (low + high) / 2
                if widths.reduce(0, { $0 + min($1, cap) }) > available { high = cap } else { low = cap }
            }
            let cap = max(low, wrappedColumnWidth)
            widths = widths.map { min($0, cap) }
        }
        var groups: [[Int]] = [[]]
        var used: CGFloat = 0
        for (column, width) in widths.enumerated() {
            if used + width > available + 0.5, !(groups[groups.count - 1].isEmpty) {
                groups.append([])
                used = 0
            }
            groups[groups.count - 1].append(column)
            used += width
        }

        // Row heights per column group with the final widths (wrapped text grows rows, up to `maxLines`).
        let fontSize = baseFontSize * scale
        let rowFont = regularFont(fontSize)
        let headerFont = boldFont(fontSize)
        let line = lineHeight(rowFont)
        let cellHeights = sheet.rows.enumerated().map { rowIndex, row -> [CGFloat] in
            row.enumerated().map { column, cell -> CGFloat in
                let text = cell.displayText
                guard !cell.isEmpty, text.contains(where: \.isNewline) || natural[column] > widths[column] + 0.5 else { return line }
                let size = CTFramesetterSuggestFrameSizeWithConstraints(
                    CTFramesetterCreateWithAttributedString(attributed(text, font: header && rowIndex == 0 ? headerFont : rowFont, alignment: .left)),
                    CFRange(), nil, CGSize(width: widths[column] - paddingX * 2, height: .greatestFiniteMagnitude), nil
                )
                return min(ceil(size.height), line * maxLines)
            }
        }
        let heights = groups.map { columns in
            cellHeights.map { row in columns.reduce(line) { $1 < row.count ? max($0, row[$1]) : $0 } + paddingY * 2 }
        }

        // Paginate each column group: the header row repeats, the title only opens the sheet.
        let bodyRows = Array((header ? 1 : 0)..<sheet.rows.count)
        let bottom = pageSize.height - margin - footerHeight
        var pages: [Page] = []
        for group in groups.indices {
            let headerHeight = header ? heights[group][0] : 0
            var current: [Int] = []
            var top = margin + (group == 0 ? titleHeight : 0) + headerHeight
            var first = group == 0
            for row in bodyRows {
                if top + heights[group][row] > bottom, !current.isEmpty {
                    pages.append(Page(group: group, rows: current, showsTitle: first))
                    first = false
                    current = []
                    top = margin + headerHeight
                }
                current.append(row)
                top += heights[group][row]
            }
            pages.append(Page(group: group, rows: current, showsTitle: first))
        }
        return Layout(
            sheet: sheet, title: title, pageSize: pageSize, fontSize: fontSize, widths: widths,
            groups: groups, heights: heights, header: header, pages: pages
        )
    }

    /// Unwrapped width of each column's longest value (plus padding), capped at `maxColumnWidth`.
    private static func naturalWidths(_ sheet: SpreadsheetSheet, header: Bool, fontSize: CGFloat) -> [CGFloat] {
        let font = regularFont(fontSize)
        let bold = boldFont(fontSize)
        var widths = Array(repeating: minColumnWidth, count: sheet.columnCount)
        for (rowIndex, row) in sheet.rows.enumerated() {
            for (column, cell) in row.enumerated() where !cell.isEmpty {
                let width = textWidth(cell.displayText, font: header && rowIndex == 0 ? bold : font) + paddingX * 2 + 1
                widths[column] = max(widths[column], min(ceil(width), maxColumnWidth))
            }
        }
        return widths
    }

    // MARK: - Drawing

    private static func draw(_ page: Page, of layout: Layout, number: Int, total: Int, document: String, in context: CGContext) {
        let height = layout.pageSize.height
        // Layout works top-down; PDF space is bottom-up.
        func rect(_ x: CGFloat, _ top: CGFloat, _ width: CGFloat, _ rowHeight: CGFloat) -> CGRect {
            CGRect(x: x, y: height - top - rowHeight, width: width, height: rowHeight)
        }
        context.textMatrix = .identity
        let columns = layout.groups[page.group]
        let tableWidth = columns.reduce(0) { $0 + layout.widths[$1] }
        let rowFont = regularFont(layout.fontSize)
        let headerFont = boldFont(layout.fontSize)

        var top = margin
        if page.showsTitle {
            drawText(layout.title, font: boldFont(13), color: CGColor(gray: 0.1, alpha: 1), alignment: .left,
                     in: rect(margin, top, layout.pageSize.width - margin * 2, titleHeight - 8), context: context)
            top += titleHeight
        }

        func drawRow(_ row: Int, isHeader: Bool, striped: Bool) {
            let rowHeight = layout.heights[page.group][row]
            if isHeader {
                context.setFillColor(CGColor(gray: 0.91, alpha: 1))
                context.fill(rect(margin, top, tableWidth, rowHeight))
            } else if striped {
                context.setFillColor(CGColor(gray: 0.965, alpha: 1))
                context.fill(rect(margin, top, tableWidth, rowHeight))
            }
            var x = margin
            let cells = layout.sheet.rows[row]
            for column in columns {
                let width = layout.widths[column]
                if column < cells.count, !cells[column].isEmpty {
                    let cell = cells[column]
                    let alignment: CTTextAlignment = cell.isText || isHeader ? .left : .right
                    let frame = rect(x + paddingX, top + paddingY, width - paddingX * 2, rowHeight - paddingY * 2)
                    drawText(cell.displayText, font: isHeader ? headerFont : rowFont, color: CGColor(gray: 0.08, alpha: 1),
                             alignment: alignment, in: frame, context: context)
                }
                x += width
            }
            context.setStrokeColor(CGColor(gray: isHeader ? 0.55 : 0.84, alpha: 1))
            context.setLineWidth(isHeader ? 0.75 : 0.4)
            let lineY = height - top - rowHeight
            context.strokeLineSegments(between: [CGPoint(x: margin, y: lineY), CGPoint(x: margin + tableWidth, y: lineY)])
            top += rowHeight
        }

        if layout.header { drawRow(0, isHeader: true, striped: false) }
        let firstBody = layout.header ? 1 : 0
        for row in page.rows { drawRow(row, isHeader: false, striped: (row - firstBody) % 2 == 1) }

        // Footer: document (and sheet) name on the left, page count on the right.
        let footerFont = regularFont(7.5)
        let footerColor = CGColor(gray: 0.5, alpha: 1)
        let footerRect = rect(margin, height - margin - 10, layout.pageSize.width - margin * 2, 12)
        let name = layout.title == document ? document : "\(document) — \(layout.title)"
        drawText(name, font: footerFont, color: footerColor, alignment: .left, in: footerRect, context: context)
        drawText("Page \(number) of \(total)", font: footerFont, color: footerColor, alignment: .right, in: footerRect, context: context)
    }

    private static func drawText(_ text: String, font: CTFont, color: CGColor, alignment: CTTextAlignment, in frame: CGRect, context: CGContext) {
        guard frame.width > 0, frame.height > 0 else { return }
        let string = attributed(text, font: font, alignment: alignment, color: color)
        let setter = CTFramesetterCreateWithAttributedString(string)
        let ctFrame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: frame, transform: nil), nil)
        context.saveGState()
        context.clip(to: frame.insetBy(dx: -1, dy: -1))
        CTFrameDraw(ctFrame, context)
        context.restoreGState()
    }

    // MARK: - Text

    private static func regularFont(_ size: CGFloat) -> CTFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) as CTFont
    }

    private static func boldFont(_ size: CGFloat) -> CTFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold) as CTFont
    }

    private static func lineHeight(_ font: CTFont) -> CGFloat {
        ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
    }

    private static let leftStyle = paragraphStyle(.left)
    private static let rightStyle = paragraphStyle(.right)

    private static func paragraphStyle(_ alignment: CTTextAlignment) -> CTParagraphStyle {
        var align = alignment
        return withUnsafeBytes(of: &align) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer.baseAddress!)
            return CTParagraphStyleCreate(&setting, 1)
        }
    }

    private static func attributed(_ text: String, font: CTFont, alignment: CTTextAlignment, color: CGColor? = nil) -> CFAttributedString {
        let style = alignment == .right ? rightStyle : leftStyle
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        ]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return NSAttributedString(string: text, attributes: attributes) as CFAttributedString
    }

    /// Width of the longest line, unwrapped.
    private static func textWidth(_ text: String, font: CTFont) -> CGFloat {
        text.split(whereSeparator: \.isNewline).map { line in
            let ctLine = CTLineCreateWithAttributedString(attributed(String(line), font: font, alignment: .left))
            return CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
        }.max() ?? 0
    }
}
