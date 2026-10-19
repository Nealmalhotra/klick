import CoreImage
import SwiftUI

/// State of the Edit editor: slider values, geometry, the live preview and saving.
@MainActor
final class AdjustModel: ObservableObject {
    let item: FileItem

    @Published var adjustments = ImageAdjustments() {
        didSet { if adjustments != oldValue { requestPreview() } }
    }
    @Published var geometry = ImageGeometry()
    /// Downscaled, unedited source (also what "Compare" shows).
    @Published private(set) var original: CGImage?
    /// Latest finished preview frame; rotation and flips are applied by the view.
    @Published private(set) var preview: CGImage?
    @Published private(set) var isSaving = false
    @Published private(set) var errorMessage: String?

    var isModified: Bool { !adjustments.isNeutral || !geometry.isIdentity }
    var isLoading: Bool { original == nil && errorMessage == nil }

    private static let previewMaxPixelSize = 1000
    private let renderer = AdjustRenderer()
    private var previewSource: CIImage?
    private var pendingPreview: ImageAdjustments?
    private var isRenderingPreview = false

    init(item: FileItem) {
        self.item = item
    }

    func load() async {
        let url = item.url
        let maxPixelSize = Self.previewMaxPixelSize
        let loaded = await Task.detached(priority: .userInitiated) {
            Result { try ImageIOKit.loadImage(url, maxPixelSize: maxPixelSize) }
        }.value
        switch loaded {
        case .success(let image):
            original = image
            preview = image
            previewSource = CIImage(cgImage: image)
            requestPreview()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        withAnimation(Theme.springSoft) {
            adjustments = ImageAdjustments()
            geometry.reset()
        }
        errorMessage = nil
    }

    // MARK: Preview

    /// Coalesces slider changes: at most one frame renders at a time, and when it
    /// finishes only the newest values are rendered next, so dragging never queues up work.
    private func requestPreview() {
        pendingPreview = adjustments
        guard !isRenderingPreview, let source = previewSource else { return }
        isRenderingPreview = true
        Task {
            while let values = pendingPreview {
                pendingPreview = nil
                let renderer = renderer
                let frame = await Task.detached(priority: .userInitiated) {
                    values.isNeutral ? nil : renderer.makeImage(renderer.filtered(source, with: values), colorSpace: source.colorSpace, opaque: false)
                }.value
                preview = frame ?? original
            }
            isRenderingPreview = false
        }
    }

    // MARK: Save

    /// Renders the full-resolution image off the main thread and writes `<name> Edited.<ext>`.
    func save() async -> Bool {
        guard !isSaving else { return false }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let url = item.url
        let values = adjustments
        let geometry = geometry
        let renderer = renderer
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                let source = try ImageIOKit.loadImage(url)
                let output = geometry.apply(to: renderer.filtered(CIImage(cgImage: source), with: values))
                guard let image = renderer.makeImage(output, colorSpace: source.colorSpace, opaque: !ImageIOKit.hasAlpha(source)) else {
                    throw KlickError.failed("Couldn't render \(url.lastPathComponent)")
                }
                let format = ImageIOKit.preferredOutputFormat(for: url)
                let destination = OutputNaming.url(for: url, suffix: "Edited", ext: format.ext)
                let metadata = Self.metadata(from: url, width: image.width, height: image.height)
                try ImageIOKit.write(image, to: destination, format: format, metadata: metadata)
            }
        }.value

        if case .failure(let error) = result {
            errorMessage = error.localizedDescription
            return false
        }
        return true
    }

    /// Source metadata with the EXIF pixel dimensions updated to the rendered size.
    private nonisolated static func metadata(from url: URL, width: Int, height: Int) -> [CFString: Any] {
        var metadata = ImageIOKit.properties(url)
        if var exif = metadata[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            metadata[kCGImagePropertyExifDictionary] = exif
        }
        return metadata
    }
}
