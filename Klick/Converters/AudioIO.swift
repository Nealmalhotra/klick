import AVFoundation

// MARK: - Source

/// Streams decoded audio out of any file AVFoundation can read — audio files, or the
/// first audio track of a movie — as Float32 deinterleaved PCM buffers.
final class AudioSource {
    /// Standard (Float32, deinterleaved) format of the buffers `read()` returns.
    let format: AVAudioFormat
    /// Total length in frames (an estimate for movie tracks).
    let length: AVAudioFramePosition
    /// Format of the stored audio (codec, bit depth), when known.
    let fileFormat: AVAudioFormat?

    private let file: AVAudioFile?
    private let reader: AVAssetReader?
    private let output: AVAssetReaderTrackOutput?
    private let chunk: AVAudioFrameCount = 16_384

    var duration: Double { Double(length) / format.sampleRate }
    var channelCount: Int { Int(format.channelCount) }

    /// Codec of the stored audio (`kAudioFormatMPEG4AAC`, `kAudioFormatAppleLossless`, ...).
    var codec: AudioFormatID { fileFormat?.streamDescription.pointee.mFormatID ?? kAudioFormatLinearPCM }

    /// Average bit rate of a lossy audio file (bits per second); nil for lossless sources and movies.
    var lossyBitRate: Int? {
        guard let file, ![kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC].contains(codec), duration > 0,
              let size = try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        else { return nil }
        return Int(Double(size) * 8 / duration)
    }

    /// Bit depth of PCM / lossless sources; 16 for lossy ones.
    var bitDepth: Int {
        if let bits = fileFormat?.settings[AVLinearPCMBitDepthKey] as? Int, bits > 0 { return bits }
        // ALAC and FLAC store the source bit depth in the format flags (1 = 16-bit, 2 = 20, 3 = 24, 4 = 32).
        guard codec == kAudioFormatAppleLossless || codec == kAudioFormatFLAC,
              let flags = fileFormat?.streamDescription.pointee.mFormatFlags, flags > 0
        else { return 16 }
        return flags == kAppleLosslessFormatFlag_16BitSourceData ? 16 : 24
    }

    /// Opens `url`; `name` is only used for error messages.
    static func open(_ url: URL, name: String? = nil) async throws -> AudioSource {
        let label = name ?? url.lastPathComponent
        if let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false), file.length > 0 {
            return AudioSource(file: file)
        }
        // Core Audio reads most movies too; anything else goes through AVFoundation's reader.
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isReadable)) == true,
              let track = try? await asset.loadTracks(withMediaType: .audio).first
        else { throw KlickError.unreadable(label) }
        let (descriptions, range) = try await track.load(.formatDescriptions, .timeRange)
        guard let description = descriptions.first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame)
        else { throw KlickError.unreadable(label) }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw KlickError.unreadable(label) }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw KlickError.unreadable(label) }
        reader.add(output)
        guard reader.startReading() else { throw KlickError.unreadable(label) }
        let length = AVAudioFramePosition((range.duration.seconds * asbd.mSampleRate).rounded())
        return AudioSource(reader: reader, output: output, format: format, length: max(length, 1),
                           fileFormat: AVAudioFormat(streamDescription: [asbd]))
    }

    private init(file: AVAudioFile) {
        self.file = file
        reader = nil
        output = nil
        format = file.processingFormat
        length = file.length
        fileFormat = file.fileFormat
    }

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, format: AVAudioFormat,
                 length: AVAudioFramePosition, fileFormat: AVAudioFormat?) {
        file = nil
        self.reader = reader
        self.output = output
        self.format = format
        self.length = length
        self.fileFormat = fileFormat
    }

    /// Jumps to `frame`. Only audio files can seek; movie tracks always start at 0
    /// (`render` then skips the frames before its range).
    @discardableResult
    func seek(to frame: AVAudioFramePosition) -> Bool {
        guard let file else { return false }
        file.framePosition = min(max(frame, 0), file.length)
        return true
    }

    /// Next decoded chunk, or nil at the end of the stream.
    func read() throws -> AVAudioPCMBuffer? {
        if let file {
            guard file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)
            else { return nil }
            try file.read(into: buffer, frameCount: chunk)
            return buffer.frameLength > 0 ? buffer : nil
        }
        guard let reader, let output else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            if let buffer = deinterleave(sample) { return buffer }
        }
        if reader.status == .failed { throw KlickError.failed("Couldn't decode the audio") }
        return nil
    }

    /// Copies an interleaved Float32 sample buffer from the asset reader into a deinterleaved buffer.
    private func deinterleave(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let block = CMSampleBufferGetDataBuffer(sample),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else { return nil }
        let count = channelCount
        var interleaved = [Float](repeating: 0, count: frames * count)
        let status = interleaved.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min(raw.count, CMBlockBufferGetDataLength(block)), destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        for channel in 0..<count {
            let destination = channels[channel]
            for frame in 0..<frames { destination[frame] = interleaved[frame * count + channel] }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }
}

// MARK: - Format adapter

/// Resamples and up/downmixes a stream of PCM buffers to the format an encoder expects.
final class PCMAdapter {
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(from input: AVAudioFormat, to output: AVAudioFormat) throws {
        outputFormat = output
        if input.sampleRate == output.sampleRate, input.channelCount == output.channelCount {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else {
                throw KlickError.unsupported("Converting \(input.channelCount) channels at \(Int(input.sampleRate)) Hz")
            }
            // Averages channels when there are fewer outputs (stereo → mono, 5.1 → stereo).
            converter.downmix = true
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.converter = converter
        }
    }

    /// Converts `buffer`, handing every produced chunk to `emit`.
    func push(_ buffer: AVAudioPCMBuffer, emit: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let converter else { return try emit(buffer) }
        var supplied = false
        try drain(converter, capacity: buffer.frameLength, emit: emit) { status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    /// Flushes whatever the resampler still holds.
    func finish(emit: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let converter else { return }
        try drain(converter, capacity: 4096, emit: emit) { status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(
        _ converter: AVAudioConverter, capacity frames: AVAudioFrameCount,
        emit: (AVAudioPCMBuffer) throws -> Void,
        input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?
    ) throws {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw KlickError.failed("Out of memory")
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in input(inputStatus) }
            if status == .error { throw KlickError.failed("Couldn't resample the audio\(error.map { ": \($0.localizedDescription)" } ?? "")") }
            if out.frameLength > 0 { try emit(out) }
            if status != .haveData { break }
        }
    }
}

// MARK: - Sinks

/// An encoder fed with PCM buffers, writing one output file.
protocol AudioSink: AnyObject {
    /// PCM format `write` expects (Float32, deinterleaved).
    var inputFormat: AVAudioFormat { get }
    func write(_ buffer: AVAudioPCMBuffer) throws
    /// Flushes the encoder and closes the file.
    func finish() throws
}

/// How to encode an output file.
struct AudioEncoding {
    var format: AudioFormat
    /// Bit rate of lossy formats in bits per second; nil picks a transparent default.
    var bitRate: Int?
    /// Bit depth of WAV / AIFF output.
    var bitDepth = 16
    /// Write Apple Lossless instead of AAC into M4A.
    var appleLossless = false

    init(_ format: AudioFormat, bitRate: Int? = nil, bitDepth: Int = 16, appleLossless: Bool = false) {
        self.format = format
        self.bitRate = bitRate
        self.bitDepth = bitDepth
        self.appleLossless = appleLossless
    }

    /// Re-encodes like `source`: same container, same bit depth, ALAC stays ALAC.
    /// Lossy sources are re-encoded at about their own bit rate (a 96 kbps podcast doesn't
    /// balloon to 256 kbps); lossless ones get the transparent defaults.
    static func matching(_ source: AudioSource, as format: AudioFormat) -> AudioEncoding {
        var encoding = AudioEncoding(format, bitDepth: source.bitDepth > 16 ? 24 : 16,
                                     appleLossless: format == .m4a && source.codec == kAudioFormatAppleLossless)
        if !format.isLossless, !encoding.appleLossless, let rate = source.lossyBitRate {
            let mp3Rates = [64, 80, 96, 112, 128, 160, 192, 224, 256, 320].map { $0 * 1000 }
            encoding.bitRate = format == .mp3
                ? mp3Rates.first { $0 >= rate * 95 / 100 } ?? 320_000
                : min(max(rate, 32_000), 320_000)
        }
        return encoding
    }

    /// Opens an encoder writing `url` for audio at `sampleRate` with `channels` channels.
    func makeSink(url: URL, sampleRate: Double, channels: Int) throws -> AudioSink {
        switch format {
        case .mp3:
            let quality: MP3Encoder.Quality = bitRate.map { .constant(kbps: $0 / 1000) } ?? .variable(2)
            return try MP3Encoder(url: url, sampleRate: sampleRate, channels: min(channels, 2), quality: quality)
        case .ogg, .opus:
            let stereo = min(channels, 2) == 2
            return try OggOpusEncoder(url: url, inputSampleRate: sampleRate, channels: min(channels, 2),
                                      bitRate: bitRate ?? (stereo ? 160_000 : 96_000))
        case .wav, .aiff:
            return try PCMFileSink(url: url, sampleRate: sampleRate, channels: channels, settings: [
                AVAudioFileTypeKey: format == .wav ? kAudioFileWAVEType : kAudioFileAIFFType, // plain AIFF, not AIFF-C
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: bitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: format == .aiff,
                AVLinearPCMIsNonInterleaved: false,
            ])
        case .flac:
            return try FLACFileSink(url: url, sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
        case .m4a:
            if appleLossless {
                return try PCMFileSink(url: url, sampleRate: sampleRate, channels: channels, settings: [
                    AVAudioFileTypeKey: kAudioFileM4AType,
                    AVFormatIDKey: kAudioFormatAppleLossless,
                    AVEncoderBitDepthHintKey: bitDepth,
                ])
            }
            // AAC tops out at 48 kHz and stereo here.
            let rates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
            let rate = rates.contains(sampleRate) ? sampleRate : (sampleRate > 48000 ? 48000 : 44100)
            let count = min(channels, 2)
            return try PCMFileSink(url: url, sampleRate: rate, channels: count, settings: [
                AVAudioFileTypeKey: kAudioFileM4AType,
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVEncoderBitRateKey: AudioEncoding.aacBitRate(bitRate ?? (count == 2 ? 256_000 : 128_000), sampleRate: rate, channels: count),
            ])
        }
    }

    /// The AAC bit rate closest to `requested` that the encoder accepts for this rate and
    /// layout (22 kHz mono tops out at 64 kbps, for example).
    static func aacBitRate(_ requested: Int, sampleRate: Double, channels: Int) -> Int {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]),
              let rates = AVAudioConverter(from: pcm, to: aac)?.applicableEncodeBitRates?.map(\.intValue), !rates.isEmpty
        else { return requested }
        return rates.min { abs($0 - requested) < abs($1 - requested) } ?? requested
    }
}

/// WAV / AIFF / FLAC / M4A writer backed by `AVAudioFile`.
final class PCMFileSink: AudioSink {
    private let file: AVAudioFile
    var inputFormat: AVAudioFormat { file.processingFormat }

    init(url: URL, sampleRate: Double, channels: Int, settings: [String: Any]) throws {
        var settings = settings
        settings[AVSampleRateKey] = sampleRate
        settings[AVNumberOfChannelsKey] = channels
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw KlickError.failed("Couldn't create \(url.lastPathComponent)")
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        try file.write(from: buffer)
    }

    func finish() throws {
        file.close()
    }
}

/// FLAC writer. `AVAudioFile` can't say which bit depth to store and always writes
/// 24-bit FLAC, so this goes through `ExtAudioFile` to keep 16-bit sources 16-bit.
final class FLACFileSink: AudioSink {
    let inputFormat: AVAudioFormat
    private let file: ExtAudioFileRef
    private var closed = false

    init(url: URL, sampleRate: Double, channels: Int, bitDepth: Int) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            throw KlickError.unsupported("FLAC with \(channels) channels")
        }
        inputFormat = format
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatFLAC,
            mFormatFlags: bitDepth > 16 ? kAppleLosslessFormatFlag_24BitSourceData : kAppleLosslessFormatFlag_16BitSourceData,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0
        )
        var file: ExtAudioFileRef?
        guard ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &description, nil, AudioFileFlags.eraseFile.rawValue, &file) == noErr,
              let file
        else { throw KlickError.failed("Couldn't create \(url.lastPathComponent)") }
        self.file = file
        var client = format.streamDescription.pointee
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr else {
            ExtAudioFileDispose(file)
            throw KlickError.unsupported("FLAC at \(Int(sampleRate)) Hz")
        }
    }

    deinit {
        if !closed { ExtAudioFileDispose(file) }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
        guard status == noErr else { throw KlickError.failed("FLAC encoding failed (\(status))") }
    }

    func finish() throws {
        guard !closed else { return }
        closed = true
        ExtAudioFileDispose(file)
    }
}

// MARK: - Rendering

/// Decodes a source, optionally edits it, and encodes the result.
enum AudioRender {
    /// In-place edit of a decoded chunk; `position` is the source frame of its first sample.
    typealias Transform = (_ buffer: AVAudioPCMBuffer, _ position: AVAudioFramePosition) -> Void

    /// Streams `source` (or `range` of it, in seconds) through `transform` into a new file.
    /// - Parameters:
    ///   - channels: output channel count; nil keeps the source layout.
    ///   - gain: linear gain applied after `transform`.
    ///   - progress: reported over `progressSpan` of the job.
    static func render(
        _ source: AudioSource, to url: URL, encoding: AudioEncoding,
        range: ClosedRange<Double>? = nil, channels: Int? = nil, gain: Float = 1,
        transform: Transform? = nil, progress: JobProgress, progressSpan: ClosedRange<Double> = 0...1
    ) throws {
        let rate = source.format.sampleRate
        let start = AVAudioFramePosition(((range?.lowerBound ?? 0) * rate).rounded())
        let end = range.map { AVAudioFramePosition(($0.upperBound * rate).rounded()) } ?? .max
        let total = Double(max(min(end, source.length) - start, 1))
        var position: AVAudioFramePosition = source.seek(to: start) ? start : 0

        let sink: AudioSink
        do {
            sink = try encoding.makeSink(url: url, sampleRate: rate, channels: channels ?? source.channelCount)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        do {
            let adapter = try PCMAdapter(from: source.format, to: sink.inputFormat)
            while position < end, let buffer = try source.read() {
                try progress.checkCancelled()
                let first = position
                position += AVAudioFramePosition(buffer.frameLength)
                // Keep only the frames inside the range.
                let lower = max(start - first, 0)
                let upper = min(end - first, AVAudioFramePosition(buffer.frameLength))
                guard upper > lower else { continue }
                let slice = (lower == 0 && upper == buffer.frameLength) ? buffer : buffer.slice(from: Int(lower), count: Int(upper - lower))
                transform?(slice, first + lower)
                if gain != 1 { slice.applyGain(gain) }
                try adapter.push(slice, emit: sink.write)
                let done = Double(first + upper - start) / total
                progress.report(progressSpan.lowerBound + (progressSpan.upperBound - progressSpan.lowerBound) * min(done, 1))
            }
            try adapter.finish(emit: sink.write)
            try sink.finish()
        } catch {
            try? sink.finish()
            try? FileManager.default.removeItem(at: url)
            if error is KlickError { throw error }
            throw KlickError.failed("Couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
        }
        progress.report(progressSpan.upperBound)
    }
}

// MARK: - Buffer helpers

extension AVAudioPCMBuffer {
    /// Copy of `count` frames starting at `offset`.
    func slice(from offset: Int, count: Int) -> AVAudioPCMBuffer {
        let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(count, 1)))!
        copy.frameLength = AVAudioFrameCount(count)
        if let source = floatChannelData, let destination = copy.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                destination[channel].update(from: source[channel] + offset, count: count)
            }
        }
        return copy
    }

    func applyGain(_ gain: Float) {
        guard let channels = floatChannelData else { return }
        for channel in 0..<Int(format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<Int(frameLength) { samples[frame] *= gain }
        }
    }
}
