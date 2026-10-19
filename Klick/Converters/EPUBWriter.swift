import Foundation

/// Attributed text → EPUB 3: `mimetype` stored first, `container.xml`, an OPF package, a navigation
/// document built from the headings, one XHTML chapter per top-level heading, and the images.
enum EPUBWriter {
    static func write(_ text: NSAttributedString, title: String, to url: URL) throws {
        let blocks = DocumentBlock.blocks(from: text)
        guard !blocks.isEmpty else { throw KlickError.failed("\(title) has no text") }

        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data(containerXML.utf8),
            "OEBPS/style.css": Data(stylesheet.utf8),
        ]
        var images: [(path: String, ext: String)] = []
        let chapters = chapterRanges(blocks)
        var chapterFiles: [String] = []
        var headingFile: [Int: String] = [:] // block index → chapter file
        for (number, range) in chapters.enumerated() {
            let file = "chapter-\(number + 1).xhtml"
            chapterFiles.append(file)
            for index in range { if case .heading = blocks[index].kind { headingFile[index] = file } }
            let body = DocumentHTMLWriter.body(blocks, indices: range) { data, ext in
                let path = "images/image-\(images.count + 1).\(ext)"
                entries["OEBPS/" + path] = data
                images.append((path, ext))
                return path
            }
            let chapterTitle = range.lazy.compactMap { index -> String? in
                if case .heading = blocks[index].kind { return blocks[index].plainText }
                return nil
            }.first ?? title
            entries["OEBPS/" + file] = Data(xhtml(title: chapterTitle, body: body).utf8)
        }
        entries["OEBPS/nav.xhtml"] = Data(navigation(blocks, headingFile: headingFile, title: title, firstChapter: chapterFiles[0]).utf8)
        entries["OEBPS/content.opf"] = Data(package(title: title, chapters: chapterFiles, images: images).utf8)
        try ZipPackage.write(entries, to: url, storedFirst: "mimetype")
    }

    /// Splits before every heading of the highest level present, when there are at least two of them.
    private static func chapterRanges(_ blocks: [DocumentBlock]) -> [Range<Int>] {
        let levels = blocks.compactMap { block -> Int? in
            if case .heading(let level) = block.kind { return level }
            return nil
        }
        guard let top = levels.min(), levels.filter({ $0 == top }).count > 1 else { return [blocks.indices] }
        var starts = blocks.indices.filter { blocks[$0].kind == .heading(top) }
        if starts.first != 0 { starts.insert(0, at: 0) }
        return starts.enumerated().map { offset, start in
            start..<(offset + 1 < starts.count ? starts[offset + 1] : blocks.count)
        }
    }

    // MARK: - Documents

    private static let containerXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>

    """

    private static let stylesheet = """
    body { font-family: serif; line-height: 1.4; }
    h1, h2, h3, h4, h5, h6 { font-family: sans-serif; }
    img { max-width: 100%; }
    pre { white-space: pre-wrap; font-size: 0.85em; }
    code { font-family: monospace; }
    blockquote { margin-left: 1em; font-style: italic; }
    table { border-collapse: collapse; }
    th, td { border: 1px solid #999; padding: 0.2em 0.5em; }

    """

    private static func xhtml(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(language)" lang="\(language)">
        <head>
        <meta charset="UTF-8"/>
        <title>\(DocumentHTMLWriter.escape(title))</title>
        <link rel="stylesheet" type="text/css" href="style.css"/>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    /// Table of contents: every heading, nested by level.
    private static func navigation(_ blocks: [DocumentBlock], headingFile: [Int: String], title: String, firstChapter: String) -> String {
        let headings = blocks.indices.compactMap { index -> (index: Int, level: Int)? in
            if case .heading(let level) = blocks[index].kind { return (index, level) }
            return nil
        }
        var list = ""
        if headings.isEmpty {
            list = "<ol>\n<li><a href=\"\(firstChapter)\">\(DocumentHTMLWriter.escape(title))</a></li>\n</ol>\n"
        } else {
            // Nest by relative level; same structure as the chapter lists.
            let base = headings.map(\.level).min() ?? 1
            var depth = 0
            for heading in headings {
                let level = heading.level - base + 1
                if level > depth {
                    while depth < level { list += depth == level - 1 ? "<ol>\n" : "<ol>\n<li><span>…</span>"; depth += 1 }
                } else {
                    list += "</li>\n"
                    while depth > level { list += "</ol></li>\n"; depth -= 1 }
                }
                let file = headingFile[heading.index] ?? firstChapter
                let label = DocumentHTMLWriter.escape(blocks[heading.index].plainText.trimmingCharacters(in: .whitespacesAndNewlines))
                list += "<li><a href=\"\(file)#h\(heading.index)\">\(label.isEmpty ? "…" : label)</a>"
            }
            list += "</li>\n"
            while depth > 1 { list += "</ol></li>\n"; depth -= 1 }
            list += "</ol>\n"
        }
        return xhtml(title: title, body: "<nav epub:type=\"toc\" id=\"toc\">\n<h1>Contents</h1>\n\(list)</nav>\n")
    }

    private static func package(title: String, chapters: [String], images: [(path: String, ext: String)]) -> String {
        let modified = ISO8601DateFormatter().string(from: Date()) // e.g. 2026-10-19T09:30:00Z
        var manifest = """
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>

        """
        for (index, chapter) in chapters.enumerated() {
            manifest += "    <item id=\"chapter-\(index + 1)\" href=\"\(chapter)\" media-type=\"application/xhtml+xml\"/>\n"
        }
        for (index, image) in images.enumerated() {
            manifest += "    <item id=\"image-\(index + 1)\" href=\"\(image.path)\" media-type=\"\(DocumentHTMLWriter.mimeType(image.ext))\"/>\n"
        }
        let spine = chapters.indices.map { "    <itemref idref=\"chapter-\($0 + 1)\"/>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="\(language)">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(DocumentHTMLWriter.escape(title))</dc:title>
            <dc:language>\(language)</dc:language>
            <meta property="dcterms:modified">\(modified)</meta>
          </metadata>
          <manifest>
        \(manifest)  </manifest>
          <spine>
        \(spine)
          </spine>
        </package>

        """
    }

    private static var language: String { Locale.current.language.languageCode?.identifier ?? "en" }
}
