import AVFoundation
import SwiftUI

/// Pieces shared by the audio editors (Trim, Bleep): preview playback, the waveform
/// and the transport controls.
enum AudioEditorKit {
    static let cardWidth: CGFloat = 480
    static let waveformHeight: CGFloat = 112
    /// Waveform bars per point of width (one 2 pt bar + 1 pt gap).
    static let barPitch: CGFloat = 3

    /// `1:05.3` (tenths) or `1:05`.
    static func clock(_ seconds: Double, tenths: Bool = true) -> String {
        let clamped = max(seconds, 0)
        let minutes = Int(clamped) / 60
        if !tenths { return String(format: "%d:%02d", minutes, Int(clamped) % 60) }
        let rest = clamped - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, (rest * 10).rounded(.down) / 10)
    }

    /// Loads the waveform for an editor, or tells the user and returns nil.
    @MainActor
    static func loadWaveform(_ item: FileItem, width: CGFloat) async -> AudioWaveform? {
        let buckets = Int(width / barPitch)
        do {
            return try await Task.detached(priority: .userInitiated) {
                try await AudioWaveform.load(item.url, buckets: buckets)
            }.value
        } catch {
            Feedback.shared.failure()
            Toast.shared.showMessage("Couldn't open \(item.name)", symbol: "exclamationmark.triangle.fill")
            return nil
        }
    }
}

// MARK: - Preview player

/// Plays a stretch of the file through the system output. While playing it can swap
/// "bleep" ranges for a 1 kHz tone (or silence), so the Bleep editor previews its result.
@MainActor
final class AudioPreviewPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    /// Playhead, in seconds.
    @Published var position: Double = 0

    /// Ranges (seconds) replaced while playing.
    var bleepRanges: [ClosedRange<Double>] = []
    var bleepSilence = false

    private let url: URL
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var tone: AVAudioSourceNode?
    private var file: AVAudioFile?
    private var segmentStart = 0.0
    private var segmentEnd = 0.0
    private var timer: Timer?

    init(url: URL) {
        self.url = url
    }

    /// Plays from `start` to `end` seconds.
    func play(from start: Double, to end: Double) {
        stop()
        do {
            try prepare()
        } catch {
            NSLog("%@", "Klick: audio preview failed: \(error)")
            Feedback.shared.failure()
            return
        }
        guard let file, let player else { return }
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(start, 0) * rate)
        let count = AVAudioFramePosition(end * rate) - first
        guard count > 0, first < file.length else { return }
        segmentStart = start
        segmentEnd = end
        position = start
        player.scheduleSegment(file, startingFrame: first, frameCount: AVAudioFrameCount(min(count, file.length - first)), at: nil)
        player.play()
        isPlaying = true
        updateBleep()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        isPlaying = false
    }

    /// Stops playback and releases the audio engine (call when the editor closes).
    func shutdown() {
        stop()
        engine?.stop()
        engine = nil
    }

    private func prepare() throws {
        if let engine {
            // The engine stops when the output device changes; playing a stopped engine throws.
            if !engine.isRunning { try engine.start() }
            return
        }
        let file = try AVAudioFile(forReading: url)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        let tone = AudioPreviewPlayer.makeTone(sampleRate: file.processingFormat.sampleRate)
        engine.attach(tone)
        engine.connect(tone, to: engine.mainMixerNode, format: AVAudioFormat(standardFormatWithSampleRate: file.processingFormat.sampleRate, channels: 1))
        tone.volume = 0
        try engine.start()
        self.file = file
        self.engine = engine
        self.player = player
        self.tone = tone
    }

    /// A continuous 1 kHz sine at the bleep level; its mixer volume switches it on and off.
    /// Built outside the main actor: the render block runs on the audio thread.
    nonisolated private static func makeTone(sampleRate: Double) -> AVAudioSourceNode {
        let phase = TonePhase()
        let increment = 2 * Double.pi * BleepGenerator.frequency / sampleRate
        return AVAudioSourceNode { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let value = BleepGenerator.level * Float(sin(phase.value))
                phase.value = (phase.value + increment).truncatingRemainder(dividingBy: 2 * .pi)
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            return noErr
        }
    }

    private func tick() {
        guard isPlaying, let player, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return }
        position = min(segmentStart + Double(playerTime.sampleTime) / playerTime.sampleRate, segmentEnd)
        updateBleep()
        if position >= segmentEnd - 0.005 { stop() }
    }

    private func updateBleep() {
        let bleeping = isPlaying && bleepRanges.contains { $0.contains(position) }
        player?.volume = bleeping ? 0 : 1
        tone?.volume = bleeping && !bleepSilence ? 1 : 0
    }
}

/// Oscillator state owned by the audio render thread.
private final class TonePhase: @unchecked Sendable {
    var value = 0.0
}

// MARK: - Views

/// Mirrored bar waveform. Bars whose center lies in `highlight` (fractions of the
/// duration) are drawn with the accent gradient, the rest are dimmed.
struct WaveformBars: View {
    let peaks: [Float]
    var highlight: [ClosedRange<Double>] = []

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let step = size.width / CGFloat(peaks.count)
            var lit = Path(), dim = Path()
            for (index, peak) in peaks.enumerated() {
                // Square root lifts quiet passages so speech stays readable.
                let height = max(CGFloat(peak.squareRoot()) * size.height * 0.9, 2)
                let rect = CGRect(x: CGFloat(index) * step + step / 6, y: (size.height - height) / 2, width: max(step * 2 / 3, 1), height: height)
                let center = (Double(index) + 0.5) / Double(peaks.count)
                let bar = Path(roundedRect: rect, cornerRadius: min(rect.width / 2, 1.5))
                if highlight.contains(where: { $0.contains(center) }) { lit.addPath(bar) } else { dim.addPath(bar) }
            }
            context.fill(dim, with: .color(Color.primary.opacity(0.24)))
            context.fill(lit, with: .linearGradient(
                Gradient(colors: [Theme.accentLight, Theme.accent, Theme.accentDeep]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
    }
}

/// Thin white line with a knob, marking the playback position.
struct Playhead: View {
    var body: some View {
        VStack(spacing: 0) {
            Circle().fill(.white).frame(width: 7, height: 7)
            Rectangle().fill(.white).frame(width: 1.5)
        }
        .shadow(color: .black.opacity(0.35), radius: 1.5)
        .allowsHitTesting(false)
    }
}

/// Round play / pause button.
struct PlayPauseButton: View {
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.accent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(isPlaying ? "Pause (Space)" : "Play (Space)")
    }
}

/// "In  0:01.2" style caption.
struct TimeCaption: View {
    let title: String
    let seconds: Double
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(AudioEditorKit.clock(seconds))
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
        }
    }
}

/// Rounded well the waveform sits in, with a spinner until it has loaded.
struct WaveformWell<Content: View>: View {
    let isLoaded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.05))
            if isLoaded {
                content.transition(.opacity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: AudioEditorKit.waveformHeight)
        .animation(.easeOut(duration: 0.2), value: isLoaded)
    }
}
