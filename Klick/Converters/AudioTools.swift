import AVFoundation

/// The audio wheel's conversions and tools. Every result is written next to the original.
enum AudioTools {
    /// Extensions macOS has no decoder for (Windows Media Audio).
    static let undecodableExtensions: Set<String> = ["wma", "asf"]

    static func canDecode(_ item: FileItem) -> Bool {
        !undecodableExtensions.contains(item.ext)
    }

    // MARK: Convert

    /// `Voice.wav` → `Voice.mp3` / `.m4a` / `.flac` / `.ogg` / `.opus` / `.aiff`.
    /// Works for the audio track of videos too.
    static func convert(_ item: FileItem, to format: AudioFormat, progress: JobProgress) async throws -> URL {
        let source = try await open(item)
        let output = OutputNaming.url(for: item.url, ext: format.ext)
        try AudioRender.render(source, to: output, encoding: .matching(source, as: format), progress: progress)
        return output
    }

    // MARK: Compress

    /// `Song.wav` → `Song Compressed.flac` (lossless); `Song.mp3` → a 128 kbps MP3;
    /// anything else → a 128 kbps AAC `.m4a`. Like video compression, a result that
    /// isn't at least 10% smaller is thrown away in favour of a lower bit rate.
    static func compress(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let source = try await open(item)
        let isPCM = source.codec == kAudioFormatLinearPCM && ["wav", "wave", "aif", "aiff", "aifc", "caf"].contains(item.ext)
        let mono = source.channelCount == 1
        let attempts: [AudioEncoding] = if isPCM {
            [AudioEncoding.matching(source, as: .flac)]
        } else if item.ext == "mp3" {
            [AudioEncoding(.mp3, bitRate: mono ? 64_000 : 128_000), AudioEncoding(.mp3, bitRate: mono ? 48_000 : 96_000)]
        } else {
            [AudioEncoding(.m4a, bitRate: mono ? 64_000 : 128_000), AudioEncoding(.m4a, bitRate: mono ? 48_000 : 96_000)]
        }

        for (index, encoding) in attempts.enumerated() {
            let span = Double(index) / Double(attempts.count)...Double(index + 1) / Double(attempts.count)
            let source = index == 0 ? source : try await open(item)
            let output = OutputNaming.url(for: item.url, suffix: "Compressed", ext: encoding.format.ext)
            try AudioRender.render(source, to: output, encoding: encoding, progress: progress, progressSpan: span)
            let newSize = Int64((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if Double(newSize) <= Double(item.size) * 0.9 { return output }
            try? FileManager.default.removeItem(at: output)
        }
        throw KlickError.failed("\(item.name) is already as small as it gets")
    }

    // MARK: Normalize

    /// Integrated loudness the normalizer aims for (streaming-service level).
    static let targetLoudness = -14.0
    /// Highest sample peak allowed after the gain, in dBFS.
    static let peakCeiling = -1.0

    /// `Talk.m4a` → `Talk Normalized.m4a`: one gain for the whole file that brings it to
    /// -14 LUFS, limited so peaks stay under -1 dBFS.
    static func normalize(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let meter = try await measure(item, progress: progress, span: 0...0.4)
        guard let loudness = meter.integrated, meter.peak > 0 else { throw KlickError.failed("\(item.name) is silent") }
        let peak = 20 * log10(Double(meter.peak))
        let gain = min(targetLoudness - loudness, peakCeiling - peak)
        guard abs(gain) >= 0.1 else { throw KlickError.failed("\(item.name) is already normalized") }
        NSLog("%@", "Klick: normalizing \(item.name): \(String(format: "%.1f", loudness)) LUFS, peak \(String(format: "%.1f", peak)) dBFS, gain \(String(format: "%+.1f", gain)) dB")

        let source = try await open(item)
        let (format, ext) = sameFormat(as: item)
        let output = OutputNaming.url(for: item.url, suffix: "Normalized", ext: ext)
        try AudioRender.render(source, to: output, encoding: .matching(source, as: format),
                               gain: Float(pow(10, gain / 20)), progress: progress, progressSpan: 0.4...1)
        return output
    }

    /// One analysis pass over the whole file.
    static func measure(_ item: FileItem, progress: JobProgress, span: ClosedRange<Double>) async throws -> LoudnessMeter {
        let source = try await open(item)
        let meter = LoudnessMeter(sampleRate: source.format.sampleRate, channels: source.channelCount)
        var position: AVAudioFramePosition = 0
        while let buffer = try source.read() {
            try progress.checkCancelled()
            meter.process(buffer)
            position += AVAudioFramePosition(buffer.frameLength)
            progress.report(span.lowerBound + (span.upperBound - span.lowerBound) * min(Double(position) / Double(source.length), 1))
        }
        meter.finish()
        return meter
    }

    // MARK: Channels

    /// Mono files become stereo (`Name Stereo.ext`, the channel duplicated); stereo and
    /// surround files are mixed down to mono (`Name Mono.ext`).
    static func toggleChannels(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let source = try await open(item)
        let (target, suffix) = source.channelCount == 1 ? (2, "Stereo") : (1, "Mono")
        return try await setChannels(item, source: source, to: target, suffix: suffix, progress: progress)
    }

    static func setChannels(_ item: FileItem, source: AudioSource? = nil, to channels: Int, suffix: String, progress: JobProgress) async throws -> URL {
        let source = if let source { source } else { try await open(item) }
        let (format, ext) = sameFormat(as: item)
        let output = OutputNaming.url(for: item.url, suffix: suffix, ext: ext)
        try AudioRender.render(source, to: output, encoding: .matching(source, as: format), channels: channels, progress: progress)
        return output
    }

    // MARK: Trim & bleep (editors)

    /// `Name Trimmed.ext`: the audio between `range.lowerBound` and `range.upperBound` seconds.
    static func trim(_ item: FileItem, range: ClosedRange<Double>, progress: JobProgress) async throws -> URL {
        let source = try await open(item)
        let (format, ext) = sameFormat(as: item)
        let output = OutputNaming.url(for: item.url, suffix: "Trimmed", ext: ext)
        try AudioRender.render(source, to: output, encoding: .matching(source, as: format), range: range, progress: progress)
        return output
    }

    /// `Name Bleeped.ext`: every range (in seconds) replaced by a 1 kHz tone, or silence.
    static func bleep(_ item: FileItem, ranges: [ClosedRange<Double>], silence: Bool, progress: JobProgress) async throws -> URL {
        let source = try await open(item)
        let (format, ext) = sameFormat(as: item)
        let output = OutputNaming.url(for: item.url, suffix: "Bleeped", ext: ext)
        let rate = source.format.sampleRate
        let frameRanges = ranges.map { AVAudioFramePosition($0.lowerBound * rate)..<AVAudioFramePosition($0.upperBound * rate) }
        let generator = BleepGenerator(sampleRate: rate, silence: silence)
        try AudioRender.render(source, to: output, encoding: .matching(source, as: format), transform: { buffer, position in
            generator.apply(to: buffer, at: position, ranges: frameRanges)
        }, progress: progress)
        return output
    }

    // MARK: Helpers

    static func open(_ item: FileItem) async throws -> AudioSource {
        guard canDecode(item) else { throw KlickError.unsupported("Windows Media Audio") }
        return try await AudioSource.open(item.url, name: item.name)
    }

    /// Format and extension for "same as the original" outputs (`.aif` stays `.aif`);
    /// formats Klick can't write become M4A.
    static func sameFormat(as item: FileItem) -> (AudioFormat, String) {
        guard let format = AudioFormat(fileExtension: item.ext) else { return (.m4a, "m4a") }
        return (format, ["aif", "oga", "m4b"].contains(item.ext) ? item.ext : format.ext)
    }
}

/// Replaces sample ranges with a 1 kHz tone (or silence), cross-fading 5 ms at each edge
/// so the cuts don't click.
struct BleepGenerator {
    static let frequency = 1000.0
    /// Tone level: -6 dBFS, loud enough to cover speech without clipping.
    static let level: Float = 0.5

    let sampleRate: Double
    let silence: Bool

    func apply(to buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition, ranges: [Range<AVAudioFramePosition>]) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = AVAudioFramePosition(buffer.frameLength)
        let fade = max(sampleRate * 0.005, 1)
        for range in ranges {
            let lower = max(range.lowerBound, position), upper = min(range.upperBound, position + frames)
            guard upper > lower else { continue }
            for frame in lower..<upper {
                // 0 at the edges of the range, 1 once fully inside.
                let edge = Double(min(frame - range.lowerBound, range.upperBound - 1 - frame))
                let mix = Float(min(edge / fade, 1))
                let tone = silence ? 0 : Self.level * Float(sin(2 * .pi * Self.frequency * Double(frame) / sampleRate))
                let index = Int(frame - position)
                for channel in 0..<Int(buffer.format.channelCount) {
                    channels[channel][index] = channels[channel][index] * (1 - mix) + tone * mix
                }
            }
        }
    }
}
