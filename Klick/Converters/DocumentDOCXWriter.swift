import Foundation
import ImageIO

/// `DocumentBlock`s → WordprocessingML, for sources whose structure matters more than their fonts
/// (Markdown, HTML, plain text, e-books, Pages): Heading 1–6 styles, real Word lists from
/// `numbering.xml` (bullets and numbers, nested, restarting per list), `w:tbl` tables, clickable
/// hyperlinks, monospaced code blocks, quotes and inline images. AppKit's DOCX writer flattens all
/// of these into tab-separated paragraphs.
enum DocumentDOCXWriter {
    static func write(_ text: NSAttributedString, title: String, to url: URL) throws {
        var document = Body(contentWidth: DocumentConverter.paperSize.width * 20 - 2 * 1440)
        document.add(DocumentBlock.blocks(from: text))
        let paper = DocumentConverter.paperSize
        let body = document.xml + """
        <w:sectPr><w:pgSz w:w="\(Int(paper.width * 20))" w:h="\(Int(paper.height * 20))"/>\
        <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
        """

        var entries: [String: Data] = [
            "[Content_Types].xml": Data(contentTypes.utf8),
            "_rels/.rels": Data(packageRelationships.utf8),
            "docProps/core.xml": Data(coreProperties(title: title).utf8),
            "word/document.xml": Data((documentHeader + "<w:body>" + body + "</w:body></w:document>").utf8),
            "word/styles.xml": Data(styles.utf8),
            "word/numbering.xml": Data(numbering(document.lists).utf8),
        ]
        var relationships = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
        """
        for (id, link) in document.links {
            relationships += "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" "
                + "Target=\"\(DocumentHTMLWriter.escape(link.absoluteString))\" TargetMode=\"External\"/>"
        }
        for image in document.images {
            entries["word/media/\(image.name)"] = image.data
            relationships += "<Relationship Id=\"\(image.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(image.name)\"/>"
        }
        entries["word/_rels/document.xml.rels"] = Data((xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + relationships + "</Relationships>").utf8)
        try ZipPackage.write(entries, to: url)
    }

    // MARK: - Body

    /// Accumulates `document.xml` body markup plus the parts it references.
    private struct Body {
        let contentWidth: CGFloat // twips
        var xml = ""
        var links: [(id: String, url: URL)] = []
        var images: [(id: String, name: String, data: Data)] = []
        /// One numbering instance per list; `true` = ordered.
        var lists: [Bool] = []
        private var nextID = 3 // rId1/rId2 are styles and numbering
        private var openLists: [Int: (ordered: Bool, numID: Int)] = [:] // depth → instance

        init(contentWidth: CGFloat) {
            self.contentWidth = contentWidth
        }

        mutating func add(_ blocks: [DocumentBlock]) {
            for block in blocks {
                if case .listItem = block.kind {} else { openLists = [:] }
                switch block.kind {
                case .heading(let level):
                    paragraph(block.runs.map { var run = $0; run.bold = false; return run }, style: "Heading\(level)")
                case .paragraph:
                    paragraph(block.runs)
                case .quote:
                    paragraph(block.runs, style: "Quote")
                case .code:
                    for line in block.plainText.components(separatedBy: "\n") {
                        paragraph([DocumentBlock.Run(text: line)], style: "Code")
                    }
                case .listItem(let ordered, let depth):
                    // A list nested under a new parent item, or a change of kind, starts a new instance (and numbering).
                    openLists = openLists.filter { $0.key <= depth }
                    if openLists[depth]?.ordered != ordered {
                        lists.append(ordered)
                        openLists[depth] = (ordered, lists.count)
                    }
                    paragraph(block.runs, style: "ListParagraph", list: (openLists[depth]!.numID, min(depth, 9) - 1))
                case .table:
                    table(block.cells)
                }
            }
            if xml.hasSuffix("</w:tbl>") || xml.isEmpty { xml += "<w:p/>" } // Word wants a paragraph after a final table
        }

        private mutating func paragraph(_ runs: [DocumentBlock.Run], style: String? = nil, list: (numID: Int, level: Int)? = nil) {
            var properties = ""
            if let style { properties += "<w:pStyle w:val=\"\(style)\"/>" }
            if let list { properties += "<w:numPr><w:ilvl w:val=\"\(list.level)\"/><w:numId w:val=\"\(list.numID)\"/></w:numPr>" }
            xml += "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + inline(runs) + "</w:p>"
        }

        private mutating func table(_ rows: [[[DocumentBlock.Run]]]) {
            let columns = max(rows.map(\.count).max() ?? 1, 1)
            let width = Int(contentWidth) / columns
            // Borders repeated on the table itself: Quick Look and Pages ignore table styles.
            let border = "w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\""
            let borders = ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) \(border)/>" }.joined()
            xml += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblBorders>\(borders)</w:tblBorders>"
                + "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr><w:tblGrid>"
                + String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
            for (index, row) in rows.enumerated() {
                let header = index == 0 && rows.count > 1 && row.joined().contains { !$0.text.isEmpty }
                    && row.joined().allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                for column in 0..<columns {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/></w:tcPr>"
                    paragraph(column < row.count ? row[column] : [])
                    xml += "</w:tc>"
                }
                xml += "</w:tr>"
            }
            xml += "</w:tbl>"
        }

        private mutating func inline(_ runs: [DocumentBlock.Run]) -> String {
            var markup = ""
            for run in runs {
                if let image = run.image {
                    markup += drawing(image.data, ext: image.ext)
                    continue
                }
                var properties = run.link != nil ? "<w:rStyle w:val=\"Hyperlink\"/>" : ""
                if run.code { properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/>" }
                if run.bold { properties += "<w:b/>" }
                if run.italic { properties += "<w:i/>" }
                if run.strike { properties += "<w:strike/>" }
                if run.code { properties += "<w:sz w:val=\"20\"/>" }
                let content = "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + textMarkup(run.text) + "</w:r>"
                if let link = run.link {
                    let id = "rId\(nextID)"
                    nextID += 1
                    links.append((id, link))
                    markup += "<w:hyperlink r:id=\"\(id)\" w:history=\"1\">\(content)</w:hyperlink>"
                } else {
                    markup += content
                }
            }
            return markup
        }

        /// `w:t` pieces with tabs and line breaks as their own elements.
        private func textMarkup(_ text: String) -> String {
            var markup = ""
            var piece = ""
            func flush() {
                if !piece.isEmpty { markup += "<w:t xml:space=\"preserve\">\(DocumentHTMLWriter.escape(piece))</w:t>" }
                piece = ""
            }
            for character in text {
                switch character {
                case "\t": flush(); markup += "<w:tab/>"
                case "\n", "\u{2028}", "\r\n": flush(); markup += "<w:br/>"
                default: piece.append(character)
                }
            }
            flush()
            return markup
        }

        /// An inline picture at 96 dpi, at most as wide as the text column.
        private mutating func drawing(_ data: Data, ext: String) -> String {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int, pixelWidth > 0,
                  let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int, pixelHeight > 0
            else { return "" }
            let emuPerTwip = 635.0
            let maxWidth = Double(contentWidth) * emuPerTwip
            let scale = min(1, maxWidth / (Double(pixelWidth) * 9525))
            let cx = Int(Double(pixelWidth) * 9525 * scale)
            let cy = Int(Double(pixelHeight) * 9525 * scale)
            let number = images.count + 1
            let id = "rId\(nextID)"
            nextID += 1
            let name = "image\(number).\(ext == "jpg" ? "jpeg" : ext)"
            images.append((id, name, data))
            return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
            <wp:docPr id="\(number)" name="Picture \(number)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
            <pic:nvPicPr><pic:cNvPr id="\(number)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
        }
    }

    // MARK: - Package parts

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static let documentHeader = xmlHeader + """
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
    """

    private static let contentTypes = xmlHeader + """
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="png" ContentType="image/png"/>\
    <Default Extension="jpeg" ContentType="image/jpeg"/>\
    <Default Extension="gif" ContentType="image/gif"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    </Types>
    """

    private static let packageRelationships = xmlHeader + """
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    private static func coreProperties(title: String) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return xmlHeader + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(DocumentHTMLWriter.escape(title))</dc:title>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified>\
        </cp:coreProperties>
        """
    }

    private static var styles: String {
        let headingSizes = [32, 28, 26, 24, 22, 22] // half-points
        var headings = ""
        for (index, size) in headingSizes.enumerated() {
            headings += """
            <w:style w:type="paragraph" w:styleId="Heading\(index + 1)"><w:name w:val="heading \(index + 1)"/>\
            <w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>\
            <w:pPr><w:keepNext/><w:spacing w:before="\(index < 2 ? 360 : 240)" w:after="120"/><w:outlineLvl w:val="\(index)"/></w:pPr>\
            <w:rPr><w:b/><w:sz w:val="\(size)"/></w:rPr></w:style>
            """
        }
        return xmlHeader + """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/>\
        <w:sz w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>\
        <w:rPr><w:rFonts w:ascii="Helvetica" w:hAnsi="Helvetica" w:cs="Helvetica"/><w:sz w:val="22"/></w:rPr></w:style>\
        \(headings)\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:spacing w:after="40"/><w:contextualSpacing/></w:pPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
        <w:pPr><w:ind w:left="720"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/>\
        <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="20"/></w:rPr></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/>\
        <w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>\
        <w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/>\
        <w:pPr><w:spacing w:after="0"/></w:pPr><w:tblPr><w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="999999"/><w:left w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="999999"/><w:right w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="999999"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="999999"/>\
        </w:tblBorders></w:tblPr></w:style>\
        </w:styles>
        """
    }

    /// Abstract definition 0 is bullets, 1 is numbers (1. a. i. …); one instance per list, numbered lists restart at 1.
    private static func numbering(_ lists: [Bool]) -> String {
        func levels(ordered: Bool) -> String {
            (0..<9).map { level in
                let indent = 720 * (level + 1)
                let format = ordered ? ["decimal", "lowerLetter", "lowerRoman"][level % 3] : "bullet"
                let text = ordered ? "%\(level + 1)." : ["•", "◦", "▪"][level % 3]
                return "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/>"
                    + "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        var xml = xmlHeader + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        xml += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(ordered: false))</w:abstractNum>"
        xml += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(ordered: true))</w:abstractNum>"
        for (index, ordered) in lists.enumerated() {
            xml += "<w:num w:numId=\"\(index + 1)\"><w:abstractNumId w:val=\"\(ordered ? 1 : 0)\"/>"
            if ordered {
                xml += (0..<9).map { "<w:lvlOverride w:ilvl=\"\($0)\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" }.joined()
            }
            xml += "</w:num>"
        }
        return xml + "</w:numbering>"
    }
}
