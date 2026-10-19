import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Builds the compositions behind the video edits (crop, speed, join, redact).
enum VideoComposer {
    /// The asset's audio and video tracks on their own: no file metadata, no track metadata,
    /// no timed-metadata tracks (where phones keep location and camera details).
    static func bareCopy(of asset: AVAsset) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            let (range, transform) = try await track.load(.timeRange, .preferredTransform)
            guard range.duration > .zero,
                  let copy = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = transform
        }
        return composition
    }

    // MARK: Crop

    /// Renders only `crop` (display pixels, top-left origin) of the first video track.
    static func cropping(_ asset: AVAsset, info: VideoInfo, to crop: CGRect) async throws -> AVVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw KlickError.failed("No video track") }
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(info.displayTransform.concatenating(CGAffineTransform(translationX: -crop.minX, y: -crop.minY)), at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: info.duration)
        ))
        var configuration = try await AVVideoComposition.Configuration(for: asset)
        configuration.renderSize = crop.size
        configuration.instructions = [instruction]
        return AVVideoComposition(configuration: configuration)
    }

    // MARK: Speed

    /// Every track of `asset` played `factor` times faster (0.5 = half speed).
    static func retimed(_ asset: AVAsset, by factor: Double) async throws -> AVMutableComposition {
        let composition = try await bareCopy(of: asset)
        let duration = composition.duration
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                                   toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor))
        return composition
    }

    /// Renders a retimed composition upright, at the source frame rate, so a sped-up clip drops
    /// frames instead of piling them up (4× a 30 fps clip would otherwise play at 120 fps).
    static func upright(_ composition: AVAsset, info: VideoInfo) async throws -> AVVideoComposition {
        guard let track = try await composition.loadTracks(withMediaType: .video).first else { throw KlickError.failed("No video track") }
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: track)
        layer.setTransform(info.displayTransform, at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: try await composition.load(.duration))
        ))
        let configuration = AVVideoComposition.Configuration(
            frameDuration: info.frameDuration,
            instructions: [instruction],
            renderSize: CGSize(width: VideoExport.even(info.displaySize.width), height: VideoExport.even(info.displaySize.height))
        )
        return AVVideoComposition(configuration: configuration)
    }

    // MARK: Join

    /// Clips played one after another on a canvas the size of the first one; clips with another
    /// shape or orientation are scaled to fit and centered on black.
    static func joining(_ assets: [AVAsset]) async throws -> (AVMutableComposition, AVVideoComposition) {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw KlickError.failed("Couldn't create the joined video") }

        var renderSize = CGSize.zero
        var frameRate: Float = 0
        var segments: [(range: CMTimeRange, transform: CGAffineTransform)] = []
        var cursor = CMTime.zero
        for asset in assets {
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let (range, natural, preferred, rate) = try await source.load(.timeRange, .naturalSize, .preferredTransform, .nominalFrameRate)
            guard range.duration > .zero else { continue }
            let (size, oriented) = VideoExport.orient(natural, preferred)
            if renderSize == .zero {
                renderSize = CGSize(width: VideoExport.even(size.width), height: VideoExport.even(size.height))
            }
            frameRate = max(frameRate, rate)

            try videoTrack.insertTimeRange(range, of: source, at: cursor)
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = try await audio.load(.timeRange).intersection(range)
                if audioRange.duration > .zero {
                    try audioTrack.insertTimeRange(audioRange, of: audio, at: cursor + (audioRange.start - range.start))
                }
            }

            // Aspect-fit into the canvas, centered.
            let scale = min(renderSize.width / max(size.width, 1), renderSize.height / max(size.height, 1))
            let fitted = oriented
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (renderSize.width - size.width * scale) / 2,
                                                 y: (renderSize.height - size.height * scale) / 2))
            segments.append((CMTimeRange(start: cursor, duration: range.duration), fitted))
            cursor = cursor + range.duration
        }
        guard !segments.isEmpty else { throw KlickError.failed("No video to join") }
        if audioTrack.segments.isEmpty { composition.removeTrack(audioTrack) }

        let instructions = segments.enumerated().map { index, segment in
            var layer = AVVideoCompositionLayerInstruction.Configuration(trackID: videoTrack.trackID)
            layer.setTransform(segment.transform, at: segment.range.start)
            // The last instruction runs to the very end, so rounding can't leave an uncovered sliver.
            let end = index == segments.count - 1 ? max(composition.duration, segment.range.end) : segment.range.end
            return AVVideoCompositionInstruction(configuration: .init(
                backgroundColor: CGColor(gray: 0, alpha: 1),
                layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
                timeRange: CMTimeRange(start: segment.range.start, end: end)
            ))
        }
        let fps = Double(frameRate > 1 ? min(frameRate, 60) : 30)
        let configuration = AVVideoComposition.Configuration(
            frameDuration: CMTime(seconds: 1 / fps, preferredTimescale: 60_000),
            instructions: instructions,
            renderSize: renderSize
        )
        return (composition, AVVideoComposition(configuration: configuration))
    }

    // MARK: Redact

    /// Every frame of `asset` with the regions of `redaction` hidden. The regions are read on each
    /// frame, so an editor's live preview follows changes without rebuilding the composition.
    static func redacting(_ asset: AVAsset, with redaction: VideoRedaction) async throws -> AVVideoComposition {
        try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
            let (regions, style) = redaction.snapshot
            return AVCIImageFilteringResult(resultImage: redact(parameters.sourceImage, regions: regions, style: style))
        }
    }

    /// `image` with `style` burnt into `regions` (normalized, top-left origin). Pixels inside them
    /// are replaced outright, so nothing of the original survives there.
    static func redact(_ image: CIImage, regions: [CGRect], style: RedactStyle) -> CIImage {
        let extent = image.extent
        guard !regions.isEmpty else { return image }
        var mask = CIImage(color: .black).cropped(to: extent)
        for region in regions {
            let box = CGRect(x: extent.minX + region.minX * extent.width,
                             y: extent.minY + (1 - region.maxY) * extent.height,
                             width: region.width * extent.width,
                             height: region.height * extent.height)
            mask = CIImage(color: .white).cropped(to: box.integral.intersection(extent)).composited(over: mask)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = RedactRenderer.effect(style, on: image)
        blend.backgroundImage = image
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: extent)
    }
}

/// Areas to hide in every frame of a video, shared between the editor (main thread) and the
/// composition's frame handler (a render thread).
final class VideoRedaction: @unchecked Sendable {
    private let lock = NSLock()
    private var regions: [CGRect]
    private var style: RedactStyle

    /// - Parameter regions: normalized rectangles, top-left origin.
    init(regions: [CGRect] = [], style: RedactStyle = .blur) {
        self.regions = regions
        self.style = style
    }

    var snapshot: ([CGRect], RedactStyle) {
        lock.lock(); defer { lock.unlock() }
        return (regions, style)
    }

    func update(regions: [CGRect], style: RedactStyle) {
        lock.lock(); defer { lock.unlock() }
        self.regions = regions
        self.style = style
    }
}
