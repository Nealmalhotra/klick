import AppKit
import PDFKit
import Quartz

/// PDF page tools: DOCX export, compression, metadata removal, rotation, split and merge.
extension PDFConverter {
    /// `Report.pdf` → `Report.docx`: each page's styled text with a page break in between.
    /// Pages without a text layer (scans) are OCR'd instead.
    static func toDOCX(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        let count = document.pageCount
        let text = NSMutableAttributedString()
        for index in 0..<count {
            try progress.checkCancelled()
            guard let page = document.page(at: index) else { continue }
            if index > 0 {
                // New paragraph + form feed → Word page break.
                text.append(NSAttributedString(string: text.string.hasSuffix("\n") ? "\u{0C}" : "\n\u{0C}"))
            }
            if let pageText = page.attributedString, !pageText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text.append(pageText)
            } else {
                let paragraphs = try ImageConverter.recognizeParagraphs(in: render(page, dpi: 200), progress: progress)
                text.append(ImageConverter.attributedParagraphs(paragraphs))
            }
            progress.report(0.9 * Double(index + 1) / Double(count))
        }
        guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KlickError.failed("No text found in \(item.name)")
        }
        let output = OutputNaming.url(for: item.url, ext: "docx")
        try DocumentConverter.write(text, as: .officeOpenXML, to: output)
        progress.report(1)
        return output
    }

    /// `Report.pdf` → `Report Compressed.pdf`: images re-encoded as JPEG and downsampled for screens
    /// (text and vectors stay as they are).
    static func compress(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        progress.report(0.2)
        let output = OutputNaming.url(for: item.url, suffix: "Compressed", ext: "pdf")
        // PDFKit's JPEG/screen write options leave existing image streams untouched; a Quartz filter re-encodes them.
        try write(document, to: output, options: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): reduceFileSizeFilter as Any])
        progress.report(0.9)

        let newSize = fileSize(output)
        NSLog("%@", "Klick: compressed \(item.name) \(item.size) → \(newSize) bytes")
        guard Double(newSize) <= Double(item.size) * 0.9 else { // worth it only when ≥ 10% smaller
            try? FileManager.default.removeItem(at: output)
            throw KlickError.failed("\(item.name) is already as small as it gets")
        }
        progress.report(1)
        return output
    }

    /// `Report.pdf` → `Report No Metadata.pdf`: the document info dictionary (title, author, subject,
    /// keywords, creator, producer, dates) and the XMP packet are left out; pages, links and annotations stay.
    static func removeMetadata(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        // PDFKit carries the catalog's XMP stream over when re-saving a document, so the pages first
        // move into a fresh one. Saving that adds Quartz's Producer and dates, so it's loaded once more:
        // re-saving a loaded document with empty `documentAttributes` writes no info dictionary at all.
        let fresh = PDFDocument()
        for index in 0..<document.pageCount {
            try progress.checkCancelled()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            fresh.insert(page, at: fresh.pageCount)
            progress.report(0.7 * Double(index + 1) / Double(document.pageCount))
        }
        // Bookmarks go on the fresh document: PDFKit ignores a replaced outline on a loaded one.
        fresh.outlineRoot = copyOutline(document.outlineRoot, from: document, to: fresh)
        guard let data = fresh.dataRepresentation(), let clean = PDFDocument(data: data) else {
            throw KlickError.failed("Couldn't rewrite \(item.name)")
        }
        clean.documentAttributes = [:]
        try progress.checkCancelled()
        let output = OutputNaming.url(for: item.url, suffix: "No Metadata", ext: "pdf")
        try write(clean, to: output)
        progress.report(1)
        return output
    }

    /// Rebuilds a bookmark tree for `target`, whose pages are copies of `source`'s, in the same order.
    private static func copyOutline(_ outline: PDFOutline?, from source: PDFDocument, to target: PDFDocument) -> PDFOutline? {
        guard let outline else { return nil }
        let copy = PDFOutline()
        copy.label = outline.label
        if let destination = outline.destination, let page = destination.page {
            let index = source.index(for: page)
            if index != NSNotFound, let newPage = target.page(at: index) {
                copy.destination = PDFDestination(page: newPage, at: destination.point)
            }
        } else if let action = outline.action {
            copy.action = action.copy() as? PDFAction
        }
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index).flatMap({ copyOutline($0, from: source, to: target) }) else { continue }
            copy.insertChild(child, at: copy.numberOfChildren)
        }
        copy.isOpen = outline.isOpen
        return copy
    }

    /// `Report.pdf` → `Report Rotated.pdf` with every page turned 90° clockwise.
    static func rotate(_ item: FileItem, progress: JobProgress) throws -> URL {
        let document = try openDocument(item)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = (page.rotation + 90) % 360
        }
        try progress.checkCancelled()
        progress.report(0.5)
        let output = OutputNaming.url(for: item.url, suffix: "Rotated", ext: "pdf")
        try write(document, to: output)
        progress.report(1)
        return output
    }

    /// One PDF per page in a new `Report Pages` folder (`Report 1.pdf`, `Report 2.pdf`, ...).
    static func split(_ item: FileItem, progress: JobProgress) throws -> [URL] {
        let document = try openDocument(item)
        let count = document.pageCount
        guard count > 1 else { throw KlickError.failed("\(item.name) has only one page") }

        let folder = try OutputNaming.makeFolder(named: "\(item.baseName) Pages", in: item.directory)
        for index in 0..<count {
            try progress.checkCancelled()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.documentAttributes = document.documentAttributes
            single.insert(page, at: 0)
            try write(single, to: OutputNaming.url(named: "\(item.baseName) \(index + 1)", ext: "pdf", in: folder))
            progress.report(Double(index + 1) / Double(count))
        }
        return [folder]
    }

    /// `Report.pdf` → `Report Organized.pdf` with the pages reordered, turned or left out (ORGANIZE editor).
    /// - Parameter pages: for every output page, the source page index and an extra clockwise turn in degrees.
    static func organize(_ item: FileItem, pages: [(index: Int, rotation: Int)]) throws -> URL {
        let document = try openDocument(item)
        let organized = PDFDocument()
        organized.documentAttributes = document.documentAttributes
        for (index, rotation) in pages {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + rotation) % 360 + 360) % 360
            organized.insert(page, at: organized.pageCount)
        }
        guard organized.pageCount > 0 else { throw KlickError.failed("Nothing left to save") }
        let output = OutputNaming.url(for: item.url, suffix: "Organized", ext: "pdf")
        try write(organized, to: output)
        return output
    }

    /// Appends every PDF (sorted by name, like Finder) into `Merged.pdf` next to the first one.
    static func merge(_ items: [FileItem], progress: JobProgress) throws -> URL {
        let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let first = sorted.first else { throw KlickError.failed("Nothing to merge") }

        let merged = PDFDocument()
        for (offset, item) in sorted.enumerated() {
            try progress.checkCancelled()
            let document = try openDocument(item)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
            progress.report(0.8 * Double(offset + 1) / Double(sorted.count))
        }
        let output = OutputNaming.url(named: "Merged", ext: "pdf", in: first.directory)
        try write(merged, to: output)
        progress.report(1)
        return output
    }

    // MARK: - Helpers

    /// Preview's "Reduce File Size" recipe: JPEG at 0.7, images downsampled to 144 dpi (2400 px max).
    private static let reduceFileSizeFilter = QuartzFilter(properties: [
        "Domains": ["Applications": true],
        "FilterType": 1,
        "Name": "Klick Compress",
        "FilterData": ["ColorSettings": ["ImageSettings": [
            "Compression Quality": 0.7,
            "ImageCompression": "ImageJPEGCompress",
            "ImageScaleSettings": ["ImageResolution": 144, "ImageScaleInterpolate": true, "ImageSizeMax": 2400, "ImageSizeMin": 0],
        ]]],
    ])

    static func openDocument(_ item: FileItem) throws -> PDFDocument {
        guard let document = PDFDocument(url: item.url) else { throw KlickError.unreadable(item.name) }
        if document.isLocked { throw KlickError.failed("\(item.name) is password protected") }
        guard document.pageCount > 0 else { throw KlickError.failed("\(item.name) has no pages") }
        return document
    }

    static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard document.write(to: url, withOptions: options) else {
            throw KlickError.failed("Couldn't write \(url.lastPathComponent)")
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
