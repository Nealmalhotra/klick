import CoreImage
import CoreGraphics
import Foundation
import Vision

/// Removes the background of an image and saves it as a transparent PNG. Like remove.bg, it first
/// decides what kind of image it is:
/// * **Graphics** (logos, icons, text on a plain background) are keyed by color, so every element
///   is kept, letter counters turn transparent and edges are un-mixed from the background.
/// * **Photos** use the on-device Vision model behind "Lift subject from background". Nothing leaves the Mac.
enum BackgroundRemover {
    /// `Logo.jpg` → `Logo No Background.png` (full size).
    static func removeBackground(_ item: FileItem, progress: JobProgress) throws -> URL {
        let image = try ImageIOKit.loadImage(item.url)
        try progress.checkCancelled()
        progress.report(0.15)

        let cutout = try transparentVersion(of: image, name: item.name)
        try progress.checkCancelled()
        progress.report(0.85)

        let output = OutputNaming.url(for: item.url, suffix: "No Background", ext: ImageFormat.png.ext)
        try ImageIOKit.write(cutout, to: output, format: .png)
        progress.report(1)
        return output
    }

    static func transparentVersion(of image: CGImage, name: String) throws -> CGImage {
        switch GraphicBackgroundKeyer.analyze(image) {
        case .alreadyTransparent:
            throw KlickError.failed("\(name) already has a transparent background")
        case .graphic(let background):
            return try GraphicBackgroundKeyer.key(image, background: background)
        case .photo:
            return try cutOut(image, name: name)
        case .plainBackgroundPhoto(let background):
            // e.g. a product shot on white: prefer the subject model, which keeps white parts of the
            // subject; fall back to keying when it finds nothing.
            return try (try? cutOut(image, name: name)) ?? GraphicBackgroundKeyer.key(image, background: background)
        }
    }

    /// Returns `image` with every pixel outside the detected subjects made transparent.
    static func cutOut(_ image: CGImage, name: String) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            throw KlickError.failed("Couldn't analyze \(name): \(error.localizedDescription)")
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw KlickError.failed("No subject found in \(name)")
        }
        let masked: CVPixelBuffer
        do {
            masked = try observation.generateMaskedImage(
                ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false
            )
        } catch {
            throw KlickError.failed("Couldn't cut out the subject of \(name): \(error.localizedDescription)")
        }
        let ciImage = CIImage(cvPixelBuffer: masked)
        let context = CIContext(options: [.workingColorSpace: ImageIOKit.sRGB])
        guard let result = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: ImageIOKit.sRGB) else {
            throw KlickError.failed("Couldn't render the cut-out of \(name)")
        }
        return result
    }
}
