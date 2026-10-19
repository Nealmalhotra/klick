import AVFoundation

/// Re-encodes a video with an explicit bit rate, which export presets can't do.
enum VideoTranscoder {
    /// Writes `asset` as HEVC at `bitRate` bits/s, keeping its size, orientation and frame timing.
    /// AAC audio is copied as is; any other audio becomes 160 kbps AAC.
    static func hevc(_ asset: AVAsset, bitRate: Int, to url: URL, as fileType: AVFileType, progress: JobProgress) async throws {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw KlickError.failed("No video track") }
        let (natural, transform, frameRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration).seconds

        let reader: AVAssetReader
        let writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw KlickError.failed("Couldn't re-encode the video")
        }

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if frameRate > 0 { compression[AVVideoExpectedSourceFrameRateKey] = frameRate }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(VideoExport.even(natural.width)),
            AVVideoHeightKey: Int(VideoExport.even(natural.height)),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        var pairs = [(output: videoOutput as AVAssetReaderOutput, input: videoInput, reportsProgress: true)]

        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let description = try await audioTrack.load(.formatDescriptions).first
            let isAAC = description.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? false
            if isAAC, let description {
                pairs.append((AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil),
                              AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description), false))
            } else {
                let asbd = description.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let channels = min(max(Int(asbd?.mChannelsPerFrame ?? 2), 1), 2)
                let sampleRate = min(max(asbd?.mSampleRate ?? 44_100, 8_000), 48_000)
                pairs.append((
                    AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVNumberOfChannelsKey: channels,
                        AVSampleRateKey: sampleRate,
                    ]),
                    AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: channels,
                        AVSampleRateKey: sampleRate,
                        AVEncoderBitRateKey: 160_000,
                    ]),
                    false
                ))
            }
        }
        for pair in pairs {
            guard reader.canAdd(pair.output), writer.canAdd(pair.input) else { throw KlickError.failed("Couldn't re-encode the video") }
            reader.add(pair.output)
            pair.input.expectsMediaDataInRealTime = false
            writer.add(pair.input)
        }

        do {
            guard reader.startReading(), writer.startWriting() else {
                throw reader.error ?? writer.error ?? KlickError.failed("Couldn't re-encode the video")
            }
            writer.startSession(atSourceTime: .zero)
            // Each track is pumped on its own queue so neither can stall the other.
            let pumps = pairs.map {
                TrackPump(output: $0.output, input: $0.input, reader: reader, progress: progress, duration: $0.reportsProgress ? duration : nil)
            }
            await withTaskGroup(of: Void.self) { group in
                for pump in pumps {
                    group.addTask { await pump.run() }
                }
            }
            try progress.checkCancelled()
            if reader.status == .failed { throw reader.error ?? KlickError.failed("Couldn't read the video") }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? KlickError.failed("Couldn't write the video") }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            if error is KlickError { throw error }
            throw KlickError.failed("Couldn't re-encode the video: \(error.localizedDescription)")
        }
        progress.report(1)
    }
}

/// Moves one track from the reader to the writer on its own serial queue. Reader and writer
/// objects are only touched from that queue while it runs, hence `@unchecked Sendable`.
private final class TrackPump: @unchecked Sendable {
    private let output: AVAssetReaderOutput
    private let input: AVAssetWriterInput
    private let reader: AVAssetReader
    private let progress: JobProgress
    /// Set for the track that drives the progress bar.
    private let duration: Double?
    private let queue = DispatchQueue(label: "io.exastudio.klick.transcode", qos: .userInitiated)

    init(output: AVAssetReaderOutput, input: AVAssetWriterInput, reader: AVAssetReader, progress: JobProgress, duration: Double?) {
        self.output = output
        self.input = input
        self.reader = reader
        self.progress = progress
        self.duration = duration
    }

    /// Feeds every sample to the writer, then marks the input finished. Stops early when the
    /// job is cancelled or reading / appending fails.
    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                if self.feed() { continuation.resume() }
            }
        }
    }

    /// Appends samples while the input accepts them; true once the track is done.
    private func feed() -> Bool {
        while input.isReadyForMoreMediaData {
            guard !progress.isCancelled, reader.status == .reading, let sample = output.copyNextSampleBuffer() else {
                input.markAsFinished()
                return true
            }
            if let duration, duration > 0 {
                progress.report(0.98 * CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)
            }
            if !input.append(sample) {
                reader.cancelReading()
                input.markAsFinished()
                return true
            }
        }
        return false
    }
}
