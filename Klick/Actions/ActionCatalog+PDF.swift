import AppKit
import Foundation

extension ActionCatalog {
    // MARK: - PDF

    /// Eight targets like the original (PAGES is left out: there's no native writer for it).
    static func pdfConvertPage(_ items: [FileItem]) -> WheelPage {
        WheelPage(id: PageID.convert, title: "Convert", actions: [
            perFile("convert.docx", "DOCX", verb: "Converting to DOCX") { item, p in [try PDFConverter.toDOCX(item, progress: p)] },
            perFile("convert.pptx", "PPTX", verb: "Converting to PPTX") { item, p in [try PDFConverter.toPPTX(item, progress: p)] },
            perFile("convert.xlsx", "XLSX", verb: "Converting to XLSX") { item, p in [try PDFConverter.toXLSX(item, progress: p)] },
            perFile("convert.jpg", "JPG", verb: "Converting to JPG") { item, p in try PDFConverter.toImages(item, format: .jpg, progress: p) },
            perFile("convert.png", "PNG", verb: "Converting to PNG") { item, p in try PDFConverter.toImages(item, format: .png, progress: p) },
            perFile("convert.epub", "EPUB", verb: "Converting to EPUB") { item, p in [try PDFConverter.toEPUB(item, progress: p)] },
            perFile("convert.txt", "TXT", verb: "Converting to TXT") { item, p in [try PDFConverter.toText(item, progress: p)] },
            perFile("convert.md", "MD", verb: "Converting to Markdown") { item, p in [try PDFConverter.toMarkdown(item, progress: p)] },
        ])
    }

    /// One PDF: compress, metadata, split, organize (+ rotate). Several: compress, metadata, split, merge.
    static func pdfToolsPage(_ items: [FileItem]) -> WheelPage {
        var actions: [KlickAction] = [
            perFile("tool.compress", "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing") { item, p in
                [try PDFConverter.compress(item, progress: p)]
            },
            perFile("tool.metadata", "METADATA", symbol: "tag", verb: "Removing metadata") { item, p in
                [try PDFConverter.removeMetadata(item, progress: p)]
            },
            perFile("tool.split", "SPLIT", symbol: "rectangle.split.2x1", verb: "Splitting pages") { item, p in
                try PDFConverter.split(item, progress: p)
            },
        ]
        if items.count > 1 {
            actions.append(batch("tool.merge", "MERGE PDF", symbol: "doc.on.doc", verb: "Merging PDFs") { items, p in
                [try PDFConverter.merge(items, progress: p)]
            })
        } else {
            actions.append(editor("tool.organize", "ORGANIZE", symbol: "square.grid.2x2") { OrganizePDFEditor.present(for: $0[0]) })
            actions.append(perFile("tool.rotate", "ROTATE", symbol: "rotate.right", verb: "Rotating") { item, p in
                [try PDFConverter.rotate(item, progress: p)]
            })
        }
        return WheelPage(id: PageID.tools, title: "Tools", actions: actions)
    }
}
