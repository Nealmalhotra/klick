import AppKit
import PDFKit

/// PowerPoint and Keynote → PDF or one image per slide, rendered by Quick Look (`DocumentPreview`),
/// so neither Office nor Keynote has to be installed.
enum PresentationConverter {
    static let formats: [DocumentFormat] = [.pdf, .jpg, .png]

    /// OpenDocument presentations have no Quick Look generator on macOS.
    static func canConvert(_ item: FileItem) -> Bool {
        item.ext != "odp"
    }

    /// `Deck.pptx` → `Deck.pdf` (one page per slide), or `Deck/Deck 1.png`… for images.
    static func convert(_ item: FileItem, to format: DocumentFormat, progress: JobProgress) async throws -> [URL] {
        guard canConvert(item) else { throw KlickError.unsupported("Converting \(item.ext.uppercased()) presentations") }
        progress.report(0.05)
        let document = try await DocumentPreview.pdf(for: item, progress: progress)
        progress.report(0.8)
        if let imageFormat = format.imageFormat {
            // 2× the slide size (a 16:9 PowerPoint slide → 1920×1080), at most 3840 px wide.
            let width = document.page(at: 0)?.bounds(for: .mediaBox).width ?? 960
            let dpi = min(144, 72 * 3840 / max(width, 1))
            return try DocumentConverter.writeImages(document, for: item, format: imageFormat, dpi: dpi, progress: progress)
        }
        let output = OutputNaming.url(for: item.url, ext: "pdf")
        guard document.write(to: output) else { throw KlickError.failed("Couldn't write \(output.lastPathComponent)") }
        progress.report(1)
        return [output]
    }
}
