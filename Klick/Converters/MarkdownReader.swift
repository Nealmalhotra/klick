import AppKit

/// Markdown → attributed text. Foundation's CommonMark/GFM parser (`.full` syntax) supplies the
/// block structure as `PresentationIntent`s; this turns them into real fonts, paragraph styles,
/// `NSTextList`s and header levels, so every AppKit writer (DOCX lists, HTML `<h1>`…) and
/// `DocumentBlocks` see a proper document.
enum MarkdownReader {
    static let bodyFont = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
    static let codeFont = NSFont(name: "Menlo", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    /// Indent per list / quote level.
    private static let indentStep: CGFloat = 24

    static func attributedString(from source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            return NSAttributedString(string: source, attributes: [.font: bodyFont])
        }

        let result = NSMutableAttributedString()
        var objects = TextObjects()
        var previous: PresentationIntent?
        var previousAttributes: [NSAttributedString.Key: Any] = [:]
        for run in parsed.runs {
            let block = run.presentationIntent
            var attributes = blockAttributes(block, after: previous, objects: &objects)
            if block != previous {
                // Every block (and table cell) is its own paragraph.
                if result.length > 0 && !result.string.hasSuffix("\n") {
                    result.append(NSAttributedString(string: "\n", attributes: previousAttributes))
                }
                if let marker = listMarker(block, previous: previous, lists: objects.lists) {
                    result.append(NSAttributedString(string: marker, attributes: attributes))
                }
                previous = block
            }
            if let inline = run.inlinePresentationIntent {
                attributes = inlineAttributes(inline, base: attributes)
            }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            previousAttributes = attributes
        }
        return result
    }

    /// Lists and tables shared by the paragraphs that belong to them, by intent identity.
    private struct TextObjects {
        var lists: [Int: NSTextList] = [:]
        var tables: [Int: NSTextTable] = [:]
    }

    private static func blockAttributes(
        _ block: PresentationIntent?, after previous: PresentationIntent?, objects: inout TextObjects
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        var font = bodyFont
        var attributes: [NSAttributedString.Key: Any] = [:]
        let components = block?.components ?? []

        // Components run innermost → outermost; NSParagraphStyle wants lists outermost first.
        var textLists: [NSTextList] = []
        for component in components.reversed() {
            guard component.kind == .orderedList || component.kind == .unorderedList else { continue }
            let list = objects.lists[component.identity] ?? NSTextList(
                markerFormat: component.kind == .orderedList ? orderedMarker : (textLists.isEmpty ? .disc : .circle), options: 0
            )
            objects.lists[component.identity] = list
            textLists.append(list)
        }
        if textLists.isEmpty, previous?.components.contains(where: { $0.kind == .orderedList || $0.kind == .unorderedList }) == true {
            style.paragraphSpacingBefore = 6 // list items are tight; leave room after the list
        }
        if let cell = tableCell(components, objects: &objects) {
            style.textBlocks = [cell.block]
            style.paragraphSpacing = 0
            if cell.header { font = adding(.bold, to: font) }
        }
        let quoted = components.contains { $0.kind == .blockQuote }
        let depth = CGFloat(textLists.count)
        if !textLists.isEmpty {
            // AppKit's list layout: "\t<marker>\t" with the text hanging at the next level.
            style.textLists = textLists
            style.firstLineHeadIndent = (depth - 1) * indentStep + (quoted ? indentStep : 0)
            style.headIndent = style.firstLineHeadIndent + indentStep
            style.tabStops = [
                NSTextTab(textAlignment: .left, location: style.firstLineHeadIndent + 6),
                NSTextTab(textAlignment: .left, location: style.headIndent),
            ]
            style.paragraphSpacing = 2
        } else if quoted {
            style.firstLineHeadIndent = indentStep
            style.headIndent = indentStep
        }

        for component in components {
            switch component.kind {
            case .header(let level):
                let sizes: [CGFloat] = [24, 20, 16, 14, 13, 12]
                let level = min(max(level, 1), 6)
                font = adding(.bold, to: bodyFont.withSize(sizes[level - 1]))
                style.headerLevel = level
                style.paragraphSpacingBefore = 10
            case .codeBlock:
                font = codeFont
                style.paragraphSpacing = 0
                attributes[.backgroundColor] = NSColor(white: 0.95, alpha: 1)
            case .blockQuote:
                attributes[.foregroundColor] = NSColor.darkGray
            case .thematicBreak:
                style.alignment = .center
            default:
                break
            }
        }
        attributes[.font] = font
        attributes[.paragraphStyle] = style
        return attributes
    }

    private static func inlineAttributes(
        _ inline: InlinePresentationIntent, base: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var attributes = base
        var font = base[.font] as? NSFont ?? bodyFont
        if inline.contains(.code) { font = codeFont.withSize(font.pointSize - 1) }
        if inline.contains(.stronglyEmphasized) { font = adding(.bold, to: font) }
        if inline.contains(.emphasized) { font = adding(.italic, to: font) }
        if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        attributes[.font] = font
        return attributes
    }

    /// Bold/italic variant via font descriptors (thread-safe, unlike `NSFontManager`).
    static func adding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// "\t•\t" / "\t3.\t" when `block` starts a new list item.
    private static func listMarker(_ block: PresentationIntent?, previous: PresentationIntent?, lists: [Int: NSTextList]) -> String? {
        guard let components = block?.components,
              let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { return true }; return false }),
              case .listItem(let ordinal) = components[itemIndex].kind
        else { return nil }
        let item = components[itemIndex]
        guard previous?.components.contains(where: { $0.identity == item.identity }) != true,
              let list = components[(itemIndex + 1)...].first(where: { $0.kind == .orderedList || $0.kind == .unorderedList }),
              let textList = lists[list.identity]
        else { return nil }
        return "\t\(textList.marker(forItemNumber: ordinal))\t"
    }

    /// "1." rather than AppKit's bare "1".
    private static let orderedMarker = NSTextList.MarkerFormat("{decimal}.")

    /// The table cell a block sits in: one `NSTextTableBlock` per cell of a shared, thinly ruled `NSTextTable`.
    private static func tableCell(_ components: [PresentationIntent.IntentType], objects: inout TextObjects) -> (block: NSTextTableBlock, header: Bool)? {
        var column: Int?
        var row: Int?
        var header = false
        var table: (identity: Int, columns: Int)?
        for component in components {
            switch component.kind {
            case .tableCell(let index): column = index
            case .tableHeaderRow: row = 0; header = true
            case .tableRow(let index): row = index
            case .table(let columns): table = (component.identity, columns.count)
            default: break
            }
        }
        guard let column, let row, let table else { return nil }
        let textTable = objects.tables[table.identity] ?? {
            let textTable = NSTextTable()
            textTable.numberOfColumns = max(table.columns, 1)
            textTable.collapsesBorders = true
            textTable.hidesEmptyCells = false
            return textTable
        }()
        objects.tables[table.identity] = textTable
        let block = NSTextTableBlock(table: textTable, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setWidth(0.5, type: .absoluteValueType, for: .border)
        block.setBorderColor(.gray)
        block.setWidth(4, type: .absoluteValueType, for: .padding)
        return (block, header)
    }
}
