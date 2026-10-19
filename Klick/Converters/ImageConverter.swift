import AppKit
import CoreGraphics
import ImageIO

/// Raster image conversions (format changes, image → PDF).
enum ImageConverter {
    /// `Photo.jpg` → `Photo.webp` (metadata kept when the target supports it).
    static func convert(_ item: FileItem, to format: ImageFormat, progress: JobProgress) throws -> URL {
        progress.report(0.1)
        let image = try ImageIOKit.loadImage(item.url)
        try progress.checkCancelled()
        progress.report(0.5)
        let output = OutputNaming.url(for: item.url, ext: format.ext)
        try ImageIOKit.write(image, to: output, format: format, metadata: ImageIOKit.properties(item.url))
        progress.report(1)
        return output
    }

    /// Wraps the image in a single-page PDF sized from its DPI (72 dpi fallback).
    /// JPEG data is passed through untouched, so the PDF stays small.
    static func toPDF(_ item: FileItem, progress: JobProgress) throws -> URL {
        let output = OutputNaming.url(for: item.url, ext: "pdf")
        guard let ctx = CGContext(output as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Klick"] as CFDictionary) else {
            throw ImageIOKit.writeError(for: output, fallback: KlickError.failed("Couldn't create \(output.lastPathComponent)"))
        }
        progress.report(0.3)
        do {
            try drawPage(item, in: ctx)
            ctx.closePDF()
        } catch {
            ctx.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress.report(1)
        return output
    }
}

extension CGImagePropertyOrientation {
    /// Transform that maps raw pixel space to upright display space
    /// (in a bottom-left origin context of the rotated size).
    func transform(for size: CGSize) -> CGAffineTransform {
        let w = size.width, h = size.height
        switch self {
        case .up: return .identity
        case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: return .identity
        }
    }
}
