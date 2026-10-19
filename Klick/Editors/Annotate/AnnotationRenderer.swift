import AppKit
import CoreGraphics
import CoreText

/// Draws annotations with Core Graphics. The canvas preview and the saved file use
/// the same code, in image-pixel coordinates with a top-left origin.
enum AnnotationRenderer {
    static func draw(_ annotations: [Annotation], in ctx: CGContext) {
        for annotation in annotations { draw(annotation, in: ctx) }
    }

    /// Burns `annotations` into a copy of `image`.
    /// - Parameter pixelSize: the image size the annotation coordinates refer to.
    static func render(_ annotations: [Annotation], over image: CGImage, pixelSize: CGSize) throws -> CGImage {
        let width = image.width, height = image.height
        let spaces = [image.colorSpace, ImageIOKit.sRGB].compactMap { $0 }.filter { $0.model == .rgb }
        guard let ctx = spaces.lazy.compactMap({
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: $0, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }).first else {
            throw KlickError.failed("Couldn't prepare the image")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: CGFloat(width) / pixelSize.width, y: -CGFloat(height) / pixelSize.height)
        draw(annotations, in: ctx)
        guard let output = ctx.makeImage() else { throw KlickError.failed("Couldn't render the annotations") }
        return output
    }

    /// Writes `<name> Annotated.<ext>` next to `source`, keeping its format and metadata.
    static func export(_ annotations: [Annotation], source: URL, pixelSize: CGSize) throws -> URL {
        let image = try ImageIOKit.loadImage(source)
        let rendered = try render(annotations, over: image, pixelSize: pixelSize)
        let format = ImageIOKit.preferredOutputFormat(for: source)
        let output = OutputNaming.url(for: source, suffix: "Annotated", ext: format.ext)
        try ImageIOKit.write(rendered, to: output, format: format, metadata: ImageIOKit.properties(source))
        return output
    }

    // MARK: Marks

    private static func draw(_ mark: Annotation, in ctx: CGContext) {
        guard let start = mark.points.first, let end = mark.points.last else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineJoin(.round)
        ctx.setLineWidth(mark.size)

        switch mark.tool {
        case .pen:
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.setLineCap(.round)
            ctx.addPath(smoothPath(through: mark.points))
            ctx.strokePath()
        case .highlighter:
            ctx.setStrokeColor(mark.color.cgColor.copy(alpha: 0.4) ?? mark.color.cgColor)
            ctx.setLineCap(.butt)
            ctx.addPath(smoothPath(through: mark.points))
            ctx.strokePath()
        case .arrow:
            let path = arrowPath(from: start, to: end, width: mark.size)
            ctx.setFillColor(mark.color.cgColor)
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.setLineWidth(mark.size * 0.35)
            ctx.addPath(path)
            ctx.drawPath(using: .fillStroke)
        case .rectangle:
            let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized
            let radius = min(mark.size * 1.2, rect.width / 2, rect.height / 2)
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        case .ellipse:
            let rect = CGRect(x: start.x, y: start.y, width: end.x - start.x, height: end.y - start.y).standardized
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.addEllipse(in: rect)
            ctx.strokePath()
        case .text:
            drawText(mark, at: start, in: ctx)
        }
    }

    /// Quadratic smoothing through the midpoints of the raw samples: steady curves
    /// without the jitter of the input. A single sample becomes a dot.
    static func smoothPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            path.addLine(to: points.last ?? first)
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// A tapered shaft ending in a swept, filled head.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let length = hypot(end.x - start.x, end.y - start.y)
        guard length > 0.5 else { return path }
        let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length

        let headLength = min(width * 4 + 4, length * 0.6)
        let headHalfWidth = headLength * 0.46
        let neck = length - headLength
        let sweep = headLength * 0.14

        func point(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(x: start.x + ux * along - uy * across, y: start.y + uy * along + ux * across)
        }
        path.move(to: point(0, width * 0.18))
        path.addLine(to: point(neck + sweep, width * 0.5))
        path.addLine(to: point(neck - sweep, headHalfWidth))
        path.addLine(to: end)
        path.addLine(to: point(neck - sweep, -headHalfWidth))
        path.addLine(to: point(neck + sweep, -width * 0.5))
        path.addLine(to: point(0, -width * 0.18))
        path.closeSubpath()
        return path
    }

    // MARK: Text

    /// Bold rounded system font used for labels.
    static func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let font = font(size: fontSize)
        return font.ascender - font.descender
    }

    /// Bounds of a label in image pixels.
    static func textBounds(of mark: Annotation) -> CGRect {
        guard let origin = mark.points.first else { return .null }
        let width = CTLineGetTypographicBounds(line(mark.text, fontSize: mark.size), nil, nil, nil)
        return CGRect(x: origin.x, y: origin.y, width: width, height: lineHeight(fontSize: mark.size))
    }

    /// Width of `text` in image pixels.
    static func textWidth(_ text: String, fontSize: CGFloat) -> CGFloat {
        CTLineGetTypographicBounds(line(text, fontSize: fontSize), nil, nil, nil)
    }

    private static func line(_ text: String, fontSize: CGFloat) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(size: fontSize),
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Text with a contrasting halo: stroked first, then filled on top.
    private static func drawText(_ mark: Annotation, at origin: CGPoint, in ctx: CGContext) {
        guard !mark.text.isEmpty else { return }
        let line = line(mark.text, fontSize: mark.size)
        ctx.translateBy(x: origin.x, y: origin.y + font(size: mark.size).ascender)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        ctx.setLineWidth(mark.size * 0.16)
        ctx.setStrokeColor(mark.color.outline)
        ctx.setFillColor(mark.color.cgColor)
        for mode in [CGTextDrawingMode.stroke, .fill] {
            ctx.setTextDrawingMode(mode)
            ctx.textPosition = .zero // drawing advances it
            CTLineDraw(line, ctx)
        }
    }
}
