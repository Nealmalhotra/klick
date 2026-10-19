import AppKit
import NaturalLanguage
import PDFKit

/// PDF → reflowed text: Markdown and EPUB 3. Structure (headings, paragraphs, lists, tables) comes
/// from `PDFTextLayout`; scanned pages are read with OCR.
extension PDFConverter {
    /// `Report.pdf` → `Report.md`: headings by font size, paragraphs, lists and pipe tables.
    static func toMarkdown(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        let blocks = PDFTextLayout.blocks(of: try pageTexts(of: document, item: item, progress: progress, upTo: 0.9))
        var markdown = ""
        var previous: PDFTextLayout.Block?
        for placed in blocks {
            let block = placed.block
            if case .listItem(let marker, _) = block {
                var continuesList = false
                if case .listItem(let previousMarker, _) = previous { continuesList = marker.continues(previousMarker) }
                if !markdown.isEmpty { markdown += continuesList ? "\n" : "\n\n" }
                markdown += markdownBlock(block)
            } else {
                if !markdown.isEmpty { markdown += "\n\n" }
                markdown += markdownBlock(block)
            }
            previous = block
        }
        let output = OutputNaming.url(for: item.url, ext: "md")
        try Data((markdown + "\n").utf8).write(to: output, options: .atomic)
        progress.report(1)
        return output
    }

    /// `Book.pdf` → `Book.epub`: EPUB 3 with reflowed text, one chapter per top-level heading
    /// (or per page when there are none) and a navigation document listing them.
    static func toEPUB(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        let pages = try pageTexts(of: document, item: item, progress: progress, upTo: 0.85)
        let blocks = PDFTextLayout.blocks(of: pages)
        let title = documentTitle(document) ?? item.baseName
        let language = dominantLanguage(blocks) ?? "en"
        let chapters = epubChapters(blocks, pageCount: pages.count, bookTitle: title)

        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data(EPUB.container.utf8),
            "OEBPS/style.css": Data(EPUB.stylesheet.utf8),
        ]
        var manifest = ""
        var spine = ""
        var toc = ""
        for (index, chapter) in chapters.enumerated() {
            let file = "chapter\(index + 1).xhtml"
            entries["OEBPS/\(file)"] = Data(EPUB.page(title: chapter.title, language: language, body: chapter.body).utf8)
            manifest += #"<item id="c\#(index + 1)" href="\#(file)" media-type="application/xhtml+xml"/>"#
            spine += #"<itemref idref="c\#(index + 1)"/>"#
            toc += #"<li><a href="\#(file)">\#(xmlEscaped(chapter.title))</a>"#
            if !chapter.sections.isEmpty {
                toc += "<ol>" + chapter.sections.map { #"<li><a href="\#(file)#\#($0.anchor)">\#(xmlEscaped($0.title))</a></li>"# }.joined() + "</ol>"
            }
            toc += "</li>"
        }
        entries["OEBPS/nav.xhtml"] = Data(EPUB.page(
            title: "Contents", language: language,
            body: #"<nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\#(toc)</ol></nav>"#
        ).utf8)
        var metadata = #"<dc:identifier id="book-id">urn:uuid:\#(UUID().uuidString.lowercased())</dc:identifier>"#
        metadata += "<dc:title>\(xmlEscaped(title))</dc:title><dc:language>\(language)</dc:language>"
        if let author = document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String,
           !author.trimmingCharacters(in: .whitespaces).isEmpty {
            metadata += "<dc:creator>\(xmlEscaped(author))</dc:creator>"
        }
        metadata += #"<meta property="dcterms:modified">\#(ISO8601DateFormatter().string(from: Date()))</meta>"#
        entries["OEBPS/content.opf"] = Data(EPUB.package(language: language, metadata: metadata, manifest: manifest, spine: spine).utf8)

        try progress.checkCancelled()
        let output = OutputNaming.url(for: item.url, ext: "epub")
        try ZipPackage.write(entries, to: output, storedFirst: "mimetype")
        progress.report(1)
        return output
    }

    // MARK: - Text extraction

    /// Every page's text: positioned lines, or OCR paragraphs for pages without a text layer.
    /// Reports progress up to `limit`; throws when the whole document has no text.
    static func pageTexts(of document: PDFDocument, item: FileItem, progress: JobProgress, upTo limit: Double) throws -> [PDFTextLayout.PageText] {
        let count = document.pageCount
        var pages: [PDFTextLayout.PageText] = []
        for index in 0..<count {
            try progress.checkCancelled()
            guard let page = document.page(at: index) else { continue }
            let lines = PDFTextLayout.lines(of: page)
            if lines.isEmpty {
                let image = try render(page, dpi: 200, maxPixels: 4000)
                pages.append(.recognized(try ImageConverter.recognizeParagraphs(in: image, progress: progress)))
            } else {
                pages.append(.lines(lines))
            }
            progress.report(limit * Double(index + 1) / Double(count))
        }
        guard pages.contains(where: { !$0.isEmpty }) else { throw KlickError.failed("No text found in \(item.name)") }
        return pages
    }

    /// The Title from the document info, when it's a real title rather than a file name.
    static func documentTitle(_ document: PDFDocument) -> String? {
        guard let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        let lowered = title.lowercased()
        return [".pdf", ".doc", ".docx", ".indd", "untitled", "microsoft word"].contains { lowered.contains($0) } ? nil : title
    }

    /// Escapes text for XML content and attributes, dropping characters XML can't hold.
    static func xmlEscaped(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "\t", "\n", "\r": result.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value): continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    // MARK: - Markdown

    private static func markdownBlock(_ block: PDFTextLayout.Block) -> String {
        switch block {
        case .heading(let level, let text):
            return String(repeating: "#", count: level) + " " + markdownEscaped(text, lineStart: false)
        case .paragraph(let text):
            return markdownEscaped(text)
        case .listItem(let marker, let text):
            // Numbers are written as printed (a list may start at 4); letters, which Markdown
            // can't number, stay in the text of a bullet.
            switch marker.style {
            case .number: return "\(marker.ordinal). " + markdownEscaped(text)
            case .letter: return "- \(marker.label) " + markdownEscaped(text, lineStart: false)
            case .bullet: return "- " + markdownEscaped(text)
            }
        case .table(let rows):
            let width = rows.map(\.count).max() ?? 0
            func row(_ cells: [String]) -> String {
                let padded = cells + Array(repeating: "", count: width - cells.count)
                return "| " + padded.map { markdownEscaped($0, lineStart: false).replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
            }
            let separator = "|" + Array(repeating: " --- |", count: width).joined()
            return ([row(rows[0]), separator] + rows.dropFirst().map(row)).joined(separator: "\n")
        }
    }

    /// Escapes Markdown syntax in plain text: inline markers, plus block markers at the start of a paragraph.
    private static func markdownEscaped(_ text: String, lineStart: Bool = true) -> String {
        var escaped = ""
        for character in text {
            if "\\`*_".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        guard lineStart, let first = escaped.first else { return escaped }
        if "#>+-=".contains(first) { return "\\" + escaped }
        if let dot = escaped.firstIndex(where: { !$0.isNumber }), dot != escaped.startIndex, ".)".contains(escaped[dot]) {
            escaped.insert("\\", at: dot)
        }
        return escaped
    }

    // MARK: - EPUB

    private struct Chapter {
        var title: String
        var body = ""
        var sections: [(title: String, anchor: String)] = []
    }

    /// Splits the blocks into chapters at the top heading level and renders their XHTML.
    private static func epubChapters(_ blocks: [PDFTextLayout.PlacedBlock], pageCount: Int, bookTitle: String) -> [Chapter] {
        let levels = blocks.compactMap { placed -> Int? in
            if case .heading(let level, _) = placed.block { return level }
            return nil
        }
        let topLevel = levels.min()
        var chapters: [Chapter] = []
        var openList: PDFTextLayout.ListMarker?  // last item of the list being written
        var headingCount = 0

        func closeList() {
            guard let marker = openList, !chapters.isEmpty else { return }
            chapters[chapters.count - 1].body += marker.style == .bullet ? "</ul>" : "</ol>"
            openList = nil
        }

        for placed in blocks {
            // Start a new chapter at each top-level heading, or each page when there are no headings.
            let startsChapter: Bool
            if case .heading(let level, _) = placed.block, level == topLevel {
                startsChapter = true
            } else if topLevel == nil {
                startsChapter = chapters.count <= placed.page
            } else {
                startsChapter = chapters.isEmpty
            }
            if startsChapter {
                closeList()
                var title = topLevel == nil ? "Page \(placed.page + 1)" : bookTitle
                if case .heading(_, let text) = placed.block { title = text }
                chapters.append(Chapter(title: title))
            }

            var html = ""
            if case .listItem(let marker, _) = placed.block {
                if openList.map(marker.continues) != true {
                    closeList()
                    switch marker.style {
                    case .bullet: html += "<ul>"
                    case .number: html += "<ol>"
                    case .letter: html += #"<ol type="a">"#
                    }
                }
                openList = marker
            } else {
                closeList()
            }
            switch placed.block {
            case .heading(let level, let text):
                headingCount += 1
                let anchor = "h\(headingCount)"
                let tag = "h\(min(level - (topLevel ?? 1) + 1, 6))"
                html += #"<\#(tag) id="\#(anchor)">\#(xmlEscaped(text))</\#(tag)>"#
                if level == (topLevel ?? 0) + 1 { chapters[chapters.count - 1].sections.append((text, anchor)) }
            case .paragraph(let text):
                html += "<p>\(xmlEscaped(text))</p>"
            case .listItem(let marker, let text):
                // Keeps the printed number, also for lists that start past 1.
                html += marker.style == .bullet ? "<li>" : #"<li value="\#(marker.ordinal)">"#
                html += "\(xmlEscaped(text))</li>"
            case .table(let rows):
                html += "<table>" + rows.map { row in
                    "<tr>" + row.map { "<td>\(xmlEscaped($0))</td>" }.joined() + "</tr>"
                }.joined() + "</table>"
            }
            chapters[chapters.count - 1].body += html
        }
        closeList()
        return chapters.isEmpty ? [Chapter(title: bookTitle)] : chapters
    }

    /// BCP 47 code of the text's main language.
    private static func dominantLanguage(_ blocks: [PDFTextLayout.PlacedBlock]) -> String? {
        var sample = ""
        for placed in blocks where sample.count < 4000 {
            switch placed.block {
            case .heading(_, let text), .paragraph(let text), .listItem(_, let text): sample += text + "\n"
            case .table: break
            }
        }
        return NLLanguageRecognizer.dominantLanguage(for: sample).map(\.rawValue)
    }

    /// Fixed parts of the EPUB container.
    private enum EPUB {
        static let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """

        static let stylesheet = """
        body { font-family: serif; line-height: 1.5; margin: 0 5%; }
        h1, h2, h3, h4, h5, h6 { font-family: sans-serif; line-height: 1.25; margin: 1.4em 0 0.5em; }
        p { margin: 0 0 0.8em; }
        ul, ol { margin: 0 0 0.8em; padding-left: 1.6em; }
        table { border-collapse: collapse; margin: 1em 0; width: 100%; }
        td { border: 1px solid #bbb; padding: 0.3em 0.5em; vertical-align: top; }
        tr:first-child td { font-weight: bold; background: #f2f2f2; }
        nav ol { list-style: none; padding-left: 1em; }
        """

        static func package(language: String, metadata: String, manifest: String, spine: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\(language)">\
            <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(metadata)</metadata>\
            <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\
            <item id="css" href="style.css" media-type="text/css"/>\(manifest)</manifest>\
            <spine>\(spine)</spine></package>
            """
        }

        static func page(title: String, language: String, body: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">\
            <head><meta charset="UTF-8"/><title>\(xmlEscaped(title))</title><link rel="stylesheet" type="text/css" href="style.css"/></head>\
            <body>\(body)</body></html>
            """
        }
    }
}
