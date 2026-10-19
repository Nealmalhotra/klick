import AppKit
import CoreGraphics
import ImageIO
import Vision

/// Image tools that run without a window: OCR → DOCX, compression, metadata removal, images → PDF.
extension ImageConverter {
    /// `Scan.png` → `Scan.docx` with the recognized text, one Word paragraph per text block.
    static func toDOCX(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let image = try ImageIOKit.loadImage(item.url)
        progress.report(0.2)
        let paragraphs = try recognizeParagraphs(in: image, progress: progress)
        guard !paragraphs.isEmpty else { throw KlickError.failed("No text found in \(item.name)") }
        progress.report(0.9)
        let output = OutputNaming.url(for: item.url, ext: "docx")
        try DocumentConverter.write(attributedParagraphs(paragraphs), as: .officeOpenXML, to: output)
        progress.report(1)
        return output
    }

    /// `Photo.jpg` → `Photo Compressed.jpg`, never upscaled. Lossy formats are re-encoded at a lower
    /// quality, opaque PNG/TIFF/BMP become JPEG, transparent ones become a (downscaled) PNG or WebP.
    /// Steps get stronger until the result is at least 10% smaller than the original.
    static func compress(_ item: FileItem, progress: JobProgress) throws -> URL {
        if item.ext == "gif", let source = CGImageSourceCreateWithURL(item.url as CFURL, nil), CGImageSourceGetCount(source) > 1 {
            throw KlickError.unsupported("Compressing animated GIFs")
        }
        let original = try ImageIOKit.loadImage(item.url)
        let longSide = max(original.width, original.height)
        let metadata = ImageIOKit.properties(item.url)
        let steps = compressionSteps(for: item, opaque: isFullyOpaque(original))

        for (index, step) in steps.enumerated() {
            try progress.checkCancelled()
            let image = step.maxPixelSize.map { $0 < longSide } == true
                ? try ImageIOKit.loadImage(item.url, maxPixelSize: step.maxPixelSize)
                : original
            let output = OutputNaming.url(for: item.url, suffix: "Compressed", ext: step.format.ext)
            try ImageIOKit.write(image, to: output, format: step.format, quality: step.quality, metadata: metadata)
            progress.report(Double(index + 1) / Double(steps.count))

            // Only worth keeping when it saves at least 10%.
            let size = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if size > 0 && Double(size) <= Double(item.size) * 0.9 {
                let formatter = ByteCountFormatter()
                let saved = 100 - Int((Double(size) / Double(item.size) * 100).rounded())
                NSLog("%@", "Klick: compressed \(item.name) \(formatter.string(fromByteCount: item.size)) → \(formatter.string(fromByteCount: size)) (-\(saved)%) as \(step.format.title), quality \(step.quality ?? 1), max \(step.maxPixelSize ?? longSide) px")
                return output
            }
            try? FileManager.default.removeItem(at: output)
        }
        throw KlickError.failed("\(item.name) is already as small as it gets")
    }

    /// `Photo.jpg` → `Photo No Metadata.jpg`: just the pixels (orientation baked in), without
    /// EXIF, GPS, IPTC, TIFF or XMP. Formats ImageIO can't write become PNG.
    /// Animated GIFs stay animated GIFs (frames and timing kept).
    static func stripMetadata(_ item: FileItem, progress: JobProgress) throws -> URL {
        if AnimatedGIF.isAnimated(item.url) {
            let output = OutputNaming.url(for: item.url, suffix: "No Metadata", ext: "gif")
            try AnimatedGIF.rewrite(item.url, to: output, progress: progress) { $0 }
            return output
        }
        let image = try ImageIOKit.loadImage(item.url)
        try progress.checkCancelled()
        progress.report(0.5)
        let format = ImageIOKit.preferredOutputFormat(for: item.url)
        let output = OutputNaming.url(for: item.url, suffix: "No Metadata", ext: format.ext)
        try ImageIOKit.write(image, to: output, format: format)
        progress.report(1)
        return output
    }

    /// One page per image (sorted by name, like Finder) in `Images.pdf` next to the first image.
    /// Pages are sized from each image's DPI and honour EXIF orientation; JPEG data is embedded
    /// untouched and HEIC/AVIF/WebP photos are embedded as JPEG to keep the PDF small.
    static func mergeToPDF(_ items: [FileItem], progress: JobProgress) throws -> URL {
        let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let first = sorted.first else { throw KlickError.failed("Nothing to merge") }

        let output = OutputNaming.url(named: "Images", ext: "pdf", in: first.directory)
        guard let ctx = CGContext(output as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Klick"] as CFDictionary) else {
            throw ImageIOKit.writeError(for: output, fallback: KlickError.failed("Couldn't create \(output.lastPathComponent)"))
        }
        do {
            for (index, item) in sorted.enumerated() {
                try progress.checkCancelled()
                try drawPage(item, in: ctx)
                progress.report(Double(index + 1) / Double(sorted.count))
            }
            ctx.closePDF()
        } catch {
            ctx.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    // MARK: - OCR (shared with PDF → DOCX)

    /// Recognizes text with Vision (accurate, language correction, automatic language) and groups
    /// the lines into paragraphs.
    static func recognizeParagraphs(in image: CGImage, progress: JobProgress) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.progressHandler = { request, _, _ in
            if progress.isCancelled { request.cancel() }
        }
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            try progress.checkCancelled()
            throw KlickError.failed("Text recognition failed")
        }
        return paragraphs(from: lines(from: request.results ?? []))
    }

    /// Paragraphs as Word-friendly text (Helvetica 12, spacing after each paragraph).
    static func attributedParagraphs(_ paragraphs: [String]) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        return NSAttributedString(string: paragraphs.joined(separator: "\n"), attributes: [
            .font: NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12),
            .paragraphStyle: style,
        ])
    }

    // MARK: - Helpers

    private struct OCRLine {
        let text: String
        /// Normalized, bottom-left origin.
        let box: CGRect
    }

    /// Vision returns line fragments in a loose order: cluster them into rows (fragments at the same
    /// height), top to bottom, each read left to right.
    private static func lines(from observations: [VNRecognizedTextObservation]) -> [OCRLine] {
        var rows: [[OCRLine]] = []
        let fragments = observations
            .compactMap { observation in observation.topCandidates(1).first.map { OCRLine(text: $0.string, box: observation.boundingBox) } }
            .sorted { $0.box.midY > $1.box.midY }
        for fragment in fragments {
            if let last = rows.last?.last, abs(last.box.midY - fragment.box.midY) < min(last.box.height, fragment.box.height) / 2 {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
            }
        }
        return rows.map { row in
            let ordered = row.sorted { $0.box.minX < $1.box.minX }
            return OCRLine(
                text: ordered.map(\.text).joined(separator: " "),
                box: ordered.dropFirst().reduce(ordered[0].box) { $0.union($1.box) }
            )
        }
    }

    /// Joins lines into paragraphs. A new paragraph starts after a vertical gap of more than ¾ line,
    /// or after a noticeably short line ending a sentence.
    private static func paragraphs(from lines: [OCRLine]) -> [String] {
        var paragraphs: [String] = []
        var current: [OCRLine] = []
        func flush() {
            guard !current.isEmpty else { return }
            paragraphs.append(current.dropFirst().reduce(current[0].text) { text, line in
                text.hasSuffix("-") ? text + line.text : text + " " + line.text
            })
            current = []
        }
        for line in lines {
            if let previous = current.last {
                let lineHeight = min(previous.box.height, line.box.height)
                let gap = previous.box.minY - line.box.maxY
                let widest = current.map(\.box.width).max() ?? 0
                let endsSentence = previous.text.last.map { ".!?:".contains($0) } == true && previous.box.width < widest * 0.8
                if gap > lineHeight * 0.75 || endsSentence { flush() }
            }
            current.append(line)
        }
        flush()
        return paragraphs
    }

    private struct CompressionStep {
        let format: ImageFormat
        let quality: Double?
        /// Longest side cap; `nil` keeps the original size.
        let maxPixelSize: Int?
    }

    private static func compressionSteps(for item: FileItem, opaque: Bool) -> [CompressionStep] {
        switch ImageFormat(fileExtension: item.ext) {
        case let format? where [.jpg, .heic, .avif, .webp].contains(format):
            return [
                CompressionStep(format: format, quality: 0.6, maxPixelSize: nil),
                CompressionStep(format: format, quality: 0.5, maxPixelSize: 2560),
                CompressionStep(format: format, quality: 0.4, maxPixelSize: 1600),
            ]
        case _ where opaque:
            return [
                CompressionStep(format: .jpg, quality: 0.75, maxPixelSize: nil),
                CompressionStep(format: .jpg, quality: 0.6, maxPixelSize: 2560),
                CompressionStep(format: .jpg, quality: 0.45, maxPixelSize: 1600),
            ]
        default:
            return [
                CompressionStep(format: .png, quality: nil, maxPixelSize: 2560),
                CompressionStep(format: .webp, quality: 0.8, maxPixelSize: 2560),
                CompressionStep(format: .webp, quality: 0.6, maxPixelSize: 1600),
            ]
        }
    }

    /// False when the image has at least one (partly) transparent pixel.
    private static func isFullyOpaque(_ image: CGImage) -> Bool {
        guard ImageIOKit.hasAlpha(image) else { return true }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: ImageIOKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        return !stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }
    }

    /// Adds one PDF page showing `item` upright, sized from its DPI (72 dpi fallback).
    /// SVGs become a page of their intrinsic size, drawn as vectors.
    static func drawPage(_ item: FileItem, in ctx: CGContext) throws {
        if SVGKit.isSVG(item.url) {
            guard let svg = SVGKit.image(item.url) else { throw KlickError.unreadable(item.name) }
            var mediaBox = CGRect(origin: .zero, size: svg.size)
            let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            SVGKit.draw(svg, in: mediaBox, context: ctx)
            ctx.endPDFPage()
            return
        }
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw KlickError.unreadable(item.name) }
        if let format = ImageFormat(fileExtension: item.ext), [.heic, .avif, .webp].contains(format) {
            let jpeg = try ImageIOKit.data(image, format: .jpg, quality: 0.9)
            guard let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)
            else { throw KlickError.failed("Couldn't prepare \(item.name)") }
            image = decoded
        }

        let props = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let orientation = CGImagePropertyOrientation(rawValue: props[kCGImagePropertyOrientation] as? UInt32 ?? 1) ?? .up
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let scale = 72 / dpi
        let pixel = CGSize(width: image.width, height: image.height)
        let rotated = orientation.rawValue >= 5
        var mediaBox = CGRect(
            x: 0, y: 0,
            width: (rotated ? pixel.height : pixel.width) * scale,
            height: (rotated ? pixel.width : pixel.height) * scale
        )
        let boxData = Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)

        ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(orientation.transform(for: pixel))
        ctx.draw(image, in: CGRect(origin: .zero, size: pixel))
        ctx.restoreGState()
        ctx.endPDFPage()
    }
}
