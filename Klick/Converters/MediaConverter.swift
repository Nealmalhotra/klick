import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Video / audio conversions built on AVFoundation's async APIs.
enum MediaConverter {
    /// `Clip.mov` → `Clip.mp4`. Streams are copied untouched when the container allows it (MP4 only
    /// for H.264/HEVC + AAC, which every player expects), otherwise re-encoded at the highest quality.
    static func convertVideo(_ item: FileItem, to container: VideoContainer, progress: JobProgress) async throws -> URL {
        let asset = try await loadAsset(item, requiring: .video)
        let fileType: AVFileType = container == .mp4 ? .mp4 : .mov
        let codecsFit = container == .mov ? true : try await hasMP4Codecs(asset)
        let passthrough = codecsFit
            ? await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: fileType)
            : false
        let preset = passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        let output = OutputNaming.url(for: item.url, ext: container.ext)
        try await export(asset, preset: preset, to: output, as: fileType, progress: progress)
        return output
    }

    /// `Clip.mp4` → `Clip.gif`: the first 15 s at 12.5 fps, at most 480 px wide, looping forever.
    static func toGIF(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let asset = try await loadAsset(item, requiring: .video)
        let duration = try await asset.load(.duration).seconds
        let frameDelay = 0.08 // GIF delays are in 1/100 s; 8 cs = 12.5 fps
        let times = stride(from: 0, to: min(duration, 15), by: frameDelay).map { CMTime(seconds: $0, preferredTimescale: 600) }
        guard !times.isEmpty else { throw KlickError.failed("\(item.name) has no frames") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let size = try await orientedSize(of: asset)
        let scale = min(1, 480 / max(size.width, 1))
        generator.maximumSize = CGSize(width: (size.width * scale).rounded(.up), height: (size.height * scale).rounded(.up))
        let tolerance = CMTime(seconds: frameDelay / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let output = OutputNaming.url(for: item.url, ext: "gif")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, times.count, nil) else {
            throw KlickError.failed("Couldn't create \(output.lastPathComponent)")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
            ],
        ] as CFDictionary

        do {
            // Every slot must be filled: a frame that fails to decode repeats the previous one.
            var lastFrame: CGImage?
            var added = 0
            for await result in generator.images(for: times) {
                try progress.checkCancelled()
                if let frame = (try? result.image) ?? lastFrame {
                    CGImageDestinationAddImage(destination, frame, frameProperties)
                    lastFrame = frame
                    added += 1
                }
                progress.report(0.95 * Double(added) / Double(times.count))
            }
            guard added == times.count, CGImageDestinationFinalize(destination) else {
                throw KlickError.failed("Couldn't decode the frames of \(item.name)")
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        progress.report(1)
        return output
    }

    /// `Clip.mp4` → `Clip.m4a` (AAC audio only).
    static func extractAudio(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let asset = try await loadAsset(item, requiring: .audio)
        let output = OutputNaming.url(for: item.url, ext: "m4a")
        try await export(asset, preset: AVAssetExportPresetAppleM4A, to: output, as: .m4a, progress: progress)
        return output
    }

    /// `Clip.mov` → `Clip Compressed.mp4`. Videos above 1080p first go down to HEVC 1080p; others keep
    /// their size and are re-encoded as HEVC at ~55% of their video bit rate. Smaller presets are the
    /// fallback when an attempt doesn't save at least 10%.
    static func compressVideo(_ item: FileItem, progress: JobProgress) async throws -> URL {
        enum Attempt { case preset(String), lowerBitRate }
        let asset = try await loadAsset(item, requiring: .video)
        let size = try await orientedSize(of: asset)
        let shortSide = min(size.width, size.height)
        var attempts: [Attempt] = shortSide > 1080
            ? [.preset(AVAssetExportPresetHEVC1920x1080), .lowerBitRate, .preset(AVAssetExportPreset1280x720)]
            : [.lowerBitRate]
        if shortSide <= 1080 {
            if shortSide > 720 { attempts.append(.preset(AVAssetExportPreset1280x720)) }
            if shortSide > 540 { attempts.append(.preset(AVAssetExportPreset960x540)) }
        }

        for attempt in attempts {
            let output = OutputNaming.url(for: item.url, suffix: "Compressed", ext: "mp4")
            switch attempt {
            case .preset(let preset):
                try await export(asset, preset: preset, to: output, as: .mp4, progress: progress)
            case .lowerBitRate:
                try await VideoTranscoder.hevc(asset, bitRate: try await compressedBitRate(of: asset, item: item),
                                               to: output, as: .mp4, progress: progress)
            }
            let newSize = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            NSLog("%@", "Klick: compressed \(item.name) with \(attempt): \(item.size) → \(newSize) bytes")
            if Double(newSize) <= Double(item.size) * 0.9 { return output } // worth it only when ≥ 10% smaller
            try? FileManager.default.removeItem(at: output)
        }
        throw KlickError.failed("\(item.name) is already as small as it gets")
    }

    /// ~55% of the source's video bit rate (HEVC holds the quality of H.264 at about half the rate).
    private static func compressedBitRate(of asset: AVAsset, item: FileItem) async throws -> Int {
        var rate = 0.0
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            rate = Double(try await track.load(.estimatedDataRate))
        }
        if rate <= 0 {
            let seconds = try await asset.load(.duration).seconds
            rate = seconds > 0 ? Double(item.size) * 8 / seconds : 2_000_000
        }
        return max(Int(rate * 0.55), 200_000)
    }

    /// `Clip.mov` → `Clip Muted.mov`: the video track(s) copied without audio.
    static func mute(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let asset = try await loadAsset(item, requiring: .video)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw KlickError.failed("\(item.name) has no audio")
        }
        let composition = AVMutableComposition()
        for track in try await asset.loadTracks(withMediaType: .video) {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let (range, transform) = try await track.load(.timeRange, .preferredTransform)
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = transform
        }

        let (fileType, ext): (AVFileType, String) = switch item.ext {
        case "mp4": (.mp4, "mp4")
        case "m4v": (.m4v, "m4v")
        default: (.mov, "mov")
        }
        let passthrough = await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: composition, outputFileType: fileType)
        let output = OutputNaming.url(for: item.url, suffix: "Muted", ext: ext)
        try await export(composition, preset: passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality, to: output, as: fileType, progress: progress)
        return output
    }

    /// `Clip.mp4` → `Clip Snapshot.jpg`: the frame at 1 s (or mid-clip for shorter videos), full resolution.
    static func snapshot(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let asset = try await loadAsset(item, requiring: .video)
        let duration = try await asset.load(.duration)
        let time = CMTimeMinimum(CMTime(seconds: 1, preferredTimescale: 600), CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2))
        progress.report(0.2)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image: CGImage
        do {
            image = try await generator.image(at: time).image
        } catch {
            throw KlickError.failed("Couldn't read a frame from \(item.name)")
        }
        try progress.checkCancelled()
        progress.report(0.7)

        let output = OutputNaming.url(for: item.url, suffix: "Snapshot", ext: "jpg")
        try ImageIOKit.write(image, to: output, format: .jpg, quality: 1)
        progress.report(1)
        return output
    }

    /// `Voice.wav` → `Voice.mp3` / `.m4a` / `.wav` / `.flac` / `.ogg` / `.opus` / `.aiff`, keeping sample
    /// rate and channels (WAV/AIFF are 16- or 24-bit like the source). See `AudioTools` for the
    /// encoders: LAME for MP3, Core Audio for the rest, Ogg Opus for both OGG and OPUS.
    static func convertAudio(_ item: FileItem, to format: AudioFormat, progress: JobProgress) async throws -> URL {
        try await AudioTools.convert(item, to: format, progress: progress)
    }

    // MARK: - Helpers

    /// Opens the asset and makes sure it is readable and has a track of `mediaType`.
    private static func loadAsset(_ item: FileItem, requiring mediaType: AVMediaType) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: item.url)
        guard (try? await asset.load(.isReadable)) == true else { throw KlickError.unreadable(item.name) }
        guard try await !asset.loadTracks(withMediaType: mediaType).isEmpty else {
            throw KlickError.failed("\(item.name) has no \(mediaType == .audio ? "audio" : "video")")
        }
        return asset
    }

    /// True when every audio/video track is H.264, HEVC or AAC.
    private static func hasMP4Codecs(_ asset: AVAsset) async throws -> Bool {
        let codecs: Set<FourCharCode> = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kAudioFormatMPEG4AAC]
        for track in try await asset.load(.tracks) where track.mediaType == .video || track.mediaType == .audio {
            for description in try await track.load(.formatDescriptions) where !codecs.contains(CMFormatDescriptionGetMediaSubType(description)) {
                return false
            }
        }
        return true
    }

    /// Display size of the first video track (rotation applied).
    private static func orientedSize(of asset: AVAsset) async throws -> CGSize {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .zero }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }

    /// Runs an export session, mirroring its progress and cancelling it when the job is cancelled.
    /// A partially written file is removed on failure.
    private static func export(_ asset: AVAsset, preset: String, to url: URL, as fileType: AVFileType, progress: JobProgress) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw KlickError.unsupported("Exporting with \(preset)")
        }
        session.shouldOptimizeForNetworkUse = fileType == .mp4
        do {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await session.export(to: url, as: fileType)
                    return true
                }
                group.addTask {
                    for await state in session.states(updateInterval: 0.2) {
                        try progress.checkCancelled()
                        if case .exporting(let exportProgress) = state { progress.report(exportProgress.fractionCompleted) }
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
            if error is CancellationError { throw KlickError.cancelled }
            if error is KlickError { throw error }
            throw KlickError.failed("Couldn't export \(url.lastPathComponent): \(error.localizedDescription)")
        }
        progress.report(1)
    }
}
