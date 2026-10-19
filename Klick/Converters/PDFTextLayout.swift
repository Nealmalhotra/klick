import AppKit
import PDFKit

/// Recovers structure from a PDF's text layer for the reflowing exports (Markdown, EPUB, XLSX):
/// visual lines with their font size, cells split at wide horizontal gaps, and blocks —
/// headings by font size, paragraphs, list items and tables.
enum PDFTextLayout {
    /// Text on one visual line, separated from its neighbours by a wide gap (a table cell, a tab stop).
    struct Segment {
        var text: String
        var minX: CGFloat
        var maxX: CGFloat
    }

    /// One visual line in reading order.
    struct Line {
        var segments: [Segment]
        /// Page space: PDF points, origin bottom-left.
        var bounds: CGRect
        /// Dominant font size, in points.
        var fontSize: CGFloat
        var isBold: Bool

        var text: String { segments.map(\.text).joined(separator: " ") }
    }

    enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(ListMarker, text: String)
        case table([[String]])
    }

    /// How a list item was marked in the PDF ("•", "3.", "(4)", "b)").
    struct ListMarker: Equatable {
        enum Style { case bullet, number, letter }

        let style: Style
        /// The item's number (letters count from a = 1); 1 for bullets.
        let ordinal: Int
        /// The marker as printed, without the following space.
        let label: String

        /// Whether this marker can follow `previous` in the same list.
        func continues(_ previous: ListMarker) -> Bool {
            style == previous.style && (style == .bullet || ordinal == previous.ordinal + 1)
        }
    }

    /// What a page holds: positioned lines from its text layer, or paragraphs recognized in a scan.
    enum PageText {
        case lines([Line])
        case recognized([String])

        var isEmpty: Bool {
            switch self {
            case .lines(let lines): return lines.isEmpty
            case .recognized(let paragraphs): return paragraphs.isEmpty
            }
        }
    }

    /// A spreadsheet row.
    struct Row {
        var cells: [String]
        var isBold = false
    }

    /// A block and the (0-based) page it starts on.
    struct PlacedBlock {
        let page: Int
        var block: Block
    }

    // MARK: - Lines

    /// The page's text as visual lines. PDFKit's line selections give the reading order; words are
    /// measured through range selections (`characterBounds(at:)` uses a different index space).
    static func lines(of page: PDFPage) -> [Line] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        guard let selection = page.selection(for: NSRange(location: 0, length: text.length)) else { return [] }
        let attributed = page.attributedString.flatMap { $0.length == text.length ? $0 : nil }

        var lines: [Line] = []
        for lineSelection in selection.selectionsByLine() {
            for index in 0..<lineSelection.numberOfTextRanges(on: page) {
                let range = lineSelection.range(at: index, on: page)
                guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= text.length,
                      let line = line(in: range, of: page, text: text, attributed: attributed)
                else { continue }
                // Cells drawn one by one can come back as separate "lines" on the same row, sometimes
                // after the wrapped tail of a cell to their left.
                if let row = lines.indices.suffix(3).last(where: { sharesRow(lines[$0], line) }) {
                    lines[row] = joinRow(lines[row], line)
                } else {
                    lines.append(line)
                }
            }
        }
        return lines
    }

    private static func line(in range: NSRange, of page: PDFPage, text: NSString, attributed: NSAttributedString?) -> Line? {
        // Words (runs of non-blank characters) with their bounds.
        var words: [(range: NSRange, bounds: CGRect)] = []
        var start: Int?
        for index in range.location...NSMaxRange(range) {
            let blank = index == NSMaxRange(range) || isBlank(text.character(at: index))
            if blank, let first = start {
                let wordRange = NSRange(location: first, length: index - first)
                if let bounds = page.selection(for: wordRange)?.bounds(for: page), !bounds.isEmpty {
                    words.append((wordRange, bounds))
                }
                start = nil
            } else if !blank, start == nil {
                start = index
            }
        }
        guard let firstWord = words.first else { return nil }

        let (fontSize, isBold) = dominantFont(in: range, of: attributed, fallbackHeight: firstWord.bounds.height)
        let gap = cellGap(fontSize)
        var segments: [Segment] = []
        var segmentStart = firstWord
        var previous = firstWord
        for word in words.dropFirst().map(Optional.some) + [nil] {
            if let word, word.bounds.minX - previous.bounds.maxX <= gap {
                previous = word
                continue
            }
            let segmentRange = NSRange(location: segmentStart.range.location, length: NSMaxRange(previous.range) - segmentStart.range.location)
            segments.append(Segment(
                text: collapseSpaces(text.substring(with: segmentRange)),
                minX: segmentStart.bounds.minX, maxX: previous.bounds.maxX
            ))
            if let word { segmentStart = word; previous = word }
        }
        let bounds = words.dropFirst().reduce(firstWord.bounds) { $0.union($1.bounds) }
        return Line(segments: segments, bounds: bounds, fontSize: fontSize, isBold: isBold)
    }

    /// Horizontal gap that separates two cells rather than two words.
    private static func cellGap(_ fontSize: CGFloat) -> CGFloat { max(fontSize * 1.2, 6) }

    private static func isBlank(_ unit: unichar) -> Bool {
        switch unit {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x2028, 0x2029, 0x3000, 0x2000...0x200B: return true
        default: return false
        }
    }

    private static func collapseSpaces(_ string: String) -> String {
        string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The font covering most characters of `range`: its size and whether it's bold.
    private static func dominantFont(in range: NSRange, of attributed: NSAttributedString?, fallbackHeight: CGFloat) -> (CGFloat, Bool) {
        var lengths: [NSFont: Int] = [:]
        attributed?.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? NSFont { lengths[font, default: 0] += run.length }
        }
        guard let font = lengths.max(by: { $0.value < $1.value })?.key, font.pointSize > 1.5 else {
            return (max(fallbackHeight / 1.2, 1), false)
        }
        let name = font.fontName.lowercased()
        let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            || ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) }
        return (font.pointSize, bold)
    }

    /// `next` continues `line`'s row: they overlap vertically and `next` sits to the right.
    private static func sharesRow(_ line: Line, _ next: Line) -> Bool {
        let overlap = min(line.bounds.maxY, next.bounds.maxY) - max(line.bounds.minY, next.bounds.minY)
        return overlap >= 0.6 * min(line.bounds.height, next.bounds.height) && next.bounds.minX >= line.bounds.maxX - 1
    }

    private static func joinRow(_ line: Line, _ next: Line) -> Line {
        var joined = line
        if let last = line.segments.last, let first = next.segments.first,
           first.minX - last.maxX <= cellGap(max(line.fontSize, next.fontSize)) {
            joined.segments[joined.segments.count - 1] = Segment(text: last.text + " " + first.text, minX: last.minX, maxX: first.maxX)
            joined.segments += next.segments.dropFirst()
        } else {
            joined.segments += next.segments
        }
        joined.bounds = line.bounds.union(next.bounds)
        joined.fontSize = max(line.fontSize, next.fontSize)
        return joined
    }

    // MARK: - Rows (spreadsheets)

    /// The page as spreadsheet rows: runs of multi-cell lines are aligned into shared columns,
    /// every other line is a single cell.
    static func rows(of page: PageText) -> [Row] {
        let lines: [Line]
        switch page {
        case .lines(let pageLines): lines = pageLines
        case .recognized(let paragraphs): return paragraphs.map { Row(cells: [$0]) }
        }
        var rows: [Row] = []
        var index = 0
        while index < lines.count {
            guard lines[index].segments.count > 1 else {
                rows.append(Row(cells: [lines[index].text], isBold: lines[index].isBold))
                index += 1
                continue
            }
            let end = tableEnd(lines, from: index) { $0.segments.count > 1 }
            rows += gridRows(lines[index..<end])
            index = end
        }
        return rows
    }

    /// End of the table starting at `start`: rows of cells, plus single lines that wrap a cell of the row above.
    private static func tableEnd(_ lines: [Line], from start: Int, isRow: (Line) -> Bool) -> Int {
        var end = start
        while end < lines.count {
            let line = lines[end]
            if isRow(line) {
                end += 1
            } else if end > start, wrapsCell(line, below: lines[end - 1]) {
                end += 1
            } else {
                break
            }
        }
        return end
    }

    /// A single line right under `row`, starting where one of its cells starts.
    private static func wrapsCell(_ line: Line, below row: Line) -> Bool {
        line.segments.count == 1 && gap(row, line) <= line.fontSize * 0.6
            && row.segments.contains { abs($0.minX - line.bounds.minX) <= 2 }
    }

    /// Assigns cells to columns: overlapping horizontal extents (left, right or center aligned) share a column.
    /// Single lines after the first continue the cell above them (wrapped cell text).
    private static func gridRows(_ lines: ArraySlice<Line>) -> [Row] {
        let rowLines = lines.enumerated().filter { $0.offset == 0 || $0.element.segments.count > 1 }.map(\.element)
        var columns: [(minX: CGFloat, maxX: CGFloat)] = []
        for segment in rowLines.flatMap(\.segments).sorted(by: { $0.minX < $1.minX }) {
            if let last = columns.last, segment.minX <= last.maxX + 2 {
                columns[columns.count - 1].maxX = max(last.maxX, segment.maxX)
            } else {
                columns.append((segment.minX, segment.maxX))
            }
        }
        func column(of segment: Segment) -> Int {
            let mid = (segment.minX + segment.maxX) / 2
            return columns.firstIndex { mid >= $0.minX - 1 && mid <= $0.maxX + 1 }
                ?? columns.lastIndex { $0.minX <= segment.minX + 1 } ?? 0
        }
        var rows: [Row] = []
        for line in lines {
            if rows.isEmpty || line.segments.count > 1 {
                rows.append(Row(cells: Array(repeating: "", count: columns.count), isBold: line.isBold))
            }
            for segment in line.segments {
                let index = column(of: segment)
                let cell = rows[rows.count - 1].cells[index]
                rows[rows.count - 1].cells[index] = cell.isEmpty ? segment.text : joinLines(cell, segment.text)
            }
        }
        return rows
    }

    // MARK: - Blocks (Markdown, EPUB)

    /// Structured content of every page. Heading levels come from the document's font sizes
    /// (the most common size is body text); paragraphs broken by a page are joined again.
    static func blocks(of pages: [PageText]) -> [PlacedBlock] {
        let metrics = Metrics(pages.flatMap { page -> [Line] in
            if case .lines(let lines) = page { return lines }
            return []
        })
        var placed: [PlacedBlock] = []
        for (pageIndex, page) in pages.enumerated() {
            let blocks: [Block]
            switch page {
            case .lines(let lines):
                var lastItem: ListMarker?
                if let last = placed.last, case .listItem(let marker, _) = last.block { lastItem = marker }
                blocks = self.blocks(of: withoutPageNumbers(lines), metrics: metrics, lastItem: lastItem)
            case .recognized(let paragraphs):
                blocks = paragraphs.map { .paragraph($0) }
            }
            for (offset, block) in blocks.enumerated() {
                if offset == 0, case .paragraph(let text) = block, let last = placed.last,
                   case .paragraph(let previous) = last.block, continuesAcrossPages(previous, text) {
                    placed[placed.count - 1].block = .paragraph(joinLines(previous, text))
                    continue
                }
                placed.append(PlacedBlock(page: pageIndex, block: block))
            }
        }
        return placed
    }

    /// Font statistics shared by every page of a document.
    private struct Metrics {
        /// Most common font size, weighted by text length.
        let bodySize: CGFloat
        /// Distinct heading sizes, largest first (level 1, 2, ...).
        let headingSizes: [CGFloat]

        init(_ lines: [Line]) {
            var weights: [CGFloat: Int] = [:]
            for line in lines { weights[(line.fontSize * 2).rounded() / 2, default: 0] += line.text.count }
            bodySize = weights.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 12
            var sizes: [CGFloat] = []
            for size in lines.filter({ $0.text.count <= 120 }).map(\.fontSize).sorted(by: >) where size >= bodySize * 1.15 {
                if let last = sizes.last, last - size < 0.75 { continue }
                sizes.append(size)
            }
            headingSizes = Array(sizes.prefix(5))
        }

        func headingLevel(_ line: Line) -> Int? {
            let text = line.text
            guard text.count <= 120, text.contains(where: \.isLetter) else { return nil }
            if line.fontSize >= bodySize * 1.15 {
                return (headingSizes.firstIndex { $0 - line.fontSize < 0.75 } ?? headingSizes.count - 1) + 1
            }
            // Short bold lines at body size read as the lowest heading level.
            if line.isBold, abs(line.fontSize - bodySize) < 1, text.count <= 80, !text.hasSuffix("."), !text.hasSuffix(",") {
                return min(headingSizes.count + 1, 6)
            }
            return nil
        }
    }

    /// - Parameter lastItem: the marker of the list item right before this page, so a list can carry on.
    private static func blocks(of lines: [Line], metrics: Metrics, lastItem: ListMarker?) -> [Block] {
        let textRight = lines.filter { $0.segments.count == 1 }.map(\.bounds.maxX).max() ?? 0
        let lineGap = typicalLineGap(lines)
        var blocks: [Block] = []
        var lastItem = lastItem
        var index = 0
        while index < lines.count {
            let line = lines[index]

            // Tables: two or more consecutive rows of short cells.
            if isTableRow(line) {
                let end = tableEnd(lines, from: index, isRow: isTableRow)
                if lines[index..<end].filter(isTableRow).count >= 2 {
                    blocks.append(.table(gridRows(lines[index..<end]).map(\.cells)))
                    lastItem = nil
                    index = end
                    continue
                }
            }

            if let level = metrics.headingLevel(line) {
                var text = line.text
                var end = index + 1
                while end < lines.count, metrics.headingLevel(lines[end]) == level,
                      abs(lines[end].fontSize - line.fontSize) < 0.5, gap(lines[end - 1], lines[end]) < line.fontSize * 0.8 {
                    text = joinLines(text, lines[end].text)
                    end += 1
                }
                blocks.append(.heading(level: level, text: text))
                lastItem = nil
                index = end
                continue
            }

            // A marker only makes a list item when its number fits: a new list starts at 1 (or a),
            // an existing one goes on with the next number. "101. Lorem" stays text.
            let parsed = listMarker(line.text)
            let marker = parsed.flatMap { candidate in
                candidate.marker.ordinal == 1 || lastItem.map(candidate.marker.continues) == true ? candidate : nil
            }
            var text = marker.map { String(line.text.dropFirst($0.length)) } ?? line.text
            var end = index + 1
            while end < lines.count {
                let previous = lines[end - 1], next = lines[end]
                guard next.segments.count == 1 || !isTableRow(next),
                      metrics.headingLevel(next) == nil,
                      abs(next.fontSize - previous.fontSize) <= 0.6,
                      gap(previous, next) <= lineGap + 0.4 * previous.fontSize
                else { break }
                // A short line ending a sentence closes its paragraph.
                if previous.bounds.maxX < textRight - 3 * previous.fontSize, endsSentence(previous.text) { break }
                if let nextMarker = listMarker(next.text)?.marker,
                   startsItem(nextMarker, at: next, after: previous, in: marker?.marker, itemStart: line, lineGap: lineGap) {
                    break
                }
                // List items continue on indented lines only.
                if marker != nil, next.bounds.minX < line.bounds.minX + line.fontSize * 0.5 { break }
                text = joinLines(text, next.text)
                end += 1
            }
            if let marker {
                blocks.append(.listItem(marker.marker, text: text))
                lastItem = marker.marker
            } else {
                blocks.append(.paragraph(text))
                lastItem = nil
            }
            index = end
        }
        return blocks
    }

    private static func isTableRow(_ line: Line) -> Bool {
        line.segments.count > 1 && line.segments.map(\.text.count).reduce(0, +) / line.segments.count <= 40
    }

    /// Vertical whitespace between two consecutive lines.
    private static func gap(_ line: Line, _ next: Line) -> CGFloat {
        line.bounds.minY - next.bounds.maxY
    }

    /// The usual leading between lines of a paragraph on this page (median of the small gaps).
    private static func typicalLineGap(_ lines: [Line]) -> CGFloat {
        let gaps = zip(lines, lines.dropFirst())
            .filter { abs($0.fontSize - $1.fontSize) < 0.5 }
            .map { gap($0, $1) }
            .filter { $0 >= -1 && $0 < 40 }
            .sorted()
        return gaps.isEmpty ? 3 : max(gaps[gaps.count / 2], 0)
    }

    /// Whether a marked line inside a paragraph or list item really starts a new item, rather than
    /// being a wrapped line that happens to begin with "101." or "– ".
    private static func startsItem(
        _ marker: ListMarker, at line: Line, after previous: Line, in current: ListMarker?, itemStart: Line, lineGap: CGFloat
    ) -> Bool {
        if let current {
            // The next item of the list being read: its marker lines up with this item's.
            return marker.continues(current) && abs(line.bounds.minX - itemStart.bounds.minX) <= itemStart.fontSize * 0.5
        }
        // A paragraph gives way to a new list only at a break: the sentence (or an intro "…:") ended,
        // or there's extra space or indentation before the marker.
        guard marker.ordinal == 1 else { return false }
        return endsSentence(previous.text)
            || gap(previous, line) > lineGap + 0.25 * line.fontSize
            || line.bounds.minX > previous.bounds.minX + line.fontSize
    }

    private static let bulletMarker = try! NSRegularExpression(pattern: #"^[•◦▪▫‣⁃●○■□➢►–—\-\*·](?=\s+\S)"#)
    private static let numberMarker = try! NSRegularExpression(pattern: #"^\(?(\d{1,3})[.)](?=\s+\S)"#)
    private static let letterMarker = try! NSRegularExpression(pattern: #"^\(?([a-z])[.)](?=\s+\S)"#)

    /// The list marker at the start of `text` ("• ", "3. ", "(b) ") and the length to drop with its spaces.
    private static func listMarker(_ text: String) -> (marker: ListMarker, length: Int)? {
        let range = NSRange(text.startIndex..., in: text)
        for (regex, style) in [(bulletMarker, ListMarker.Style.bullet), (numberMarker, .number), (letterMarker, .letter)] {
            guard let match = regex.firstMatch(in: text, range: range), let labelRange = Range(match.range, in: text) else { continue }
            let label = String(text[labelRange])
            var ordinal = 1
            if style != .bullet, let valueRange = Range(match.range(at: 1), in: text) {
                let value = text[valueRange]
                ordinal = style == .number ? Int(value) ?? 1 : Int(value.unicodeScalars.first!.value) - 96
            }
            let spaces = text[labelRange.upperBound...].prefix { $0.isWhitespace }.count
            return (ListMarker(style: style, ordinal: ordinal, label: label), label.count + spaces)
        }
        return nil
    }

    private static let pageNumber = try! NSRegularExpression(pattern: #"^(page\s*)?\d{1,4}(\s*(of|/)\s*\d{1,4})?$"#, options: .caseInsensitive)

    /// Drops a running page number ("12", "Page 3 of 9") at the top or bottom of the page.
    private static func withoutPageNumbers(_ lines: [Line]) -> [Line] {
        func isPageNumber(_ line: Line?) -> Bool {
            guard let text = line?.text.trimmingCharacters(in: .whitespaces) else { return false }
            return pageNumber.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        var lines = lines
        if lines.count > 1, isPageNumber(lines.last) { lines.removeLast() }
        if lines.count > 1, isPageNumber(lines.first) { lines.removeFirst() }
        return lines
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return true }
        return ".!?:;\"”’)]".contains(last)
    }

    private static func continuesAcrossPages(_ previous: String, _ next: String) -> Bool {
        !endsSentence(previous) && next.first?.isLowercase == true
    }

    /// Joins wrapped lines, healing words hyphenated at the line end ("perfor-" + "mance").
    static func joinLines(_ text: String, _ next: String) -> String {
        if text.hasSuffix("\u{AD}") { return text.dropLast() + next }
        if text.hasSuffix("-"), text.dropLast().last?.isLetter == true, next.first?.isLowercase == true {
            return text.dropLast() + next
        }
        return text + " " + next
    }
}
