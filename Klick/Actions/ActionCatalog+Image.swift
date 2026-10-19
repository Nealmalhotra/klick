import AppKit
import Foundation

extension ActionCatalog {
    // MARK: - Images

    /// Eight targets like the original: every raster format except the source
    /// (BMP makes room when the source is not in the list), then PDF and DOCX.
    /// SVG is input-only: all seven raster formats plus a vector PDF, no OCR.
    static func imageConvertPage(_ items: [FileItem]) -> WheelPage {
        let hasSVG = items.contains { SVGKit.isSVG($0.url) }
        let sourceFormats = Set(items.compactMap { ImageFormat(fileExtension: $0.ext) })
        var targets: [ImageFormat] = [.jpg, .png, .webp, .heic, .tiff, .avif, .bmp]
        if hasSVG {
            // Keep them all.
        } else if sourceFormats.count == 1, let source = sourceFormats.first, let index = targets.firstIndex(of: source) {
            targets.remove(at: index)
        } else {
            targets.removeAll { $0 == .bmp }
        }
        var actions = targets.map { format in
            perFile("convert.\(format.rawValue)", format.title, verb: "Converting to \(format.title)") { item, p in
                [try ImageConverter.convert(item, to: format, progress: p)]
            }
        }
        actions.append(perFile("convert.pdf", "PDF", verb: "Converting to PDF") { item, p in
            [try ImageConverter.toPDF(item, progress: p)]
        })
        if !hasSVG {
            actions.append(perFile("convert.docx", "DOCX", verb: "Extracting text to DOCX") { item, p in
                [try await ImageConverter.toDOCX(item, progress: p)]
            })
        }
        return WheelPage(id: PageID.convert, title: "Convert", actions: actions)
    }

    static func imageToolsPage(_ items: [FileItem]) -> WheelPage {
        let createPDF = batch("tool.createpdf", "CREATE PDF", symbol: "doc.badge.plus", verb: "Creating PDF") { items, p in
            [try ImageConverter.mergeToPDF(items, progress: p)]
        }
        let collage = editor("tool.collage", "COLLAGE", symbol: "rectangle.3.group") { CollageEditor.present(for: $0) }

        // Vectors have nothing to compress, strip or crop: just combine them.
        if items.contains(where: { SVGKit.isSVG($0.url) }) {
            return WheelPage(id: PageID.tools, title: "Tools", actions: items.count > 1 ? [createPDF, collage] : [])
        }

        let compress = perFile("tool.compress", "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing") { item, p in
            [try ImageConverter.compress(item, progress: p)]
        }
        let crop = editor("tool.crop", "CROP", symbol: "crop") { CropEditor.present(for: $0) }
        guard items.count == 1 else {
            return WheelPage(id: PageID.tools, title: "Tools", actions: [
                compress,
                perFile("tool.metadata", "METADATA", symbol: "tag", verb: "Removing metadata") { item, p in
                    [try ImageConverter.stripMetadata(item, progress: p)]
                },
                crop,
                createPDF,
                collage,
            ])
        }
        return WheelPage(id: PageID.tools, title: "Tools", actions: [
            compress,
            editor("tool.metadata", "METADATA", symbol: "tag") { MetadataEditor.present(for: $0[0]) },
            editor("tool.edit", "EDIT", symbol: "slider.horizontal.3") { AdjustEditor.present(for: $0[0]) },
            editor("tool.annotate", "ANNOTATE", symbol: "pencil.tip.crop.circle") { AnnotateEditor.present(for: $0[0]) },
            editor("tool.addbg", "ADD BG", symbol: "photo.artframe") { BackgroundEditor.present(for: $0[0]) },
            crop,
            editor("tool.redact", "REDACT", symbol: "eye.slash") { RedactEditor.present(for: $0[0]) },
        ])
    }
}
