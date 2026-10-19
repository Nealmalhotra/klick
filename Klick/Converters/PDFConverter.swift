import AppKit
import PDFKit

/// PDF conversions to images and text. Page tools (compress, metadata, rotate, split, merge, DOCX) live in
/// `PDFTools.swift`, Office exports (PPTX, XLSX) in `PDFOfficeExport.swift`, reflowed text (EPUB, Markdown)
/// in `PDFTextExport.swift`.
enum PDFConverter {
    /// Rendering resolution for PDF → image (300 dpi, like the original: Letter → 2550×3300).
    static let renderDPI: CGFloat = 300

    /// One image per page. A single page lands next to the PDF (`Page 001.jpg`);
    /// multiple pages go into a folder named after the document.
    static func toImages(_ item: FileItem, format: ImageFormat, progress: JobProgress) throws -> [URL] {
        guard let document = PDFDocument(url: item.url) else { throw KlickError.unreadable(item.name) }
        if document.isLocked { throw KlickError.failed("\(item.name) is password protected") }
        let count = document.pageCount
        guard count > 0 else { throw KlickError.failed("\(item.name) has no pages") }

        let folder: URL? = count > 1 ? try OutputNaming.makeFolder(named: item.baseName, in: item.directory) : nil
        var outputs: [URL] = []
        for index in 0..<count {
            try progress.checkCancelled()
            guard let page = document.page(at: index) else { continue }
            let image = try render(page, dpi: renderDPI)
            let url: URL
            if let folder {
                url = OutputNaming.url(named: "\(item.baseName) \(index + 1)", ext: format.ext, in: folder)
            } else {
                url = OutputNaming.url(for: item.url, ext: format.ext)
            }
            try ImageIOKit.write(image, to: url, format: format)
            outputs.append(url)
            progress.report(Double(index + 1) / Double(count))
        }
        return folder.map { [$0] } ?? outputs
    }

    /// Extracts the text layer into a UTF-8 `.txt`.
    static func toText(_ item: FileItem, progress: JobProgress) throws -> URL {
        guard let document = PDFDocument(url: item.url) else { throw KlickError.unreadable(item.name) }
        progress.report(0.3)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try progress.checkCancelled()
            pages.append(document.page(at: index)?.string ?? "")
            progress.report(0.3 + 0.6 * Double(index + 1) / Double(max(document.pageCount, 1)))
        }
        let output = OutputNaming.url(for: item.url, ext: "txt")
        try pages.joined(separator: "\n\n").write(to: output, atomically: true, encoding: .utf8)
        progress.report(1)
        return output
    }

    /// Page size in points as shown in a viewer: the crop box, turned by the page rotation.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 != 0 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Renders the visible part of a page (crop box) on white at the given resolution, honouring page rotation.
    /// - Parameter maxPixels: optional cap on the longest side, for poster-sized pages.
    static func render(_ page: PDFPage, dpi: CGFloat, maxPixels: CGFloat? = nil) throws -> CGImage {
        let pointSize = displaySize(of: page)
        var scale = dpi / 72
        if let maxPixels { scale = min(scale, maxPixels / max(pointSize.width, pointSize.height, 1)) }
        let width = max(Int((pointSize.width * scale).rounded()), 1)
        let height = max(Int((pointSize.height * scale).rounded()), 1)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ImageIOKit.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw KlickError.failed("Out of memory rendering page") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { throw KlickError.failed("Couldn't render page") }
        return image
    }
}
