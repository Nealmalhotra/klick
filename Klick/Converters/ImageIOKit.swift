import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Small ImageIO toolbox shared by converters and editors.
enum ImageIOKit {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Decodes the first frame with its EXIF orientation already applied.
    /// - Parameter maxPixelSize: optional downscale (for previews).
    static func loadImage(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if SVGKit.isSVG(url) { return try SVGKit.rasterize(url, maxPixelSize: maxPixelSize) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw KlickError.unreadable(url.lastPathComponent)
        }
        let pixelSize = Self.pixelSize(of: source)
        let limit = maxPixelSize ?? max(Int(pixelSize.width), Int(pixelSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(limit, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw KlickError.unreadable(url.lastPathComponent)
        }
        return image
    }

    /// Pixel size of the first frame *after* orientation is applied.
    static func orientedPixelSize(_ url: URL) -> CGSize? {
        if SVGKit.isSVG(url) { return SVGKit.pointSize(url).map(SVGKit.rasterSize(for:)) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let size = pixelSize(of: source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = props?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? CGSize(width: size.height, height: size.width) : size
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        return CGSize(width: w, height: h)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Composites the image onto an opaque background (for JPEG/BMP).
    static func flatten(_ image: CGImage, background: CGColor = .white) -> CGImage {
        guard hasAlpha(image),
              let ctx = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(background)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// Writes `image` to `url` in `format`.
    /// - Parameters:
    ///   - metadata: properties copied from the source (orientation is reset to "up").
    static func write(_ image: CGImage, to url: URL, format: ImageFormat, quality: Double? = nil, metadata: [CFString: Any] = [:]) throws {
        let quality = quality ?? format.defaultQuality
        var image = image
        if !format.supportsAlpha { image = flatten(image) }

        if format == .webp {
            let data = try WebPEncoder.encode(image, quality: Float(quality * 100))
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw writeError(for: url, fallback: error)
            }
            return
        }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw writeError(for: url, fallback: KlickError.unsupported("Writing \(format.title)"))
        }
        var props: [CFString: Any] = [:]
        if format.supportsMetadata {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
                if let value = metadata[key] { props[key] = value }
            }
            if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        props[kCGImagePropertyOrientation] = 1
        if format == .jpg || format == .heic || format == .avif {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if format == .tiff {
            var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw writeError(for: url, fallback: KlickError.failed("Couldn't write \(url.lastPathComponent)"))
        }
    }

    /// The real reason a file couldn't be created at `url`: a read-only (or missing) folder
    /// is reported as such instead of the encoder's generic failure.
    static func writeError(for url: URL, fallback: Error) -> Error {
        let folder = url.deletingLastPathComponent()
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if !fm.fileExists(atPath: folder.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            return KlickError.failed("The folder \(folder.lastPathComponent) doesn't exist")
        }
        if !fm.isWritableFile(atPath: folder.path) {
            return KlickError.failed("Can't write to \(folder.lastPathComponent): permission denied")
        }
        if fm.fileExists(atPath: url.path), !fm.isWritableFile(atPath: url.path) {
            return KlickError.failed("Can't overwrite \(url.lastPathComponent): permission denied")
        }
        return fallback
    }

    /// Encodes to in-memory data (used for size estimates and previews).
    static func data(_ image: CGImage, format: ImageFormat, quality: Double? = nil) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(format.ext)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(image, to: tmp, format: format, quality: quality)
        return try Data(contentsOf: tmp)
    }

    /// Output format for an edited image: keep the source format when writable, else PNG.
    static func preferredOutputFormat(for url: URL) -> ImageFormat {
        guard let format = ImageFormat(fileExtension: url.pathExtension), format != .gif else { return .png }
        return format
    }

    static func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Animated GIFs: rewrites every frame (as ImageIO composites it) through a transform,
/// keeping frame delays and the loop count — and nothing else, so no metadata survives.
enum AnimatedGIF {
    static func frameCount(_ url: URL) -> Int {
        guard url.pathExtension.lowercased() == "gif",
              let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return 0 }
        return CGImageSourceGetCount(source)
    }

    static func isAnimated(_ url: URL) -> Bool { frameCount(url) > 1 }

    static func rewrite(_ url: URL, to output: URL, progress: JobProgress? = nil, transform: (CGImage) throws -> CGImage) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw KlickError.unreadable(url.lastPathComponent) }
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw ImageIOKit.writeError(for: output, fallback: KlickError.unsupported("Writing GIF"))
        }
        let fileGIF = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let loopCount = fileGIF?[kCGImagePropertyGIFLoopCount] ?? 0
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount],
        ] as CFDictionary)

        for index in 0..<count {
            try progress?.checkCancelled()
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw KlickError.unreadable(url.lastPathComponent) }
            let frameGIF = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
            var timing: [CFString: Any] = [:]
            for key in [kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFUnclampedDelayTime] {
                if let value = frameGIF[key] { timing[key] = value }
            }
            CGImageDestinationAddImage(destination, try transform(frame), [kCGImagePropertyGIFDictionary: timing] as CFDictionary)
            progress?.report(Double(index + 1) / Double(count))
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw ImageIOKit.writeError(for: output, fallback: KlickError.failed("Couldn't write \(output.lastPathComponent)"))
        }
    }
}

/// SVG input. ImageIO can't decode SVG, but AppKit can (`NSImage` uses CoreSVG), so vectors
/// are rasterized on demand — sharp, with a transparent background — or drawn as vectors into PDFs.
enum SVGKit {
    /// Long side of the raster used for conversions and editors: twice the intrinsic size,
    /// at least 2048 px, at most 8192 px.
    static let minLongSide: CGFloat = 2048
    static let maxLongSide: CGFloat = 8192

    static func isSVG(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "svg"
    }

    /// The vector, sized in points from its `width`/`height` (or `viewBox`).
    static func image(_ url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        if image.size.width <= 0 || image.size.height <= 0 { image.size = CGSize(width: 1024, height: 1024) }
        return image
    }

    /// Intrinsic size in points.
    static func pointSize(_ url: URL) -> CGSize? {
        image(url)?.size
    }

    /// Pixel size SVGs are rasterized at.
    static func rasterSize(for size: CGSize) -> CGSize {
        let longSide = max(size.width, size.height)
        let target = min(max(longSide * 2, minLongSide), maxLongSide)
        let scale = target / longSide
        return CGSize(width: max((size.width * scale).rounded(), 1), height: max((size.height * scale).rounded(), 1))
    }

    /// Renders the SVG with a transparent background.
    /// - Parameter maxPixelSize: optional cap on the long side (for previews).
    static func rasterize(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        guard let image = image(url) else { throw KlickError.unreadable(url.lastPathComponent) }
        var size = rasterSize(for: image.size)
        if let maxPixelSize, CGFloat(maxPixelSize) < max(size.width, size.height) {
            let scale = CGFloat(maxPixelSize) / max(size.width, size.height)
            size = CGSize(width: max((size.width * scale).rounded(), 1), height: max((size.height * scale).rounded(), 1))
        }
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: ImageIOKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw KlickError.failed("\(url.lastPathComponent) is too large") }
        ctx.interpolationQuality = .high
        draw(image, in: CGRect(origin: .zero, size: size), context: ctx)
        guard let raster = ctx.makeImage() else { throw KlickError.failed("Couldn't render \(url.lastPathComponent)") }
        return raster
    }

    /// Draws the vector into any context (bitmap or PDF — PDFs keep paths and text as vectors).
    static func draw(_ image: NSImage, in rect: CGRect, context ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Thin Swift wrapper over the vendored libwebp encoder (ImageIO can't write WebP).
enum WebPEncoder {
    static func encode(_ image: CGImage, quality: Float) throws -> Data {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let alpha = ImageIOKit.hasAlpha(image)

        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: ImageIOKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw KlickError.failed("Couldn't prepare pixels for WebP") }

        if alpha {
            // libwebp expects straight (non-premultiplied) RGBA.
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let a = Int(pixels[i + 3])
                guard a > 0, a < 255 else { continue }
                pixels[i] = UInt8(min(255, Int(pixels[i]) * 255 / a))
                pixels[i + 1] = UInt8(min(255, Int(pixels[i + 1]) * 255 / a))
                pixels[i + 2] = UInt8(min(255, Int(pixels[i + 2]) * 255 / a))
            }
        }

        var output: UnsafeMutablePointer<UInt8>?
        let size = pixels.withUnsafeBufferPointer { buffer in
            WebPEncodeRGBA(buffer.baseAddress, Int32(width), Int32(height), Int32(bytesPerRow), quality, &output)
        }
        defer { WebPFree(output) }
        guard size > 0, let output else { throw KlickError.failed("WebP encoding failed") }
        return Data(bytes: output, count: size)
    }
}
