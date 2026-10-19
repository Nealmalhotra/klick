import AVFoundation

/// MP3 writer built on the vendored LAME 3.100 encoder (`Vendor/lame`, LGPL, embedded
/// as `Contents/Frameworks/libmp3lame.dylib`).
///
/// Feed it Float32 PCM at any sample rate (mono or stereo); LAME resamples to the
/// nearest MPEG rate itself. VBR files get a Xing/LAME header so players show the
/// right duration and seek accurately.
final class MP3Encoder: AudioSink {
    enum Quality {
        /// LAME `-V` preset: 0 (best, ~245 kbps) ... 9 (smallest, ~65 kbps). V2 is ~190 kbps.
        case variable(Int)
        /// Constant bit rate in kbps (32...320).
        case constant(kbps: Int)
    }

    let inputFormat: AVAudioFormat
    private let lame: OpaquePointer
    private let handle: FileHandle
    private let url: URL
    private var scratch = [UInt8]()
    private var finished = false

    init(url: URL, sampleRate: Double, channels: Int, quality: Quality = .variable(2)) throws {
        guard (1...2).contains(channels), sampleRate >= 8000,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        else { throw KlickError.unsupported("MP3 with \(channels) channels at \(Int(sampleRate)) Hz") }
        guard let lame = lame_init() else { throw KlickError.failed("Couldn't start the MP3 encoder") }
        self.lame = lame
        inputFormat = format

        lame_set_in_samplerate(lame, Int32(sampleRate.rounded()))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        // Keep the source rate when MP3 can store it; above 48 kHz, LAME picks the best one.
        let mpegRates: Set<Int32> = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        if mpegRates.contains(Int32(sampleRate.rounded())) { lame_set_out_samplerate(lame, Int32(sampleRate.rounded())) }
        lame_set_quality(lame, 2) // algorithm quality: 2 = near-best, still fast
        lame_set_write_id3tag_automatic(lame, 0)
        switch quality {
        case .variable(let preset):
            lame_set_VBR(lame, vbr_default)
            lame_set_VBR_quality(lame, Float(min(max(preset, 0), 9)))
            lame_set_bWriteVbrTag(lame, 1)
        case .constant(let kbps):
            lame_set_VBR(lame, vbr_off)
            lame_set_brate(lame, Int32(min(max(kbps, 32), 320)))
            lame_set_bWriteVbrTag(lame, 1) // the LAME tag still carries gapless info
        }
        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            throw KlickError.failed("The MP3 encoder rejected \(Int(sampleRate)) Hz")
        }

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            lame_close(lame)
            throw KlickError.failed("Couldn't create \(url.lastPathComponent)")
        }
        self.handle = handle
        self.url = url
    }

    deinit {
        if !finished { try? handle.close() }
        lame_close(lame)
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return }
        // Worst case from lame.h: 1.25 × samples + 7200 bytes.
        let capacity = frames + frames / 4 + 7200
        if scratch.count < capacity { scratch = [UInt8](repeating: 0, count: capacity) }
        let left = channels[0]
        let right = inputFormat.channelCount > 1 ? channels[1] : channels[0]
        let written = scratch.withUnsafeMutableBufferPointer { out in
            lame_encode_buffer_ieee_float(lame, left, right, Int32(frames), out.baseAddress, Int32(capacity))
        }
        guard written >= 0 else { throw KlickError.failed("MP3 encoding failed (\(written))") }
        try handle.write(contentsOf: scratch[0..<Int(written)])
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        defer { try? handle.close() }
        if scratch.count < 7200 { scratch = [UInt8](repeating: 0, count: 7200) }
        let flushed = scratch.withUnsafeMutableBufferPointer { out in
            lame_encode_flush(lame, out.baseAddress, Int32(out.count))
        }
        if flushed > 0 { try handle.write(contentsOf: scratch[0..<Int(flushed)]) }

        // Overwrite the placeholder first frame with the final Xing/LAME tag.
        var tag = [UInt8](repeating: 0, count: 2880)
        let size = tag.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        if size > 0, size <= tag.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tag[0..<size])
        }
    }
}

extension MP3Encoder {
    /// `Voice.wav` / `Clip.mov` → `Voice.mp3`: encodes the audio of any readable audio or
    /// video file (its first audio track) next to the original.
    /// - Parameters:
    ///   - suffix: optional word for the output name ("Compressed").
    ///   - bitRate: constant bit rate in bits per second; nil = VBR V2 (~190 kbps).
    static func encode(_ item: FileItem, suffix: String? = nil, bitRate: Int? = nil, progress: JobProgress) async throws -> URL {
        let source = try await AudioSource.open(item.url, name: item.name)
        let output = OutputNaming.url(for: item.url, suffix: suffix, ext: "mp3")
        try AudioRender.render(source, to: output, encoding: AudioEncoding(.mp3, bitRate: bitRate),
                               channels: min(source.channelCount, 2), progress: progress)
        return output
    }
}
