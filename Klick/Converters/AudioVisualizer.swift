import Accelerate
import AppKit
import AVFoundation
import CoreText

/// `Song.mp3` → `Song Visualizer.mp4`: a 720p video of the track — a live spectrum in
/// Klick orange on a dark stage, the title, and a progress waveform — with the audio in AAC.
enum AudioVisualizer {
    static let size = CGSize(width: 1280, height: 720)
    static let fps: Int32 = 30

    static func render(_ item: FileItem, progress: JobProgress) async throws -> URL {
        // Overview for the progress strip (first 15% of the job).
        let overview = try await AudioWaveform.load(item.url, buckets: 240) { progress.report(0.15 * $0) }
        try progress.checkCancelled()

        // The soundtrack and the picture are produced independently (each decodes the file),
        // so the writer can pull whichever it needs next without either side blocking the other.
        let soundtrack = try await SoundtrackProducer(source: AudioTools.open(item))
        let rate = soundtrack.format.sampleRate
        let channels = Int(soundtrack.format.channelCount)
        let frames = try await FrameProducer(
            source: AudioTools.open(item), sampleRate: rate,
            renderer: FrameRenderer(title: item.baseName, overview: overview.peaks, duration: max(overview.duration, 0.001))
        )

        let output = OutputNaming.url(for: item.url, suffix: "Visualizer", ext: "mp4")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
            ],
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: AudioEncoding.aacBitRate(channels == 2 ? 192_000 : 128_000, sampleRate: rate, channels: channels),
        ])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(video), writer.canAdd(audio) else { throw KlickError.unsupported("Writing MP4 video") }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw KlickError.failed("Couldn't create \(output.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)

        let pump = WriterPump(audio: audio, video: video, adaptor: adaptor, soundtrack: soundtrack, frames: frames, progress: progress)
        if let error = await pump.run() {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw (error as? KlickError) ?? KlickError.failed(writer.error?.localizedDescription ?? error.localizedDescription)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw KlickError.failed("Couldn't write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
        progress.report(1)
        return output
    }
}

/// Feeds both writer inputs from their own queues, each pulling from its producer
/// whenever AVAssetWriter asks for more.
private final class WriterPump: @unchecked Sendable {
    private let audio: AVAssetWriterInput
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let soundtrack: SoundtrackProducer
    private let frames: FrameProducer
    private let progress: JobProgress
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var failure: Error?

    init(audio: AVAssetWriterInput, video: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
         soundtrack: SoundtrackProducer, frames: FrameProducer, progress: JobProgress) {
        self.audio = audio
        self.video = video
        self.adaptor = adaptor
        self.soundtrack = soundtrack
        self.frames = frames
        self.progress = progress
    }

    /// Returns once both inputs are finished, with the first error raised, if any.
    func run() async -> Error? {
        group.enter()
        audio.requestMediaDataWhenReady(on: DispatchQueue(label: "io.exastudio.klick.visualizer.audio")) { [self] in
            pump(audio) {
                guard let sample = try soundtrack.next() else { return false }
                guard audio.append(sample) else { throw KlickError.failed("Couldn't encode the audio") }
                return true
            }
        }
        group.enter()
        video.requestMediaDataWhenReady(on: DispatchQueue(label: "io.exastudio.klick.visualizer.video")) { [self] in
            pump(video) {
                guard let pool = adaptor.pixelBufferPool else { throw KlickError.failed("The video encoder isn't ready") }
                guard let (pixels, time) = try frames.next(pool: pool) else { return false }
                guard adaptor.append(pixels, withPresentationTime: time) else { throw KlickError.failed("Couldn't encode a video frame") }
                progress.report(0.15 + 0.83 * frames.fraction)
                return true
            }
        }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }
        return error
    }

    private var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }

    /// Appends while `input` accepts data; `step` returns false at the end of its stream.
    private func pump(_ input: AVAssetWriterInput, step: () throws -> Bool) {
        do {
            while input.isReadyForMoreMediaData {
                try progress.checkCancelled()
                // Stop early when the other input failed.
                guard error == nil, try step() else { return finish(input) }
            }
        } catch {
            lock.lock()
            if failure == nil { failure = error }
            lock.unlock()
            finish(input)
        }
    }

    private func finish(_ input: AVAssetWriterInput) {
        input.markAsFinished()
        group.leave()
    }
}

// MARK: - Producers

/// Decoded audio as AVAssetWriter sample buffers (at most stereo, at a rate AAC supports).
private final class SoundtrackProducer: @unchecked Sendable {
    let format: AVAudioFormat
    private let source: AudioSource
    private let adapter: PCMAdapter
    private var pending: [AVAudioPCMBuffer] = []
    private var flushed = false
    private var written: Int64 = 0

    init(source: AudioSource) throws {
        let rates: [Double] = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000]
        let rate = rates.contains(source.format.sampleRate) ? source.format.sampleRate : 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(min(source.channelCount, 2))) else {
            throw KlickError.unsupported("This audio layout")
        }
        self.source = source
        self.format = format
        adapter = try PCMAdapter(from: source.format, to: format)
    }

    func next() throws -> CMSampleBuffer? {
        while pending.isEmpty {
            if let buffer = try source.read() {
                try adapter.push(buffer) { pending.append($0) }
            } else if !flushed {
                flushed = true
                try adapter.finish { pending.append($0) }
            } else {
                return nil
            }
        }
        let buffer = pending.removeFirst()
        guard let sample = buffer.sampleBuffer(at: CMTime(value: written, timescale: CMTimeScale(format.sampleRate))) else {
            throw KlickError.failed("Couldn't package the audio")
        }
        written += Int64(buffer.frameLength)
        return sample
    }
}

/// Video frames: each one analyzes the 2048 samples that end where the frame ends.
private final class FrameProducer: @unchecked Sendable {
    private let source: AudioSource
    private let adapter: PCMAdapter
    private let renderer: FrameRenderer
    private let spectrum: Spectrum
    private let samplesPerFrame: Double
    private let totalSamples: Double
    /// Mono mix; `history[0]` is sample number `historyStart`.
    private var history = [Float](repeating: 0, count: Spectrum.size)
    private var historyStart = -Int64(Spectrum.size)
    private var ended = false
    private var frame: Int64 = 0

    init(source: AudioSource, sampleRate: Double, renderer: FrameRenderer) throws {
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw KlickError.unsupported("This audio layout")
        }
        self.source = source
        self.renderer = renderer
        adapter = try PCMAdapter(from: source.format, to: mono)
        spectrum = Spectrum(sampleRate: sampleRate, bands: FrameRenderer.barCount)
        samplesPerFrame = sampleRate / Double(AudioVisualizer.fps)
        totalSamples = max(Double(source.length) * sampleRate / source.format.sampleRate, 1)
    }

    /// Share of the frames rendered so far.
    var fraction: Double { min(Double(frame) * samplesPerFrame / totalSamples, 1) }

    private var analyzedEnd: Int64 { historyStart + Int64(history.count) }

    func next(pool: CVPixelBufferPool) throws -> (CVPixelBuffer, CMTime)? {
        let windowEnd = Int64(Double(frame + 1) * samplesPerFrame)
        while !ended, analyzedEnd < windowEnd {
            if let buffer = try source.read() {
                try adapter.push(buffer) { history.append(contentsOf: UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength))) }
            } else {
                ended = true
                try adapter.finish { history.append(contentsOf: UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength))) }
            }
        }
        // Stop once a frame would start after the last sample.
        if ended, Double(frame) * samplesPerFrame >= Double(analyzedEnd) { return nil }
        if analyzedEnd < windowEnd { history.append(contentsOf: [Float](repeating: 0, count: Int(windowEnd - analyzedEnd))) }

        let offset = Int(windowEnd - historyStart) - Spectrum.size
        let levels = history.withUnsafeBufferPointer { spectrum.levels(of: $0.baseAddress! + offset) }
        // Forget what no later window needs.
        if offset > 1 << 16 {
            history.removeFirst(offset)
            historyStart += Int64(offset)
        }

        var pixels: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixels)
        guard let pixels else { throw KlickError.failed("Out of memory") }
        renderer.draw(levels: levels, time: Double(frame) / Double(AudioVisualizer.fps), into: pixels)
        let time = CMTime(value: frame, timescale: AudioVisualizer.fps)
        frame += 1
        return (pixels, time)
    }
}

// MARK: - Spectrum

/// Log-spaced band levels (0...1) of a 2048-sample window, smoothed over time like a VU meter.
private final class Spectrum {
    static let size = 2048
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    /// FFT bin range and center frequency of each bar.
    private let bands: [(bins: Range<Int>, frequency: Double)]
    private var smoothed: [Float]

    init(sampleRate: Double, bands count: Int) {
        let half = Spectrum.size / 2
        setup = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        window = .allocate(capacity: Spectrum.size)
        windowed = .allocate(capacity: Spectrum.size)
        real = .allocate(capacity: half)
        imag = .allocate(capacity: half)
        magnitudes = .allocate(capacity: half)
        vDSP_hann_window(window, vDSP_Length(Spectrum.size), Int32(vDSP_HANN_NORM))

        let low = 50.0, high = min(14_000, sampleRate / 2 * 0.95)
        let binWidth = sampleRate / Double(Spectrum.size)
        bands = (0..<count).map { index in
            let from = low * pow(high / low, Double(index) / Double(count))
            let to = low * pow(high / low, Double(index + 1) / Double(count))
            let first = max(Int(from / binWidth), 1)
            let last = min(max(Int(to / binWidth), first + 1), half)
            return (first..<last, sqrt(from * to))
        }
        smoothed = [Float](repeating: 0, count: count)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        [window, windowed, real, imag, magnitudes].forEach { $0.deallocate() }
    }

    func levels(of samples: UnsafePointer<Float>) -> [Float] {
        let half = Spectrum.size / 2
        vDSP_vmul(samples, 1, window, 1, windowed, 1, vDSP_Length(Spectrum.size))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(half))

        for (index, band) in bands.enumerated() {
            var loudest: Float = 0
            for bin in band.bins { loudest = max(loudest, magnitudes[bin]) }
            // A full-scale sine reads 0 dB; +3 dB per octave above 1 kHz evens out typical music.
            let amplitude = sqrt(loudest) / Float(half)
            let decibels = 20 * log10(max(amplitude, 1e-9)) + Float(3 * log2(band.frequency / 1000))
            let level = min(max((decibels + 62) / 52, 0), 1)
            let previous = smoothed[index]
            smoothed[index] = level > previous ? previous + (level - previous) * 0.65 : max(level, previous * 0.86)
        }
        return smoothed
    }
}

// MARK: - Drawing

private final class FrameRenderer {
    static let barCount = 48
    private let size = AudioVisualizer.size
    private let background: CGImage
    private let overview: [Float]
    private let duration: Double
    private let accent = Theme.accentNS.cgColor
    private let accentLight = CGColor(srgbRed: 1.00, green: 0.45, blue: 0.22, alpha: 1)
    private let accentDeep = CGColor(srgbRed: 0.86, green: 0.17, blue: 0.07, alpha: 1)
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 20, weight: .medium)

    init(title: String, overview: [Float], duration: Double) {
        self.overview = overview
        self.duration = duration
        background = FrameRenderer.makeBackground(title: title, duration: duration, size: AudioVisualizer.size)
    }

    /// Dark stage with a soft orange glow behind the bars, plus the title.
    private static func makeBackground(title: String, duration: Double, size: CGSize) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let stage = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.085, green: 0.08, blue: 0.09, alpha: 1),
            CGColor(srgbRed: 0.035, green: 0.035, blue: 0.04, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(stage, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        let glow = CGGradient(colorsSpace: space, colors: [
            Theme.accentNS.withAlphaComponent(0.22).cgColor,
            Theme.accentNS.withAlphaComponent(0).cgColor,
        ] as CFArray, locations: [0, 1])!
        let center = CGPoint(x: size.width / 2, y: size.height - 340)
        context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 560, options: [])

        // Title (shortened to fit) and length, top left.
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 36, weight: .bold), .foregroundColor: CGColor(gray: 1, alpha: 0.95),
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: titleAttributes))
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: titleAttributes))
        line = CTLineCreateTruncatedLine(line, size.width - 128, .end, token) ?? line
        context.textPosition = CGPoint(x: 64, y: size.height - 92)
        CTLineDraw(line, context)

        let subtitle = CTLineCreateWithAttributedString(NSAttributedString(string: FrameRenderer.clock(duration), attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: CGColor(gray: 1, alpha: 0.5),
        ]))
        context.textPosition = CGPoint(x: 64, y: size.height - 128)
        CTLineDraw(subtitle, context)
        return context.makeImage()!
    }

    func draw(levels: [Float], time: Double, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer), width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.draw(background, in: CGRect(origin: .zero, size: size))
        drawBars(levels, in: context)
        drawProgress(time: time, in: context)
    }

    /// Mirrored rounded bars around the stage's center line, with an orange glow.
    private func drawBars(_ levels: [Float], in context: CGContext) {
        let width: CGFloat = 1152, gap: CGFloat = 8
        let barWidth = (width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count)
        let midY = size.height - 340, maxHalf: CGFloat = 170
        let path = CGMutablePath()
        for (index, level) in levels.enumerated() {
            let half = max(CGFloat(level) * maxHalf, barWidth / 2)
            let x = (size.width - width) / 2 + CGFloat(index) * (barWidth + gap)
            path.addRoundedRect(in: CGRect(x: x, y: midY - half, width: barWidth, height: half * 2),
                                cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
        }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 28, color: Theme.accentNS.withAlphaComponent(0.65).cgColor)
        context.addPath(path)
        context.setFillColor(accent)
        context.fillPath()
        context.restoreGState()

        // Light-to-deep gradient over the bars.
        context.saveGState()
        context.addPath(path)
        context.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [accentLight, accent, accentDeep] as CFArray, locations: [0, 0.5, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: midY + maxHalf), end: CGPoint(x: 0, y: midY - maxHalf), options: [])
        context.restoreGState()
    }

    /// Waveform strip that fills with orange as the track plays, plus elapsed / remaining time.
    private func drawProgress(time: Double, in context: CGContext) {
        let left: CGFloat = 64, width = size.width - 128
        let midY: CGFloat = 120, maxHalf: CGFloat = 26
        let fraction = CGFloat(min(max(time / duration, 0), 1))
        let step = width / CGFloat(max(overview.count, 1))
        let played = CGMutablePath(), upcoming = CGMutablePath()
        for (index, peak) in overview.enumerated() {
            let half = max(CGFloat(sqrt(peak)) * maxHalf, 1.5)
            let x = left + CGFloat(index) * step
            let rect = CGRect(x: x + step * 0.2, y: midY - half, width: step * 0.6, height: half * 2)
            (x + step / 2 <= left + width * fraction ? played : upcoming)
                .addRoundedRect(in: rect, cornerWidth: step * 0.3, cornerHeight: min(step * 0.3, half))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.18))
        context.addPath(upcoming)
        context.fillPath()
        context.setFillColor(accent)
        context.addPath(played)
        context.fillPath()

        // Playhead.
        let x = left + width * fraction
        context.setFillColor(CGColor(gray: 1, alpha: 0.95))
        context.fill(CGRect(x: x - 1, y: midY - maxHalf - 8, width: 2, height: maxHalf * 2 + 16))

        let attributes: [NSAttributedString.Key: Any] = [.font: timeFont, .foregroundColor: CGColor(gray: 1, alpha: 0.6)]
        let elapsed = CTLineCreateWithAttributedString(NSAttributedString(string: FrameRenderer.clock(time), attributes: attributes))
        context.textPosition = CGPoint(x: left, y: midY - maxHalf - 44)
        CTLineDraw(elapsed, context)
        let remaining = CTLineCreateWithAttributedString(NSAttributedString(string: "-" + FrameRenderer.clock(max(duration.rounded(.down) - time.rounded(.down), 0)), attributes: attributes))
        let remainingWidth = CTLineGetTypographicBounds(remaining, nil, nil, nil)
        context.textPosition = CGPoint(x: left + width - remainingWidth, y: midY - maxHalf - 44)
        CTLineDraw(remaining, context)
    }

    /// `m:ss` or `h:mm:ss`.
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Sample buffers

extension AVAudioPCMBuffer {
    /// Wraps the buffer's samples in a `CMSampleBuffer` starting at `time`, for AVAssetWriter.
    func sampleBuffer(at time: CMTime) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &description) == noErr, let description
        else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: time.timescale), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                   formatDescription: description, sampleCount: CMItemCount(frameLength),
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &sample) == noErr, let sample,
              CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                            flags: 0, bufferList: audioBufferList) == noErr
        else { return nil }
        return sample
    }
}
