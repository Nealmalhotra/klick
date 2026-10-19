import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Tonal and color values of the Edit editor. Every value is 0 when untouched.
struct ImageAdjustments: Equatable {
    var exposure = 0.0   // EV, −2…2
    var contrast = 0.0   // −100…100
    var highlights = 0.0 // −100…100
    var shadows = 0.0    // −100…100
    var saturation = 0.0 // −100…100
    var vibrance = 0.0   // −100…100
    var warmth = 0.0     // −100…100
    var tint = 0.0       // −100…100 (green … magenta)
    var sharpness = 0.0  // 0…100
    var vignette = 0.0   // 0…100

    var isNeutral: Bool { self == ImageAdjustments() }
}

/// Rotation and mirroring, expressed in *display* space and accumulated so
/// SwiftUI always animates in the direction of the button that was pressed.
struct ImageGeometry: Equatable {
    /// Clockwise degrees, multiples of 90.
    var rotation = 0.0
    /// Mirror around the vertical / horizontal axis, in 180° steps (drives a card-flip animation).
    var flipX = 0.0
    var flipY = 0.0

    var isIdentity: Bool { quarterTurns == 0 && !mirroredX && !mirroredY }

    var quarterTurns: Int { (Int((rotation / 90).rounded()) % 4 + 4) % 4 }
    var mirroredX: Bool { Int((flipX / 180).rounded()) % 2 != 0 }
    var mirroredY: Bool { Int((flipY / 180).rounded()) % 2 != 0 }

    /// Rotates by 90° as seen on screen. The rotation sits *inside* the mirrors,
    /// so with a single mirror applied the inner angle has to turn the other way.
    mutating func rotate(clockwise: Bool) {
        let mirrored = mirroredX != mirroredY
        rotation += clockwise != mirrored ? 90 : -90
    }

    mutating func flipHorizontally() { flipX += 180 }
    mutating func flipVertically() { flipY += 180 }

    /// Back to identity along the shortest path, so an animated reset never spins twice.
    mutating func reset() {
        rotation = (rotation / 360).rounded() * 360
        flipX = (flipX / 360).rounded() * 360
        flipY = (flipY / 360).rounded() * 360
    }

    /// Applies the same transform the preview shows: rotate, then mirror.
    func apply(to image: CIImage) -> CIImage {
        let rotations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var result = image.oriented(rotations[quarterTurns])
        if mirroredX { result = result.oriented(.upMirrored) }
        if mirroredY { result = result.oriented(.downMirrored) }
        return result
    }
}

/// Core Image pipeline shared by the live preview and the full-resolution save.
/// Immutable apart from its `CIContext`, which is thread-safe.
final class AdjustRenderer: @unchecked Sendable {
    private let context = CIContext(options: [.cacheIntermediates: false, .name: "Klick Edit"])

    /// Spatial effects (sharpening, vignette) are sized relative to the image so the
    /// ~1000 px preview looks like the full-resolution result.
    private static let referenceLongSide = 1000.0

    func filtered(_ source: CIImage, with values: ImageAdjustments) -> CIImage {
        let extent = source.extent
        let scale = max(extent.width, extent.height) / Self.referenceLongSide
        var image = source.clampedToExtent()

        if values.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(values.exposure)
            image = filter.outputImage ?? image
        }

        if values.warmth != 0 || values.tint != 0 {
            // A warmer source white point means the result is rendered warmer.
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 1_000_000 / (153.85 - values.warmth * 0.7), y: values.tint * 0.4)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }

        if values.highlights < 0 || values.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 + min(values.highlights, 0) / 100 * 0.6)
            filter.shadowAmount = Float(values.shadows / 100 * (values.shadows > 0 ? 0.9 : 0.5))
            image = filter.outputImage ?? image
        }

        if values.contrast != 0 || values.highlights > 0 {
            image = toneCurve(image, contrast: values.contrast / 100, highlights: max(values.highlights, 0) / 100)
        }

        if values.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(1 + values.saturation / 100)
            filter.contrast = 1
            filter.brightness = 0
            image = filter.outputImage ?? image
        }

        if values.vibrance != 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = image
            filter.amount = Float(values.vibrance / 100)
            image = filter.outputImage ?? image
        }

        if values.sharpness > 0 {
            let filter = CIFilter.sharpenLuminance()
            filter.inputImage = image
            filter.sharpness = Float(values.sharpness / 100 * 0.8)
            filter.radius = Float(1.5 * max(scale, 1))
            image = filter.outputImage ?? image
        }

        if values.vignette > 0 {
            let filter = CIFilter.vignetteEffect()
            filter.inputImage = image
            filter.center = CGPoint(x: extent.midX, y: extent.midY)
            filter.radius = Float(hypot(extent.width, extent.height) * 0.42)
            filter.intensity = Float(values.vignette / 100)
            filter.falloff = 0.65
            image = filter.outputImage ?? image
        }

        return image.cropped(to: extent)
    }

    /// S-curve for contrast (negative values fade blacks and whites), plus an
    /// upper-curve lift for positive highlights, which CIHighlightShadowAdjust can't do.
    private func toneCurve(_ image: CIImage, contrast: Double, highlights: Double) -> CIImage {
        let fade = max(-contrast, 0) * 0.06
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0, y: fade)
        filter.point1 = CGPoint(x: 0.25, y: 0.25 - contrast * 0.07 + highlights * 0.01)
        filter.point2 = CGPoint(x: 0.5, y: 0.5 + highlights * 0.04)
        filter.point3 = CGPoint(x: 0.75, y: 0.75 + contrast * 0.07 + highlights * 0.09)
        filter.point4 = CGPoint(x: 1, y: 1 - fade)
        return filter.outputImage ?? image
    }

    /// Renders to a bitmap in the source color space (sRGB when it isn't RGB).
    /// Opaque sources stay opaque so PNG/TIFF/HEIC outputs don't gain an alpha channel.
    func makeImage(_ image: CIImage, colorSpace: CGColorSpace?, opaque: Bool) -> CGImage? {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? ImageIOKit.sRGB
        let extent = image.extent.integral
        guard opaque else {
            return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: space)
        }
        guard let bitmap = CGContext(
            data: nil, width: Int(extent.width), height: Int(extent.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let data = bitmap.data else { return nil }
        context.render(image, toBitmap: data, rowBytes: bitmap.bytesPerRow, bounds: extent, format: .RGBA8, colorSpace: space)
        return bitmap.makeImage()
    }
}
