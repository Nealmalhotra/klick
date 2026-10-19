import AVFoundation
import CoreGraphics

/// What the video tools need to know about a clip before editing it.
struct VideoInfo {
    /// Length of the whole asset.
    let duration: CMTime
    /// Size the clip is shown at (rotation applied), in pixels.
    let displaySize: CGSize
    /// Maps the first video track's pixels into `displaySize` (rotation applied, origin at zero).
    let displayTransform: CGAffineTransform
    /// One frame at the clip's nominal frame rate (1/30 s when unknown).
    let frameDuration: CMTime
    let hasAudio: Bool
    /// True when the video is HEVC, so re-encodes keep the more efficient codec.
    let isHEVC: Bool

    var seconds: Double { duration.seconds }
}

/// Loading, inspection and export plumbing shared by the video tools and editors.
enum VideoExport {
    /// Opens `item` and makes sure it is a readable video.
    static func loadAsset(_ item: FileItem) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: item.url)
        guard (try? await asset.load(.isReadable)) == true else { throw KlickError.unreadable(item.name) }
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw KlickError.failed("\(item.name) has no video")
        }
        return asset
    }

    static func info(of asset: AVAsset) async throws -> VideoInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw KlickError.failed("No video track")
        }
        let (natural, transform, frameRate, descriptions) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
        let duration = try await asset.load(.duration)
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let (displaySize, displayTransform) = orient(natural, transform)
        let fps = frameRate > 1 ? Double(frameRate) : 30
        return VideoInfo(
            duration: duration,
            displaySize: displaySize,
            displayTransform: displayTransform,
            frameDuration: CMTime(seconds: 1 / fps, preferredTimescale: 60_000),
            hasAudio: hasAudio,
            isHEVC: descriptions.contains { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_HEVC }
        )
    }

    /// Display size of a track and the transform that puts its pixels there with the origin at zero.
    static func orient(_ natural: CGSize, _ transform: CGAffineTransform) -> (CGSize, CGAffineTransform) {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let size = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        return (size, transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY)))
    }

    // MARK: Containers & presets

    /// Container for an edited copy: the source's own (MP4, M4V, MOV), QuickTime for anything else.
    static func container(for item: FileItem) -> (fileType: AVFileType, ext: String) {
        switch item.ext {
        case "mp4": return (.mp4, "mp4")
        case "m4v": return (.m4v, "m4v")
        default: return (.mov, "mov")
        }
    }

    /// Stream copy when the container accepts the asset's codecs, otherwise the best re-encode.
    static func copyPreset(for asset: AVAsset, fileType: AVFileType) async -> String {
        await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality
    }

    /// Highest-quality re-encode, keeping HEVC sources in HEVC.
    static func encodePreset(_ info: VideoInfo) -> String {
        info.isHEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    }

    /// Even pixel counts: 4:2:0 encoders can't store odd widths or heights.
    static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded(.down) * 2)
    }

    // MARK: Export

    /// Runs an export session, mirroring its progress into `span` of `progress` and cancelling it
    /// when the job is cancelled. A partially written file is removed on failure.
    /// - Parameter configure: last chance to set the time range, video composition, metadata...
    static func run(
        _ asset: AVAsset, preset: String, to url: URL, as fileType: AVFileType,
        progress: JobProgress, span: ClosedRange<Double> = 0...1,
        configure: (AVAssetExportSession) -> Void = { _ in }
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw KlickError.unsupported("Exporting with \(preset)")
        }
        session.shouldOptimizeForNetworkUse = fileType == .mp4
        configure(session)
        let width = span.upperBound - span.lowerBound
        do {
            try progress.checkCancelled()
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await session.export(to: url, as: fileType)
                    return true
                }
                group.addTask {
                    for await state in session.states(updateInterval: 0.2) {
                        try progress.checkCancelled()
                        if case .exporting(let exportProgress) = state {
                            progress.report(span.lowerBound + width * exportProgress.fractionCompleted)
                        }
                    }
                    return false
                }
                // Done once the export task finishes; the monitor is then cancelled.
                while let finished = try await group.next() {
                    if finished { group.cancelAll(); break }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            if error is CancellationError || progress.isCancelled { throw KlickError.cancelled }
            if error is KlickError { throw error }
            throw KlickError.failed("Couldn't export \(url.lastPathComponent): \(error.localizedDescription)")
        }
        progress.report(span.upperBound)
    }
}
