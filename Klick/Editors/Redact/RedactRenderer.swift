import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Core Image side of Redact. Effect strength is proportional to the image size,
/// so the downscaled preview looks like the full-resolution result.
enum RedactRenderer {
    /// No color management: pixels outside the boxes come out exactly as they went in.
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])

    /// `image` entirely covered with `style`.
    static func effect(_ style: RedactStyle, on image: CIImage) -> CIImage {
        let extent = image.extent
        let longSide = max(extent.width, extent.height)
        switch style {
        case .black:
            return CIImage(color: .black).cropped(to: extent)
        case .blur:
            return image.clampedToExtent()
                .applyingGaussianBlur(sigma: max(4, longSide / 55))
                .cropped(to: extent)
        case .pixelate:
            // Each block takes the average around its center rather than a single sample.
            let block = max(6, longSide / 60)
            let pixellate = CIFilter.pixellate()
            pixellate.inputImage = image.clampedToExtent().applyingGaussianBlur(sigma: block / 2)
            pixellate.center = CGPoint(x: extent.minX, y: extent.maxY)
            pixellate.scale = Float(block)
            return (pixellate.outputImage ?? image).cropped(to: extent)
        }
    }

    /// The whole preview with `style` applied, for the live boxes.
    static func previewEffect(_ style: RedactStyle, for image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        return context.createCGImage(effect(style, on: input), from: input.extent, format: .RGBA8, colorSpace: outputSpace(for: image))
    }

    /// Burns the boxes into a flat copy of `image`: pixels inside them are replaced
    /// outright (not blended), so nothing of the original survives there.
    /// - Parameter boxes: rectangles in pixels, top-left origin.
    static func render(_ image: CGImage, boxes: [CGRect], style: RedactStyle) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        var mask = CIImage(color: .black).cropped(to: extent)
        for box in boxes {
            let flipped = CGRect(x: box.minX, y: extent.height - box.maxY, width: box.width, height: box.height)
            mask = CIImage(color: .white).cropped(to: flipped.integral.intersection(extent)).composited(over: mask)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = effect(style, on: input)
        blend.backgroundImage = input
        blend.maskImage = mask
        guard let output = blend.outputImage,
              let result = context.createCGImage(output, from: extent, format: .RGBA8, colorSpace: outputSpace(for: image))
        else { throw KlickError.failed("Couldn't redact the image") }
        return result
    }

    /// Writes `<name> Redacted.<ext>` next to `source`, without GPS metadata.
    /// - Parameter pixelSize: the image size the box coordinates refer to.
    static func export(_ boxes: [CGRect], style: RedactStyle, source: URL, pixelSize: CGSize) throws -> URL {
        let image = try ImageIOKit.loadImage(source)
        let sx = CGFloat(image.width) / pixelSize.width
        let sy = CGFloat(image.height) / pixelSize.height
        let scaled = boxes.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
        let redacted = try render(image, boxes: scaled, style: style)

        var metadata = ImageIOKit.properties(source)
        metadata[kCGImagePropertyGPSDictionary] = nil
        let format = ImageIOKit.preferredOutputFormat(for: source)
        let output = OutputNaming.url(for: source, suffix: "Redacted", ext: format.ext)
        try ImageIOKit.write(redacted, to: output, format: format, metadata: metadata)
        return output
    }

    private static func outputSpace(for image: CGImage) -> CGColorSpace {
        image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? ImageIOKit.sRGB
    }
}
