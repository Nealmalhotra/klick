import AppKit
import PDFKit

/// PDF → Office Open XML: PowerPoint (every page as a full-bleed picture) and Excel (the text
/// in rows and columns, tables detected from the text positions).
extension PDFConverter {
    /// `Deck.pdf` → `Deck.pptx`: one slide per page showing the page rendered at 300 dpi.
    /// The slide size follows the first page; pages of another shape are centered on white.
    static func toPPTX(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        let count = document.pageCount
        let slide = slideSize(for: document.page(at: 0).map(displaySize) ?? CGSize(width: 960, height: 540))

        var entries: [String: Data] = [:]
        var slideIDs = ""
        var slideRels = ""
        var slideTypes = ""
        for index in 0..<count {
            try progress.checkCancelled()
            guard let page = document.page(at: index) else { continue }
            let number = index + 1
            let image = try render(page, dpi: renderDPI, maxPixels: 6000)
            entries["ppt/media/image\(number).jpg"] = try ImageIOKit.data(image, format: .jpg, quality: 0.9)
            entries["ppt/slides/slide\(number).xml"] = Data(PPTX.slide(number: number, frame: fit(displaySize(of: page), in: slide)).utf8)
            entries["ppt/slides/_rels/slide\(number).xml.rels"] = Data(OOXML.relationships([
                ("rId1", OOXML.slideLayoutRel, "../slideLayouts/slideLayout1.xml"),
                ("rId2", OOXML.imageRel, "../media/image\(number).jpg"),
            ]).utf8)
            slideIDs += #"<p:sldId id="\#(255 + number)" r:id="rId\#(5 + number)"/>"#
            slideRels += OOXML.relationship("rId\(5 + number)", OOXML.slideRel, "slides/slide\(number).xml")
            slideTypes += OOXML.override("/ppt/slides/slide\(number).xml", "application/vnd.openxmlformats-officedocument.presentationml.slide+xml")
            progress.report(0.95 * Double(number) / Double(count))
        }

        entries["[Content_Types].xml"] = Data(OOXML.contentTypes(
            defaults: [("jpg", "image/jpeg")],
            overrides: PPTX.overrides + slideTypes
        ).utf8)
        entries["_rels/.rels"] = Data(OOXML.packageRelationships(main: "ppt/presentation.xml").utf8)
        entries["docProps/core.xml"] = Data(OOXML.coreProperties(title: documentTitle(document) ?? item.baseName).utf8)
        entries["docProps/app.xml"] = Data(OOXML.appProperties(extra: "<Slides>\(count)</Slides>").utf8)
        entries["ppt/presentation.xml"] = Data(PPTX.presentation(slideIDs: slideIDs, size: slide).utf8)
        entries["ppt/_rels/presentation.xml.rels"] = Data(OOXML.relationships([
            ("rId1", OOXML.slideMasterRel, "slideMasters/slideMaster1.xml"),
            ("rId2", OOXML.themeRel, "theme/theme1.xml"),
            ("rId3", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps", "presProps.xml"),
            ("rId4", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps", "viewProps.xml"),
            ("rId5", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles", "tableStyles.xml"),
        ], extra: slideRels).utf8)
        entries["ppt/presProps.xml"] = Data(PPTX.presProps.utf8)
        entries["ppt/viewProps.xml"] = Data(PPTX.viewProps.utf8)
        entries["ppt/tableStyles.xml"] = Data(PPTX.tableStyles.utf8)
        entries["ppt/slideMasters/slideMaster1.xml"] = Data(PPTX.slideMaster.utf8)
        entries["ppt/slideMasters/_rels/slideMaster1.xml.rels"] = Data(OOXML.relationships([
            ("rId1", OOXML.slideLayoutRel, "../slideLayouts/slideLayout1.xml"),
            ("rId2", OOXML.themeRel, "../theme/theme1.xml"),
        ]).utf8)
        entries["ppt/slideLayouts/slideLayout1.xml"] = Data(PPTX.slideLayout.utf8)
        entries["ppt/slideLayouts/_rels/slideLayout1.xml.rels"] = Data(OOXML.relationships([
            ("rId1", OOXML.slideMasterRel, "../slideMasters/slideMaster1.xml"),
        ]).utf8)
        entries["ppt/theme/theme1.xml"] = Data(OOXML.theme.utf8)

        let output = OutputNaming.url(for: item.url, ext: "pptx")
        try ZipPackage.write(entries, to: output)
        progress.report(1)
        return output
    }

    /// `Report.pdf` → `Report.xlsx`: one worksheet per page, a row per line of text. Lines with
    /// several cells (tables) are split into aligned columns; numbers are stored as numbers.
    static func toXLSX(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        let pages = try pageTexts(of: document, item: item, progress: progress, upTo: 0.85)

        var entries: [String: Data] = [:]
        var sheets = ""
        var sheetRels = ""
        var sheetTypes = ""
        for (index, page) in pages.enumerated() {
            let number = index + 1
            entries["xl/worksheets/sheet\(number).xml"] = Data(XLSX.worksheet(PDFTextLayout.rows(of: page)).utf8)
            sheets += #"<sheet name="Page \#(number)" sheetId="\#(number)" r:id="rId\#(number)"/>"#
            sheetRels += OOXML.relationship("rId\(number)", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet", "worksheets/sheet\(number).xml")
            sheetTypes += OOXML.override("/xl/worksheets/sheet\(number).xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")
        }
        try progress.checkCancelled()

        entries["[Content_Types].xml"] = Data(OOXML.contentTypes(defaults: [], overrides: XLSX.overrides + sheetTypes).utf8)
        entries["_rels/.rels"] = Data(OOXML.packageRelationships(main: "xl/workbook.xml").utf8)
        entries["docProps/core.xml"] = Data(OOXML.coreProperties(title: documentTitle(document) ?? item.baseName).utf8)
        entries["docProps/app.xml"] = Data(OOXML.appProperties(extra: "").utf8)
        entries["xl/workbook.xml"] = Data(XLSX.workbook(sheets: sheets).utf8)
        entries["xl/_rels/workbook.xml.rels"] = Data(OOXML.relationships([
            ("rId\(pages.count + 1)", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", "styles.xml"),
        ], extra: sheetRels).utf8)
        entries["xl/styles.xml"] = Data(XLSX.styles.utf8)

        let output = OutputNaming.url(for: item.url, ext: "xlsx")
        try ZipPackage.write(entries, to: output)
        progress.report(1)
        return output
    }

    // MARK: - Geometry

    /// English Metric Units per point.
    private static let emuPerPoint: CGFloat = 12_700

    /// Slide size in EMU for a page, scaled into PowerPoint's 1"–56" range when needed.
    private static func slideSize(for page: CGSize) -> CGSize {
        let size = CGSize(width: max(page.width, 1) * emuPerPoint, height: max(page.height, 1) * emuPerPoint)
        let minimum: CGFloat = 914_400, maximum: CGFloat = 51_206_400
        var scale: CGFloat = 1
        if max(size.width, size.height) > maximum { scale = maximum / max(size.width, size.height) }
        if min(size.width, size.height) * scale < minimum { scale = min(minimum / min(size.width, size.height), maximum / max(size.width, size.height)) }
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Aspect-fit frame (EMU) of a page inside the slide.
    private static func fit(_ page: CGSize, in slide: CGSize) -> CGRect {
        let scale = min(slide.width / max(page.width, 1), slide.height / max(page.height, 1))
        let size = CGSize(width: (page.width * scale).rounded(), height: (page.height * scale).rounded())
        return CGRect(x: ((slide.width - size.width) / 2).rounded(), y: ((slide.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    // MARK: - Package parts

    /// Parts shared by every Office Open XML package.
    private enum OOXML {
        static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"
        static let slideMasterRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster"
        static let slideLayoutRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout"
        static let slideRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
        static let themeRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
        static let imageRel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"

        static func override(_ part: String, _ type: String) -> String {
            #"<Override PartName="\#(part)" ContentType="\#(type)"/>"#
        }

        static func contentTypes(defaults: [(String, String)], overrides: String) -> String {
            header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
                + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
                + #"<Default Extension="xml" ContentType="application/xml"/>"#
                + defaults.map { #"<Default Extension="\#($0.0)" ContentType="\#($0.1)"/>"# }.joined()
                + override("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml")
                + override("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml")
                + overrides + "</Types>"
        }

        static func relationship(_ id: String, _ type: String, _ target: String) -> String {
            #"<Relationship Id="\#(id)" Type="\#(type)" Target="\#(target)"/>"#
        }

        static func relationships(_ items: [(String, String, String)], extra: String = "") -> String {
            header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                + items.map { relationship($0.0, $0.1, $0.2) }.joined() + extra + "</Relationships>"
        }

        static func packageRelationships(main: String) -> String {
            relationships([
                ("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", main),
                ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
                ("rId3", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties", "docProps/app.xml"),
            ])
        }

        static func coreProperties(title: String) -> String {
            let now = ISO8601DateFormatter().string(from: Date())
            return header + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
                + "<dc:title>\(xmlEscaped(title))</dc:title>"
                + #"<dcterms:created xsi:type="dcterms:W3CDTF">\#(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\#(now)</dcterms:modified>"#
                + "</cp:coreProperties>"
        }

        static func appProperties(extra: String) -> String {
            header + #"<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes">"#
                + "<Application>Klick</Application>\(extra)</Properties>"
        }

        /// The default Office color, font and format scheme (required by slide masters).
        static let theme = header + #"""
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements>\#
        <a:clrScheme name="Office"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\#
        <a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2><a:accent1><a:srgbClr val="4472C4"/></a:accent1>\#
        <a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4>\#
        <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink>\#
        <a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme>\#
        <a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\#
        <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\#
        <a:fmtScheme name="Office"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\#
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\#
        <a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\#
        <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\#
        <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\#
        <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
        """#
    }

    /// PresentationML parts: a blank master and layout, and picture slides.
    private enum PPTX {
        static let namespaces = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        static let emptyTree = #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#

        static let overrides = [
            ("/ppt/presentation.xml", "presentation.main"), ("/ppt/slideMasters/slideMaster1.xml", "slideMaster"),
            ("/ppt/slideLayouts/slideLayout1.xml", "slideLayout"), ("/ppt/presProps.xml", "presProps"),
            ("/ppt/viewProps.xml", "viewProps"), ("/ppt/tableStyles.xml", "tableStyles"),
        ].map { OOXML.override($0.0, "application/vnd.openxmlformats-officedocument.presentationml.\($0.1)+xml") }.joined()
            + OOXML.override("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml")

        static func presentation(slideIDs: String, size: CGSize) -> String {
            OOXML.header + #"<p:presentation \#(namespaces) saveSubsetFonts="1">"#
                + #"<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>"#
                + "<p:sldIdLst>\(slideIDs)</p:sldIdLst>"
                + #"<p:sldSz cx="\#(Int(size.width))" cy="\#(Int(size.height))"/><p:notesSz cx="6858000" cy="9144000"/>"#
                + "</p:presentation>"
        }

        static let presProps = OOXML.header + "<p:presentationPr \(namespaces)/>"
        static let viewProps = OOXML.header + "<p:viewPr \(namespaces)/>"
        static let tableStyles = OOXML.header + #"<a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>"#

        static let slideMaster = OOXML.header + "<p:sldMaster \(namespaces)>"
            + #"<p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\#(emptyTree)</p:spTree></p:cSld>"#
            + #"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>"#
            + #"<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>"#
            + #"<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:defRPr sz="2800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles>"#
            + "</p:sldMaster>"

        static let slideLayout = OOXML.header + #"<p:sldLayout \#(namespaces) type="blank" preserve="1">"#
            + #"<p:cSld name="Blank"><p:spTree>\#(emptyTree)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"#

        /// A slide holding one picture (relationship `rId2`) at `frame`, in EMU.
        static func slide(number: Int, frame: CGRect) -> String {
            OOXML.header + "<p:sld \(namespaces)><p:cSld><p:spTree>\(emptyTree)"
                + #"<p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \#(number)" descr="Page \#(number)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"#
                + #"<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
                + #"<p:spPr><a:xfrm><a:off x="\#(Int(frame.minX))" y="\#(Int(frame.minY))"/><a:ext cx="\#(Int(frame.width))" cy="\#(Int(frame.height))"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
                + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
        }
    }

    /// SpreadsheetML parts: inline-string worksheets with a regular and a bold cell style.
    private enum XLSX {
        static let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

        static let overrides = OOXML.override("/xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml")
            + OOXML.override("/xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml")

        static func workbook(sheets: String) -> String {
            OOXML.header + #"<workbook xmlns="\#(main)" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">"#
                + "<sheets>\(sheets)</sheets></workbook>"
        }

        static let styles = OOXML.header + #"<styleSheet xmlns="\#(main)">"#
            + #"<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>"#
            + #"<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>"#
            + #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
            + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
            + #"<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>"#
            + #"<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#

        static func worksheet(_ rows: [PDFTextLayout.Row]) -> String {
            var widths: [Int] = []
            var data = ""
            for (rowIndex, row) in rows.enumerated() {
                var cells = ""
                for (column, text) in row.cells.enumerated() where !text.isEmpty {
                    let reference = columnName(column) + String(rowIndex + 1)
                    let style = row.isBold ? #" s="1""# : ""
                    if let number = number(text) {
                        cells += #"<c r="\#(reference)"\#(style)><v>\#(number)</v></c>"#
                    } else {
                        let clipped = String(text.prefix(32_767))
                        cells += #"<c r="\#(reference)"\#(style) t="inlineStr"><is><t xml:space="preserve">\#(xmlEscaped(clipped))</t></is></c>"#
                    }
                    // Columns fit their table cells; running text (single-cell rows) overflows into the empty cells instead.
                    guard row.cells.count > 1 else { continue }
                    if widths.count <= column { widths += Array(repeating: 0, count: column + 1 - widths.count) }
                    widths[column] = max(widths[column], min(text.count, 50))
                }
                if !cells.isEmpty { data += #"<row r="\#(rowIndex + 1)">\#(cells)</row>"# }
            }
            let columns = widths.enumerated().map { index, width in
                #"<col min="\#(index + 1)" max="\#(index + 1)" width="\#(max(width + 2, 9))" customWidth="1"/>"#
            }.joined()
            return OOXML.header + #"<worksheet xmlns="\#(main)">"#
                + (columns.isEmpty ? "" : "<cols>\(columns)</cols>")
                + "<sheetData>\(data)</sheetData></worksheet>"
        }

        /// "A", "B", ..., "Z", "AA", ...
        static func columnName(_ index: Int) -> String {
            var index = index + 1
            var name = ""
            while index > 0 {
                let remainder = (index - 1) % 26
                name = String(UnicodeScalar(65 + remainder)!) + name
                index = (index - 1) / 26
            }
            return name
        }

        private static let numberPattern = try! NSRegularExpression(pattern: #"^[-+]?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$"#)

        /// The cell's value when it's a plain number ("1,200", "-3.5"); codes with leading zeros
        /// and long digit strings (IDs, phone numbers) stay text.
        static func number(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard numberPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil else { return nil }
            let digits = trimmed.filter(\.isNumber)
            guard digits.count <= 15 else { return nil }
            let unsigned = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            if unsigned.hasPrefix("0"), unsigned.count > 1, !unsigned.hasPrefix("0.") { return nil }
            guard let value = Double(trimmed.replacingOccurrences(of: ",", with: "")) else { return nil }
            return value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        }
    }
}
