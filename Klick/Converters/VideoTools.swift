import AVFoundation
import CoreGraphics

/// The video tools page: privacy cleaning, trimming, cropping, retiming, splitting, redacting
/// and joining. Every edit writes `<name> <Suffix>.<ext>` next to the original. Streams are
/// copied untouched whenever pixels and timing stay the same; everything else is re-encoded
/// at the highest quality (HEVC sources stay HEVC).
enum VideoTools {
    /// Speeds offered by the Speed editor.
    static let speeds: [Double] = [0.5, 1.5, 2, 4]

    // MARK: Metadata

    /// `Clip.mov` → `Clip No Metadata.mov`: the same audio and video streams, copied without
    /// title, author, location, camera, creation date or any other tag.
    static func removeMetadata(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let asset = try await VideoExport.loadAsset(item)
        let composition = try await VideoComposer.bareCopy(of: asset)
        let (fileType, ext) = VideoExport.container(for: item)
        let output = OutputNaming.url(for: item.url, suffix: "No Metadata", ext: ext)
        try await VideoExport.run(composition, preset: await VideoExport.copyPreset(for: composition, fileType: fileType),
                                  to: output, as: fileType, progress: progress) { session in
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }
        return output
    }

    // MARK: Trim & split

    /// `Clip.mp4` → `Clip Trimmed.mp4`: only `range` (seconds), streams copied.
    static func trim(_ item: FileItem, to range: ClosedRange<Double>, progress: JobProgress) async throws -> URL {
        let asset = try await VideoExport.loadAsset(item)
        let (fileType, ext) = VideoExport.container(for: item)
        let output = OutputNaming.url(for: item.url, suffix: "Trimmed", ext: ext)
        try await VideoExport.run(asset, preset: await VideoExport.copyPreset(for: asset, fileType: fileType),
                                  to: output, as: fileType, progress: progress) { session in
            session.timeRange = timeRange(range)
        }
        return output
    }

    /// `Clip.mp4` → `Clip Part 1.mp4`, `Clip Part 2.mp4`...: cut at `points` (seconds), streams copied.
    static func split(_ item: FileItem, at points: [Double], progress: JobProgress) async throws -> [URL] {
        let asset = try await VideoExport.loadAsset(item)
        let duration = try await asset.load(.duration).seconds
        let cuts = points.filter { $0 > 0.05 && $0 < duration - 0.05 }.sorted()
        let bounds = [0] + cuts + [duration]
        let ranges = zip(bounds, bounds.dropFirst()).map { $0...$1 }.filter { $0.upperBound - $0.lowerBound > 0.01 }
        guard ranges.count > 1 else { throw KlickError.failed("Add a split point inside the clip") }

        let (fileType, ext) = VideoExport.container(for: item)
        let preset = await VideoExport.copyPreset(for: asset, fileType: fileType)
        var outputs: [URL] = []
        do {
            for (index, range) in ranges.enumerated() {
                let output = OutputNaming.url(for: item.url, suffix: "Part \(index + 1)", ext: ext)
                let span = Double(index) / Double(ranges.count)...Double(index + 1) / Double(ranges.count)
                try await VideoExport.run(asset, preset: preset, to: output, as: fileType, progress: progress, span: span) { session in
                    session.timeRange = timeRange(range)
                }
                outputs.append(output)
            }
        } catch {
            // All or nothing: half a set of parts is more confusing than none.
            for url in outputs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return outputs
    }

    // MARK: Crop

    /// `Clip.mp4` → `Clip Cropped.mp4`.
    /// - Parameter crop: normalized rectangle of the displayed frame (top-left origin, 0...1).
    static func crop(_ item: FileItem, to crop: CGRect, progress: JobProgress) async throws -> URL {
        let asset = try await VideoExport.loadAsset(item)
        let info = try await VideoExport.info(of: asset)
        let size = info.displaySize
        let pixels = CGRect(
            x: (crop.minX * size.width).rounded(), y: (crop.minY * size.height).rounded(),
            width: VideoExport.even(crop.width * size.width), height: VideoExport.even(crop.height * size.height)
        )
        let composition = try await VideoComposer.cropping(asset, info: info, to: pixels)
        let (fileType, ext) = VideoExport.container(for: item)
        let output = OutputNaming.url(for: item.url, suffix: "Cropped", ext: ext)
        try await VideoExport.run(asset, preset: VideoExport.encodePreset(info), to: output, as: fileType, progress: progress) { session in
            session.videoComposition = composition
        }
        return output
    }

    // MARK: Speed

    /// `Clip.mp4` → `Clip 2x.mp4`: played `factor` times faster (0.5 = half speed), audio kept
    /// at its natural pitch.
    static func changeSpeed(_ item: FileItem, by factor: Double, progress: JobProgress) async throws -> URL {
        let asset = try await VideoExport.loadAsset(item)
        let info = try await VideoExport.info(of: asset)
        let composition = try await VideoComposer.retimed(asset, by: factor)
        let video = try await VideoComposer.upright(composition, info: info)
        let metadata = (try? await asset.load(.metadata)) ?? []
        let (fileType, ext) = VideoExport.container(for: item)
        let output = OutputNaming.url(for: item.url, suffix: speedLabel(factor), ext: ext)
        try await VideoExport.run(composition, preset: VideoExport.encodePreset(info), to: output, as: fileType, progress: progress) { session in
            session.videoComposition = video
            session.audioTimePitchAlgorithm = .spectral
            session.timeRange = CMTimeRange(start: .zero, duration: composition.duration) // no time-stretch tail
            session.metadata = metadata
        }
        return output
    }

    /// "0.5x", "1.5x", "2x".
    static func speedLabel(_ factor: Double) -> String {
        let number = factor.rounded() == factor ? String(Int(factor)) : String(format: "%g", factor)
        return "\(number)x"
    }

    // MARK: Redact

    /// `Clip.mp4` → `Clip Redacted.mp4`: `regions` (normalized, top-left origin) hidden in every frame.
    static func redact(_ item: FileItem, regions: [CGRect], style: RedactStyle, progress: JobProgress) async throws -> URL {
        guard !regions.isEmpty else { throw KlickError.failed("Draw over what you want to hide") }
        let asset = try await VideoExport.loadAsset(item)
        let info = try await VideoExport.info(of: asset)
        let composition = try await VideoComposer.redacting(asset, with: VideoRedaction(regions: regions, style: style))
        let (fileType, ext) = VideoExport.container(for: item)
        let output = OutputNaming.url(for: item.url, suffix: "Redacted", ext: ext)
        try await VideoExport.run(asset, preset: VideoExport.encodePreset(info), to: output, as: fileType, progress: progress) { session in
            session.videoComposition = composition
            // The location is as revealing as a face.
            session.metadataItemFilter = .forSharing()
        }
        return output
    }

    // MARK: Join

    /// `A.mp4` + `B.mov` → `A Joined.mp4`: the clips in selection order, fitted to the first one's frame.
    static func join(_ items: [FileItem], progress: JobProgress) async throws -> URL {
        guard items.count > 1, let first = items.first else { throw KlickError.failed("Select two or more videos") }
        var assets: [AVAsset] = []
        var hevc = false
        for item in items {
            try progress.checkCancelled()
            let asset = try await VideoExport.loadAsset(item)
            if try await VideoExport.info(of: asset).isHEVC { hevc = true }
            assets.append(asset)
        }
        let (composition, video) = try await VideoComposer.joining(assets)
        let output = OutputNaming.url(for: first.url, suffix: "Joined", ext: "mp4")
        let preset = hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        try await VideoExport.run(composition, preset: preset, to: output, as: .mp4, progress: progress) { session in
            session.videoComposition = video
        }
        return output
    }

    // MARK: Helpers

    private static func timeRange(_ range: ClosedRange<Double>) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600),
                    end: CMTime(seconds: range.upperBound, preferredTimescale: 600))
    }
}
