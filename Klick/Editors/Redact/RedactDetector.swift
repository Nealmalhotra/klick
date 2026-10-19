import CoreGraphics
import Vision

/// Finds text lines and faces to cover automatically.
enum RedactDetector {
    /// Areas to cover in image pixels (top-left origin), padded and in reading order.
    /// - Parameter pixelSize: the full image size the boxes are expressed in.
    static func detect(_ target: RedactTarget, in url: URL, pixelSize: CGSize) throws -> [CGRect] {
        let boxes = switch target {
        case .text: try textLines(in: url, pixelSize: pixelSize)
        case .faces: try faces(in: url, pixelSize: pixelSize)
        }
        let bounds = CGRect(origin: .zero, size: pixelSize)
        return boxes
            .map { $0.intersection(bounds) }
            .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
            .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    // MARK: Text

    /// Vision downsamples what it reads, so small print in a big frame gets lost.
    /// Small images are upscaled and read as a whole plus a grid of overlapping
    /// tiles; fragments of the same line are then joined back together.
    private static func textLines(in url: URL, pixelSize: CGSize) throws -> [CGRect] {
        let image = try upscaled(ImageIOKit.loadImage(url, maxPixelSize: 3072), toLongSide: 2400)
        let grid = 3, overlap = 0.08, tile = 1 / Double(grid)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        var regions = [unit]
        for row in 0..<grid {
            for column in 0..<grid {
                regions.append(CGRect(x: Double(column) * tile - overlap / 2, y: Double(row) * tile - overlap / 2,
                                      width: tile + overlap, height: tile + overlap).intersection(unit))
            }
        }
        let requests = regions.map { region in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.regionOfInterest = region
            return request
        }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform(requests)

        let lines = requests.flatMap { request in
            let region = request.regionOfInterest
            return (request.results ?? []).map { observation in
                let box = observation.boundingBox
                return pixelRect(CGRect(x: region.minX + box.minX * region.width, y: region.minY + box.minY * region.height,
                                        width: box.width * region.width, height: box.height * region.height), in: pixelSize)
            }
        }
        return joinedLines(lines).map {
            let pad = max(2, $0.height * 0.2)
            return $0.insetBy(dx: -pad, dy: -pad)
        }
    }

    /// Merges boxes that sit on the same line and overlap or almost touch.
    private static func joinedLines(_ boxes: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for box in boxes.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            var line = box
            while let index = lines.firstIndex(where: { sameLine($0, line) }) {
                line = line.union(lines.remove(at: index))
            }
            lines.append(line)
        }
        return lines
    }

    private static func sameLine(_ a: CGRect, _ b: CGRect) -> Bool {
        let height = min(a.height, b.height)
        let verticalOverlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let gap = max(a.minX, b.minX) - min(a.maxX, b.maxX)
        return verticalOverlap >= height * 0.6 && gap <= height * 0.3
    }

    private static func upscaled(_ image: CGImage, toLongSide target: Int) -> CGImage {
        let factor = Double(target) / Double(max(image.width, image.height))
        guard factor > 1.2 else { return image }
        let width = Int(Double(image.width) * min(factor, 3)), height = Int(Double(image.height) * min(factor, 3))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: ImageIOKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }

    // MARK: Faces

    private static func faces(in url: URL, pixelSize: CGSize) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: ImageIOKit.loadImage(url, maxPixelSize: 3072), options: [:]).perform([request])
        return (request.results ?? []).map {
            // Vision's face box stops at the brows; grow it to take in forehead and hair.
            let face = pixelRect($0.boundingBox, in: pixelSize)
            return CGRect(x: face.minX - face.width * 0.15, y: face.minY - face.height * 0.35,
                          width: face.width * 1.3, height: face.height * 1.47)
        }
    }

    /// Vision's normalized, bottom-left-origin rectangle → image pixels, top-left origin.
    private static func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: normalized.minX * size.width, y: (1 - normalized.maxY) * size.height,
               width: normalized.width * size.width, height: normalized.height * size.height)
    }
}
