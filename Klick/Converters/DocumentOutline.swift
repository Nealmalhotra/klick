import AppKit

/// AppKit's DOCX and ODT importers drop what lives in styles and relationships: Word "Heading 1"/
/// "Title" paragraphs and ODF `<text:h>` headings arrive as body text, DOCX hyperlinks lose their
/// URL and numbered lists turn into bullets. This reads the package XML and puts them back:
/// header levels plus a bold, larger font for headings, `.link` runs, and ordered `NSTextList`s
/// with their numbers.
enum DocumentOutline {
    /// What the XML says about one paragraph.
    private struct Paragraph {
        var text: String
        var heading: Int?
        var links: [(text: String, url: URL)] = []
        /// List numbering: instance, level and format (`decimal`, `lowerLetter`…) when it isn't a bullet.
        var numbering: (id: String, level: Int, format: String)?
    }

    static func restore(from item: FileItem, in text: NSAttributedString) -> NSAttributedString {
        let paragraphs: [Paragraph]
        switch item.ext {
        case "docx", "docm", "dotx": paragraphs = wordParagraphs(item.url)
        case "odt", "ott": paragraphs = openDocumentHeadings(item.url)
        default: return text
        }
        guard !paragraphs.isEmpty else { return text }

        let result = NSMutableAttributedString(attributedString: text)
        let string = NSString(string: text.string) // a snapshot: `result` changes below
        var ranges: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            ranges.append(range)
        }
        // Both sides are in document order: match each XML paragraph within a window after the previous match.
        var matches: [(range: NSRange, paragraph: Paragraph)] = []
        var cursor = 0
        for paragraph in paragraphs where cursor < ranges.count {
            let window = ranges[cursor..<min(ranges.count, cursor + 40)]
            guard let index = window.firstIndex(where: { normalized(string.substring(with: $0)) == paragraph.text }) else { continue }
            cursor = index + 1
            matches.append((ranges[index], paragraph))
        }

        // Numbers are counted front to back; edits go back to front so earlier ranges stay valid.
        var counters: [String: [Int: Int]] = [:]
        var orderedLists: [String: NSTextList] = [:]
        var edits: [(range: NSRange, paragraph: Paragraph, list: NSTextList?, number: Int)] = []
        for match in matches {
            guard let numbering = match.paragraph.numbering else {
                edits.append((match.range, match.paragraph, nil, 0))
                continue
            }
            var levels = counters[numbering.id, default: [:]]
            levels = levels.filter { $0.key <= numbering.level }
            let number = levels[numbering.level, default: 0] + 1
            levels[numbering.level] = number
            counters[numbering.id] = levels
            let key = "\(numbering.id)/\(numbering.level)"
            let list = orderedLists[key] ?? NSTextList(markerFormat: markerFormat(numbering.format), options: 0)
            orderedLists[key] = list
            edits.append((match.range, match.paragraph, list, number))
        }
        for edit in edits.reversed() {
            for link in edit.paragraph.links {
                let found = string.range(of: link.text, options: [], range: edit.range)
                if found.location != NSNotFound { result.addAttribute(.link, value: link.url, range: found) }
            }
            if let level = edit.paragraph.heading { applyHeading(level, to: edit.range, in: result) }
            if let list = edit.list { applyOrdered(list, number: edit.number, to: edit.range, in: result) }
        }
        return result
    }

    private static func applyHeading(_ level: Int, to range: NSRange, in text: NSMutableAttributedString) {
        guard range.length > 0 else { return }
        let style = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.headerLevel = level
        style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 10)
        style.paragraphSpacing = max(style.paragraphSpacing, 4)
        text.addAttribute(.paragraphStyle, value: style, range: range)

        let scale: [CGFloat] = [1.6, 1.35, 1.17, 1.08, 1, 1]
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? MarkdownReader.bodyFont
            let size = max(font.pointSize, (font.pointSize * scale[level - 1]).rounded())
            text.addAttribute(.font, value: MarkdownReader.adding(.bold, to: font.withSize(size)), range: subrange)
        }
    }

    /// Swaps the paragraph's (bullet) list for the ordered one and its "\t•\t" marker for "\t3.\t".
    private static func applyOrdered(_ list: NSTextList, number: Int, to range: NSRange, in text: NSMutableAttributedString) {
        guard range.length > 0,
              let style = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .mutableCopy() as? NSMutableParagraphStyle,
              let current = style.textLists.last,
              !isOrdered(current)
        else { return }
        style.textLists = Array(style.textLists.dropLast()) + [list]
        text.addAttribute(.paragraphStyle, value: style, range: range)
        let paragraph = (text.string as NSString).substring(with: range)
        if let marker = paragraph.range(of: #"^\t[^\t]{0,12}\t"#, options: .regularExpression) {
            let markerRange = NSRange(marker, in: paragraph)
            let attributes = text.attributes(at: range.location, effectiveRange: nil)
            text.replaceCharacters(
                in: NSRange(location: range.location + markerRange.location, length: markerRange.length),
                with: NSAttributedString(string: "\t\(list.marker(forItemNumber: number))\t", attributes: attributes)
            )
        }
    }

    private static func isOrdered(_ list: NSTextList) -> Bool {
        ["decimal", "alpha", "roman"].contains { list.markerFormat.rawValue.contains($0) }
    }

    private static func markerFormat(_ wordFormat: String) -> NSTextList.MarkerFormat {
        switch wordFormat {
        case "lowerLetter": return NSTextList.MarkerFormat("{lower-alpha}.")
        case "upperLetter": return NSTextList.MarkerFormat("{upper-alpha}.")
        case "lowerRoman": return NSTextList.MarkerFormat("{lower-roman}.")
        case "upperRoman": return NSTextList.MarkerFormat("{upper-roman}.")
        default: return NSTextList.MarkerFormat("{decimal}.")
        }
    }

    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: #"^\t[^\t]{0,12}\t"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - DOCX

    private static func wordParagraphs(_ url: URL) -> [Paragraph] {
        guard let documentData = ZipPackage.read("word/document.xml", from: url),
              let source = String(data: documentData, encoding: .utf8),
              let document = try? XMLDocument(xmlString: protectingSpaces(source), options: [.nodePreserveWhitespace])
        else { return [] }
        let headings = headingStyles(ZipPackage.read("word/styles.xml", from: url))
        let formats = numberingFormats(ZipPackage.read("word/numbering.xml", from: url))
        let targets = relationships(ZipPackage.read("word/_rels/document.xml.rels", from: url))

        let nodes = (try? document.nodes(forXPath: "//*[local-name()='body']//*[local-name()='p']")) ?? []
        return nodes.compactMap { node -> Paragraph? in
            guard let element = node as? XMLElement else { return nil }
            let text = normalized(runText(element))
            guard !text.isEmpty else { return nil }
            var paragraph = Paragraph(text: text)
            if let style = value(element, "*[local-name()='pPr']/*[local-name()='pStyle']/@*[local-name()='val']") {
                paragraph.heading = headings[style]
            }
            if let id = value(element, "*[local-name()='pPr']/*[local-name()='numPr']/*[local-name()='numId']/@*[local-name()='val']") {
                let level = value(element, "*[local-name()='pPr']/*[local-name()='numPr']/*[local-name()='ilvl']/@*[local-name()='val']").flatMap(Int.init) ?? 0
                if let format = formats[id]?[level], format != "bullet", format != "none" {
                    paragraph.numbering = (id, level, format)
                }
            }
            for case let link as XMLElement in (try? element.nodes(forXPath: ".//*[local-name()='hyperlink']")) ?? [] {
                guard let id = value(link, "@*[local-name()='id']"), let url = targets[id] else { continue }
                let label = runText(link)
                if !label.isEmpty { paragraph.links.append((label, url)) }
            }
            return paragraph
        }
    }

    /// XMLDocument drops whitespace-only text nodes even when asked to preserve whitespace, and
    /// Word puts the spaces between differently formatted words in exactly such `<w:t> </w:t>` runs.
    private static let protectedSpace = "\u{E000}"

    private static func protectingSpaces(_ xml: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"(<w:t(?:\s[^>]*)?>)([ \t]+)(</w:t>)"#) else { return xml }
        let result = NSMutableString(string: xml)
        for match in pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).reversed() {
            let spaces = (xml as NSString).substring(with: match.range(at: 2))
            result.replaceCharacters(in: match.range(at: 2), with: String(repeating: protectedSpace, count: spaces.count))
        }
        return result as String
    }

    /// Visible text of a paragraph or hyperlink: `w:t`, tabs and breaks as spaces.
    private static func runText(_ element: XMLElement) -> String {
        let nodes = (try? element.nodes(forXPath: ".//*[local-name()='t' or local-name()='tab' or local-name()='br']")) ?? []
        return nodes.map { $0.localName == "t" ? ($0.stringValue ?? "") : " " }.joined()
            .replacingOccurrences(of: protectedSpace, with: " ")
    }

    /// Style id → heading level ("heading 1"…, "Title", or an outline level).
    private static func headingStyles(_ data: Data?) -> [String: Int] {
        guard let data, let styles = try? XMLDocument(data: data, options: []) else { return [:] }
        var levels: [String: Int] = [:]
        for case let style as XMLElement in (try? styles.nodes(forXPath: "//*[local-name()='style']")) ?? [] {
            guard let id = value(style, "@*[local-name()='styleId']") else { continue }
            let name = value(style, "*[local-name()='name']/@*[local-name()='val']")?.lowercased() ?? ""
            if name == "title" {
                levels[id] = 1
            } else if name.hasPrefix("heading "), let level = Int(name.dropFirst(8)), (1...9).contains(level) {
                levels[id] = min(level, 6)
            } else if let outline = value(style, "*[local-name()='pPr']/*[local-name()='outlineLvl']/@*[local-name()='val']").flatMap(Int.init), outline < 9 {
                levels[id] = min(outline + 1, 6)
            }
        }
        return levels
    }

    /// numId → level → numFmt, through the abstract numbering definitions.
    private static func numberingFormats(_ data: Data?) -> [String: [Int: String]] {
        guard let data, let numbering = try? XMLDocument(data: data, options: []) else { return [:] }
        var abstract: [String: [Int: String]] = [:]
        for case let definition as XMLElement in (try? numbering.nodes(forXPath: "//*[local-name()='abstractNum']")) ?? [] {
            guard let id = value(definition, "@*[local-name()='abstractNumId']") else { continue }
            var levels: [Int: String] = [:]
            for case let level as XMLElement in (try? definition.nodes(forXPath: "*[local-name()='lvl']")) ?? [] {
                guard let index = value(level, "@*[local-name()='ilvl']").flatMap(Int.init) else { continue }
                levels[index] = value(level, "*[local-name()='numFmt']/@*[local-name()='val']") ?? "decimal"
            }
            abstract[id] = levels
        }
        var formats: [String: [Int: String]] = [:]
        for case let instance as XMLElement in (try? numbering.nodes(forXPath: "//*[local-name()='num']")) ?? [] {
            guard let id = value(instance, "@*[local-name()='numId']"),
                  let abstractID = value(instance, "*[local-name()='abstractNumId']/@*[local-name()='val']")
            else { continue }
            formats[id] = abstract[abstractID]
        }
        return formats
    }

    /// Relationship id → external target (hyperlinks).
    private static func relationships(_ data: Data?) -> [String: URL] {
        guard let data, let rels = try? XMLDocument(data: data, options: []) else { return [:] }
        var targets: [String: URL] = [:]
        for case let relationship as XMLElement in (try? rels.nodes(forXPath: "//*[local-name()='Relationship']")) ?? [] {
            guard let id = value(relationship, "@Id"), let target = value(relationship, "@Target"),
                  value(relationship, "@Type")?.hasSuffix("/hyperlink") == true,
                  let url = URL(string: target)
            else { continue }
            targets[id] = url
        }
        return targets
    }

    // MARK: - ODT

    private static func openDocumentHeadings(_ url: URL) -> [Paragraph] {
        guard let data = ZipPackage.read("content.xml", from: url), let content = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]) else { return [] }
        let headings = (try? content.nodes(forXPath: "//*[local-name()='h']")) ?? []
        return headings.compactMap { node in
            guard let heading = node as? XMLElement else { return nil }
            let level = value(heading, "@*[local-name()='outline-level']").flatMap(Int.init) ?? 1
            let text = normalized(heading.stringValue ?? "")
            return text.isEmpty ? nil : Paragraph(text: text, heading: min(max(level, 1), 6))
        }
    }

    private static func value(_ element: XMLElement, _ xpath: String) -> String? {
        (try? element.nodes(forXPath: xpath))?.first?.stringValue
    }
}
