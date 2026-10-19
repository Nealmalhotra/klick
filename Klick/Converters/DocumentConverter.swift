import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Rich text document conversions: TXT, RTF(D), HTML, web archives, DOC/DOCX, ODT, Markdown, text
/// clippings and Pages in; PDF, DOCX, TXT, Markdown, HTML, EPUB, page images, RTF and ODT out.
enum DocumentConverter {
    /// `Notes.rtf` → `Notes.docx`. Styles, lists and images survive where the target supports them.
    static func convert(_ item: FileItem, to format: DocumentFormat, progress: JobProgress) async throws -> [URL] {
        progress.report(0.05)
        // Clippings may live entirely in the resource fork; packages (RTFD, Pages) report no size.
        if !item.isDirectory && !isClipping(item) && ((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0 {
            throw KlickError.failed("\(item.name) is empty")
        }
        if isPages(item) { return try await convertPages(item, to: format, progress: progress) }
        // WebKit (HTML import) only works on the main thread.
        if needsMainThread(item) {
            return try await MainActor.run { try convertNow(item, to: format, progress: progress) }
        }
        return try convertNow(item, to: format, progress: progress)
    }

    private static func convertNow(_ item: FileItem, to format: DocumentFormat, progress: JobProgress) throws -> [URL] {
        let text = try read(item)
        try progress.checkCancelled()
        progress.report(0.5)
        // Rich sources keep AppKit's DOCX writer (fonts, colours); structured ones get real Word lists and tables.
        let structured = importType(item) == nil || importType(item) == .html || importType(item) == .webArchive
        let outputs = try export(text, for: item, to: format, semanticDOCX: structured && !isClipping(item), progress: progress)
        progress.report(1)
        return outputs
    }

    /// Writes `text` next to `item` in `format` (shared with e-books).
    /// - Parameters:
    ///   - semanticHTML: clean HTML with embedded images instead of AppKit's styled export.
    ///   - semanticDOCX: `DocumentDOCXWriter` (Word lists, tables, links) instead of AppKit's writer.
    static func export(
        _ text: NSAttributedString, for item: FileItem, to format: DocumentFormat,
        semanticHTML: Bool = false, semanticDOCX: Bool = false, progress: JobProgress
    ) throws -> [URL] {
        if let imageFormat = format.imageFormat {
            // Same pages as the PDF export, rasterized like PDF → images.
            let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("klick-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: pdf) }
            try writePDF(text, to: pdf)
            guard let document = PDFDocument(url: pdf) else { throw KlickError.failed("Couldn't lay out \(item.name)") }
            return try writeImages(document, for: item, format: imageFormat, dpi: PDFConverter.renderDPI, progress: progress)
        }

        let output = OutputNaming.url(for: item.url, ext: format.ext)
        switch format {
        case .pdf: try writePDF(text, to: output)
        case .txt: try write(plainText(text), to: output)
        case .md: try write(MarkdownWriter.markdown(from: text), to: output)
        case .epub: try EPUBWriter.write(text, title: item.baseName, to: output)
        case .html where semanticHTML:
            try write(DocumentHTMLWriter.page(DocumentBlock.blocks(from: text), title: item.baseName), to: output)
        case .html: try write(text, as: .html, to: output)
        case .docx where semanticDOCX: try DocumentDOCXWriter.write(text, title: item.baseName, to: output)
        case .docx: try write(text, as: .officeOpenXML, to: output)
        case .rtf: try write(text, as: .rtf, to: output)
        case .odt: try write(text, as: .openDocument, to: output)
        case .png, .jpg: break // handled above
        }
        return [output]
    }

    /// Serializes attributed text with one of AppKit's document writers (shared with PDF/image → DOCX).
    static func write(_ text: NSAttributedString, as type: NSAttributedString.DocumentType, to url: URL) throws {
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [
                .documentType: type,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ])
            try data.write(to: url, options: .atomic)
        } catch {
            throw KlickError.failed("Couldn't write \(url.lastPathComponent)")
        }
    }

    private static func write(_ string: String, to url: URL) throws {
        do {
            try Data(string.utf8).write(to: url, options: .atomic)
        } catch {
            throw KlickError.failed("Couldn't write \(url.lastPathComponent)")
        }
    }

    /// Plain text without attachment placeholders and with list markers as "• " / "1. ".
    private static func plainText(_ text: NSAttributedString) -> String {
        text.string.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: #"(?m)^\t(\d+)\t"#, with: "$1. ", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\t([^\t\n]{1,12})\t"#, with: "$1 ", options: .regularExpression)
    }

    /// One image per page: a single page lands next to the source (`Notes.png`), several go into a
    /// folder named after it (`Notes/Notes 1.png`…), like PDF → images.
    static func writeImages(_ document: PDFDocument, for item: FileItem, format: ImageFormat, dpi: CGFloat, progress: JobProgress) throws -> [URL] {
        let count = document.pageCount
        guard count > 0 else { throw KlickError.failed("\(item.name) has no pages") }
        let start = progress.value
        let folder: URL? = count > 1 ? try OutputNaming.makeFolder(named: item.baseName, in: item.directory) : nil
        var outputs: [URL] = []
        for index in 0..<count {
            try progress.checkCancelled()
            guard let page = document.page(at: index) else { continue }
            let image = try PDFConverter.render(page, dpi: dpi)
            let url = folder.map { OutputNaming.url(named: "\(item.baseName) \(index + 1)", ext: format.ext, in: $0) }
                ?? OutputNaming.url(for: item.url, ext: format.ext)
            try ImageIOKit.write(image, to: url, format: format)
            outputs.append(url)
            progress.report(start + (1 - start) * Double(index + 1) / Double(count))
        }
        return folder.map { [$0] } ?? outputs
    }

    // MARK: - Pages

    private static func isPages(_ item: FileItem) -> Bool {
        item.ext == "pages" || item.contentType.map { type in
            ["com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages"].contains { UTType($0).map(type.conforms) == true }
        } == true
    }

    /// Pages has no public importer. Quick Look renders it page by page, so PDF and images keep the
    /// exact layout; the text formats are rebuilt from that rendering's text layer.
    private static func convertPages(_ item: FileItem, to format: DocumentFormat, progress: JobProgress) async throws -> [URL] {
        let document = try await DocumentPreview.pdf(for: item, progress: progress)
        progress.report(0.6)
        if let imageFormat = format.imageFormat {
            return try writeImages(document, for: item, format: imageFormat, dpi: PDFConverter.renderDPI, progress: progress)
        }
        if format == .pdf {
            let output = OutputNaming.url(for: item.url, ext: "pdf")
            guard document.write(to: output) else { throw KlickError.failed("Couldn't write \(output.lastPathComponent)") }
            progress.report(1)
            return [output]
        }
        let text = DocumentPreview.text(from: document)
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KlickError.failed("No text found in \(item.name)")
        }
        let outputs = try export(text, for: item, to: format, semanticDOCX: true, progress: progress)
        progress.report(1)
        return outputs
    }

    // MARK: - Reading

    private static let markdownType = UTType("net.daringfireball.markdown")

    private static func needsMainThread(_ item: FileItem) -> Bool {
        guard let type = item.contentType else { return false }
        return type.conforms(to: .html) || type.conforms(to: .webArchive) || isClipping(item)
    }

    private static func isClipping(_ item: FileItem) -> Bool {
        item.ext == "textclipping" || item.contentType?.identifier == "com.apple.finder.textclipping"
    }

    /// Loads the source as attributed text: Markdown, plain text and clippings by hand, rich formats through
    /// AppKit's importers with an explicit type (so a damaged DOCX can't silently come back as mojibake).
    private static func read(_ item: FileItem) throws -> NSAttributedString {
        let text: NSAttributedString
        if isClipping(item) {
            guard let clipping = DocumentClipping.read(item.url) else { throw KlickError.unreadable(item.name) }
            text = clipping
        } else if let type = importType(item) {
            try checkContainer(item, type: type)
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
            if type == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
            guard let imported = try? NSAttributedString(url: item.url, options: options, documentAttributes: nil) else {
                throw KlickError.unreadable(item.name)
            }
            text = addingListMarkers(to: DocumentOutline.restore(from: item, in: imported))
        } else if ["md", "markdown"].contains(item.ext) || markdownType.map({ item.contentType?.conforms(to: $0) == true }) == true {
            text = MarkdownReader.attributedString(from: try decodedText(item))
        } else {
            text = NSAttributedString(string: try decodedText(item), attributes: [.font: MarkdownReader.bodyFont])
        }
        let visible = text.string.contains { !$0.isWhitespace && $0 != "\u{FFFC}" } || text.containsAttachments(in: NSRange(location: 0, length: text.length))
        guard visible else { throw KlickError.failed("\(item.name) is empty") }
        return text
    }

    /// The AppKit importer for rich formats; nil for plain text and Markdown.
    private static func importType(_ item: FileItem) -> NSAttributedString.DocumentType? {
        switch item.ext {
        case "docx", "docm", "dotx": return .officeOpenXML
        case "doc", "dot": return .docFormat
        case "odt", "ott": return .openDocument
        case "rtf": return .rtf
        case "rtfd": return .rtfd
        case "html", "htm", "xhtml": return .html
        case "webarchive": return .webArchive
        default: break
        }
        guard let type = item.contentType else { return nil }
        if type.conforms(to: .rtfd) || type.conforms(to: .flatRTFD) { return .rtfd }
        if type.conforms(to: .rtf) { return .rtf }
        if type.conforms(to: .webArchive) { return .webArchive }
        if type.conforms(to: .html) { return .html }
        return nil
    }

    /// Cheap sanity checks before handing a file to AppKit: not empty, ZIP packages contain their main
    /// part, RTF starts like RTF, HTML is text.
    private static func checkContainer(_ item: FileItem, type: NSAttributedString.DocumentType) throws {
        if item.isDirectory { return } // RTFD package: AppKit validates it
        let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { throw KlickError.failed("\(item.name) is empty") }
        switch type {
        case .officeOpenXML:
            guard ZipPackage.read("word/document.xml", from: item.url) != nil else { throw KlickError.unreadable(item.name) }
        case .openDocument:
            guard ZipPackage.read("content.xml", from: item.url) != nil else { throw KlickError.unreadable(item.name) }
        case .rtf:
            let head = (try? FileHandle(forReadingFrom: item.url))?.readData(ofLength: 5)
            guard head == Data("{\\rtf".utf8) else { throw KlickError.unreadable(item.name) }
        case .html:
            _ = try decodedText(item)
        default:
            break
        }
    }

    /// Text files in UTF-8, UTF-16 (with or without BOM) or Latin-1/Windows-1252; binary data is rejected.
    private static func decodedText(_ item: FileItem) throws -> String {
        guard let data = try? Data(contentsOf: item.url) else { throw KlickError.unreadable(item.name) }
        guard !data.isEmpty else { throw KlickError.failed("\(item.name) is empty") }
        let bytes = [UInt8](data.prefix(4096))
        var text: String?
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else if bytes.contains(0) {
            // BOM-less UTF-16: every other byte is NUL for Latin text.
            let oddNULs = stride(from: 1, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            let evenNULs = stride(from: 0, to: bytes.count, by: 2).filter { bytes[$0] == 0 }.count
            if oddNULs > bytes.count / 4 && evenNULs == 0 {
                text = String(data: data, encoding: .utf16LittleEndian)
            } else if evenNULs > bytes.count / 4 && oddNULs == 0 {
                text = String(data: data, encoding: .utf16BigEndian)
            }
        } else {
            text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
        }
        guard var text else { throw KlickError.unreadable(item.name) }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // Control characters other than tab/newline/form feed mean it isn't text after all.
        let sample = text.unicodeScalars.prefix(4096)
        let controls = sample.filter { $0.value < 0x20 && !["\t", "\n", "\r", "\u{0C}"].contains($0) }.count
        guard controls * 50 <= max(sample.count, 1) else { throw KlickError.unreadable(item.name) }
        return text
    }

    // MARK: - Lists

    /// WebKit's HTML importer tags list paragraphs with `NSTextList`s but leaves out the marker
    /// text that TextKit 1 and AppKit's writers expect ("\t•\t", "\t3.\t"); this adds it back.
    static func addingListMarkers(to text: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        let string = result.string as NSString
        var paragraphs: [NSRange] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            paragraphs.append(range)
        }
        var numbers: [ObjectIdentifier: Int] = [:]
        // Back to front, so inserting text keeps the earlier ranges valid; numbering is counted up front.
        let items = paragraphs.compactMap { range -> (range: NSRange, list: NSTextList, style: NSParagraphStyle, number: Int)? in
            guard range.length > 0,
                  let style = result.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle,
                  let list = style.textLists.last
            else { return nil }
            let number = numbers[ObjectIdentifier(list), default: list.startingItemNumber]
            numbers[ObjectIdentifier(list)] = number + 1
            return (range, list, style, number)
        }
        for item in items.reversed() {
            let paragraph = string.substring(with: item.range)
            guard paragraph.range(of: #"^\t[^\t]{0,12}\t"#, options: .regularExpression) == nil else { continue }
            var attributes = result.attributes(at: item.range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            attributes.removeValue(forKey: .link)
            let style = item.style.mutableCopy() as! NSMutableParagraphStyle
            if !style.tabStops.contains(where: { $0.location < style.headIndent }) {
                style.tabStops = [
                    NSTextTab(textAlignment: .left, location: max(style.firstLineHeadIndent, style.headIndent - 22)),
                    NSTextTab(textAlignment: .left, location: style.headIndent),
                ]
            }
            attributes[.paragraphStyle] = style
            result.addAttribute(.paragraphStyle, value: style, range: item.range)
            // "{decimal}" alone renders a bare "3"; lists read better as "3.".
            var marker = item.list.marker(forItemNumber: item.number)
            let format = item.list.markerFormat.rawValue
            if format.hasSuffix("}") && ["decimal", "alpha", "roman"].contains(where: format.contains) { marker += "." }
            result.insert(NSAttributedString(string: "\t\(marker)\t", attributes: attributes), at: item.range.location)
        }
        return result
    }

    // MARK: - PDF

    /// Letter in the US & co., A4 elsewhere (points). Shared with the DOCX writer.
    static var paperSize: CGSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR"]
        let usesLetter = letterRegions.contains(Locale.current.region?.identifier ?? "")
        return usesLetter ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    /// Paginates the text on Letter (US & co.) or A4 paper with 1" margins and saves it as PDF.
    /// TextKit 1 lays the text out into one container per page, which is drawn straight into a
    /// PDF context (no view or print operation, so it's fast on long books and works off the main thread).
    private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let paper = paperSize
        let margin: CGFloat = 72
        let content = CGSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)

        let storage = NSTextStorage(attributedString: text)
        fitAttachments(in: storage, to: content)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var mediaBox = CGRect(origin: .zero, size: paper)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw KlickError.failed("Couldn't create \(url.lastPathComponent)")
        }
        let previousContext = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previousContext }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        let origin = CGPoint(x: margin, y: margin)
        var pages = 0
        while true {
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            let glyphs = layoutManager.glyphRange(for: container)
            guard glyphs.length > 0 || pages == 0 else { break }

            context.beginPDFPage(nil)
            context.saveGState()
            // Flipped, top-left origin like a text view.
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            context.restoreGState()
            addLinks(in: glyphs, container: container, layoutManager: layoutManager, origin: origin, pageHeight: paper.height, to: context)
            context.endPDFPage()
            pages += 1
            if NSMaxRange(glyphs) >= layoutManager.numberOfGlyphs { break }
        }
        context.closePDF()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw KlickError.failed("Couldn't create \(url.lastPathComponent)")
        }
    }

    /// Scales images down to the text area (a picture taller than a page would never fit in a container).
    private static func fitAttachments(in storage: NSTextStorage, to size: CGSize) {
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            var imageSize = attachment.bounds.size
            if imageSize == .zero {
                imageSize = attachment.image?.size
                    ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))?.size
                    ?? .zero
            }
            guard imageSize.width > 0, imageSize.height > 0 else { return }
            let scale = min(1, size.width / imageSize.width, (size.height - 2) / imageSize.height)
            if scale < 1 || attachment.bounds.size == .zero {
                attachment.bounds = CGRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
            }
        }
    }

    /// Clickable link annotations for the `.link` runs on a page.
    private static func addLinks(
        in glyphs: NSRange, container: NSTextContainer, layoutManager: NSLayoutManager,
        origin: CGPoint, pageHeight: CGFloat, to context: CGContext
    ) {
        guard let storage = layoutManager.textStorage else { return }
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.link, in: characters) { value, range, _ in
            guard let link = value as? URL ?? (value as? String).flatMap(URL.init(string:)) else { return }
            let linkGlyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: linkGlyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container
            ) { rect, _ in
                // Back to PDF space (bottom-left origin).
                let box = CGRect(x: origin.x + rect.minX, y: pageHeight - origin.y - rect.maxY, width: rect.width, height: rect.height)
                context.setURL(link as CFURL, for: box)
            }
        }
    }
}
