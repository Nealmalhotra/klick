import CoreGraphics
import Foundation

/// Background removal for graphics: logos, icons, text, illustrations and screenshots on a plain
/// background. Subject-detection models are trained on photos and tend to keep one "object" (the
/// icon) and drop the rest (the wordmark). Graphics are instead keyed by color, like remove.bg's
/// graphic mode or a "color to alpha" filter: every element that differs from the background stays,
/// counters inside letters become transparent and anti-aliased edges are un-mixed (no halo).
enum GraphicBackgroundKeyer {
    struct RGB: Equatable {
        var r: Double, g: Double, b: Double

        /// Largest per-channel difference, 0...1.
        func distance(to other: RGB) -> Double {
            max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
        }
    }

    enum Analysis: Equatable {
        /// A plain background a graphic sits on.
        case graphic(background: RGB)
        /// The edges are already transparent: nothing to remove.
        case alreadyTransparent
        /// Photographic content: leave it to subject detection.
        case photo
        /// Plain background, but too detailed to be sure it's a graphic (e.g. a product shot).
        case plainBackgroundPhoto(background: RGB)
    }

    /// Border pixels within this distance of the dominant border color count as background.
    static let borderTolerance = 0.12
    /// Share of border pixels that must match for the background to count as plain.
    static let plainBorderShare = 0.9
    /// Graphics use few colors; photos use thousands. Counted on a 4-bit-per-channel grid.
    static let graphicColorLimit = 900
    /// Pixels this close to the background become fully transparent (absorbs JPEG noise).
    static let transparencyThreshold = 0.05
    /// Pixels this far from the background become fully opaque.
    static let opacityThreshold = 0.2

    // MARK: - Analysis

    /// Classifies the image from a small thumbnail: is it a graphic on a plain background?
    static func analyze(_ image: CGImage) -> Analysis {
        guard let thumb = RGBABuffer(image: image, maxSide: 256) else { return .photo }
        let border = thumb.borderPixels()
        let opaqueBorder = border.filter { $0.a > 0.5 }
        if Double(opaqueBorder.count) < Double(border.count) * (1 - plainBorderShare) { return .alreadyTransparent }

        let background = medianColor(opaqueBorder.map(\.rgb))
        let matching = opaqueBorder.filter { $0.rgb.distance(to: background) <= borderTolerance }.count
        guard Double(matching) >= Double(opaqueBorder.count) * plainBorderShare else { return .photo }
        return thumb.distinctColorCount() <= graphicColorLimit ? .graphic(background: background) : .plainBackgroundPhoto(background: background)
    }

    static func medianColor(_ colors: [RGB]) -> RGB {
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 1 : sorted[sorted.count / 2]
        }
        return RGB(r: median(colors.map(\.r)), g: median(colors.map(\.g)), b: median(colors.map(\.b)))
    }

    // MARK: - Keying

    /// How far (in pixels) an edge pixel looks for a solid pixel to learn the true foreground color.
    static let edgeSearchRadius = 3

    /// Returns a copy of `image` with `background` keyed out.
    static func key(_ image: CGImage, background: RGB) throws -> CGImage {
        guard var buffer = RGBABuffer(image: image, maxSide: nil) else {
            throw KlickError.failed("Couldn't read the image pixels")
        }
        let width = buffer.width, height = buffer.height
        var visible = false
        buffer.withPixels { pixels in
            let source = pixels
            let samples = source.map { RGBABuffer.sample($0) }
            let opacity = samples.map { coverage(of: $0.rgb, background: background) }
            let interior = interiorMask(opacity: opacity, width: width, height: height)
            for index in pixels.indices where samples[index].a > 0 {
                let alpha = opacity[index]
                if alpha <= 0 {
                    pixels[index] = .clear
                    continue
                }
                visible = true
                // Interior pixels keep their exact color. Boundary pixels (even "solid" ones, which can
                // still be a 30/70 mix with the background) are rebuilt from the nearest interior color.
                guard !interior[index] else { continue }
                let solid = nearestInterior(to: index, width: width, height: height, interior: interior, samples: samples)
                if solid == nil && alpha >= 1 { continue }
                pixels[index] = edgePixel(samples[index], alpha: alpha, solid: solid, background: background)
            }
        }
        guard visible else { throw KlickError.failed("Nothing is left once the background is removed") }
        guard let result = buffer.makeImage() else { throw KlickError.failed("Couldn't render the result") }
        return result
    }

    /// Opacity 0...1 of a color over the background ("color to alpha" distance), with thresholds so
    /// near-background noise vanishes and clearly different colors stay solid.
    static func coverage(of c: RGB, background bg: RGB) -> Double {
        func channel(_ value: Double, _ background: Double) -> Double {
            if value > background { return background >= 1 ? 0 : (value - background) / (1 - background) }
            if value < background { return background <= 0 ? 0 : (background - value) / background }
            return 0
        }
        let raw = max(channel(c.r, bg.r), channel(c.g, bg.g), channel(c.b, bg.b))
        return min(1, max(0, (raw - transparencyThreshold) / (opacityThreshold - transparencyThreshold)))
    }

    /// Fully opaque pixels whose 8 neighbours are fully opaque too: safely inside a shape, unmixed.
    static func interiorMask(opacity: [Double], width: Int, height: Int) -> [Bool] {
        var mask = [Bool](repeating: false, count: opacity.count)
        for y in 1..<max(1, height - 1) {
            for x in 1..<max(1, width - 1) {
                let i = y * width + x
                guard opacity[i] >= 1 else { continue }
                mask[i] = opacity[i - width - 1] >= 1 && opacity[i - width] >= 1 && opacity[i - width + 1] >= 1
                    && opacity[i - 1] >= 1 && opacity[i + 1] >= 1
                    && opacity[i + width - 1] >= 1 && opacity[i + width] >= 1 && opacity[i + width + 1] >= 1
            }
        }
        return mask
    }

    /// The closest interior pixel within `edgeSearchRadius`, if any: the true color of the shape here.
    static func nearestInterior(to index: Int, width: Int, height: Int, interior: [Bool], samples: [RGBABuffer.Sample]) -> RGB? {
        let x0 = index % width, y0 = index / width
        var best: (distance: Int, color: RGB)?
        let r = edgeSearchRadius
        for y in max(0, y0 - r)...min(height - 1, y0 + r) {
            for x in max(0, x0 - r)...min(width - 1, x0 + r) {
                let i = y * width + x
                guard interior[i] else { continue }
                let distance = (x - x0) * (x - x0) + (y - y0) * (y - y0)
                if best.map({ distance < $0.distance }) ?? true { best = (distance, samples[i].rgb) }
            }
        }
        return best?.color
    }

    /// An anti-aliased edge pixel C is a mix of the foreground F and the background B: C = a·F + (1−a)·B.
    /// With F taken from the nearest solid pixel, `a` is the projection of C−B onto F−B, which gives a
    /// clean edge in the logo's exact color (no background rim, no color shift). Without a solid
    /// neighbour (thin strokes, tiny text) the color is un-mixed using the thresholded opacity.
    static func edgePixel(_ sample: RGBABuffer.Sample, alpha: Double, solid: RGB?, background bg: RGB) -> RGBABuffer.Pixel {
        let c = sample.rgb
        let color: RGB
        let mix: Double
        if let f = solid {
            let df = (f.r - bg.r, f.g - bg.g, f.b - bg.b)
            let dc = (c.r - bg.r, c.g - bg.g, c.b - bg.b)
            let length = df.0 * df.0 + df.1 * df.1 + df.2 * df.2
            let projected = length > 0 ? (dc.0 * df.0 + dc.1 * df.1 + dc.2 * df.2) / length : alpha
            color = f
            mix = min(1, max(0, projected))
        } else {
            func unmix(_ value: Double, _ background: Double) -> Double { min(1, max(0, background + (value - background) / alpha)) }
            color = RGB(r: unmix(c.r, bg.r), g: unmix(c.g, bg.g), b: unmix(c.b, bg.b))
            mix = alpha
        }
        let finalAlpha = mix * sample.a
        func store(_ value: Double) -> UInt8 { UInt8((value * finalAlpha * 255).rounded()) }
        return RGBABuffer.Pixel(r: store(color.r), g: store(color.g), b: store(color.b), a: UInt8((finalAlpha * 255).rounded()))
    }
}

/// An sRGB, premultiplied RGBA8 copy of an image.
struct RGBABuffer {
    struct Pixel: Equatable {
        var r: UInt8, g: UInt8, b: UInt8, a: UInt8

        var a01: Double { Double(a) / 255 }

        static let clear = Pixel(r: 0, g: 0, b: 0, a: 0)
    }

    struct Sample {
        let rgb: GraphicBackgroundKeyer.RGB
        let a: Double
    }

    let width: Int
    let height: Int
    private var pixels: [Pixel]
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

    /// - Parameter maxSide: downscale so the longest side is at most this (nil = full size).
    init?(image: CGImage, maxSide: Int?) {
        let scale = maxSide.map { min(1, Double($0) / Double(max(image.width, image.height))) } ?? 1
        width = max(1, Int((Double(image.width) * scale).rounded()))
        height = max(1, Int((Double(image.height) * scale).rounded()))
        pixels = Array(repeating: Pixel(r: 0, g: 0, b: 0, a: 0), count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
    }

    mutating func withPixels(_ body: (inout [Pixel]) -> Void) { body(&pixels) }

    func makeImage() -> CGImage? {
        var copy = pixels
        return copy.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: Self.colorSpace, bitmapInfo: Self.bitmapInfo
            )?.makeImage()
        }
    }

    static func sample(_ pixel: Pixel) -> Sample {
        let a = pixel.a01
        guard a > 0 else { return Sample(rgb: .init(r: 0, g: 0, b: 0), a: 0) }
        return Sample(rgb: .init(r: Double(pixel.r) / 255 / a, g: Double(pixel.g) / 255 / a, b: Double(pixel.b) / 255 / a), a: a)
    }

    /// The outermost ring of pixels.
    func borderPixels() -> [Sample] {
        var result: [Sample] = []
        for x in 0..<width {
            result.append(Self.sample(pixels[x]))
            result.append(Self.sample(pixels[(height - 1) * width + x]))
        }
        for y in 1..<max(1, height - 1) {
            result.append(Self.sample(pixels[y * width]))
            result.append(Self.sample(pixels[y * width + width - 1]))
        }
        return result
    }

    /// Number of distinct colors among visible pixels, quantized to 4 bits per channel.
    func distinctColorCount() -> Int {
        var seen = Set<Int>()
        for pixel in pixels where pixel.a > 127 {
            let s = Self.sample(pixel)
            let r = Int(s.rgb.r * 15.999), g = Int(s.rgb.g * 15.999), b = Int(s.rgb.b * 15.999)
            seen.insert(r << 8 | g << 4 | b)
        }
        return seen.count
    }
}
