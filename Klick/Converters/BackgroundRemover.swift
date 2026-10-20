import CoreImage
import CoreGraphics
import Foundation
import Vision

/// Cuts the subject out of a photo and saves it as a transparent PNG, using the same on-device
/// Vision model as "Lift subject from background" in Photos. Nothing leaves the Mac.
enum BackgroundRemover {
    /// `Photo.jpg` → `Photo No Background.png` (full size, everything but the subject transparent).
    static func removeBackground(_ item: FileItem, progress: JobProgress) throws -> URL {
        let image = try ImageIOKit.loadImage(item.url)
        try progress.checkCancelled()
        progress.report(0.15)

        let cutout = try cutOut(image, name: item.name)
        try progress.checkCancelled()
        progress.report(0.85)

        let output = OutputNaming.url(for: item.url, suffix: "No Background", ext: ImageFormat.png.ext)
        try ImageIOKit.write(cutout, to: output, format: .png)
        progress.report(1)
        return output
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
