import AppKit
import AVFoundation

/// Tiny synthesized "taptic" sounds + real trackpad haptics.
///
/// Every sound is a few milliseconds of a low sine (150–260 Hz, the band a
/// Taptic Engine vibrates in) with a very fast exponential decay and a faint
/// high transient on top, so it reads as a physical *tick* rather than a beep.
final class Feedback {
    static let shared = Feedback()

    private enum Sound: CaseIterable {
        case tick, open, select, page, close, success, failure
    }

    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    private var buffers: [Sound: AVAudioPCMBuffer] = [:]
    private var nextPlayer = 0
    private var idleTimer: Timer?
    private let settings = AppSettings.shared

    private init() {
        for sound in Sound.allCases { buffers[sound] = makeBuffer(for: sound) }
        for _ in 0..<4 {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            players.append(player)
        }
        engine.mainMixerNode.outputVolume = 1
        engine.prepare()
    }

    // MARK: Public API

    /// Spins the audio engine up ahead of time (called when the trigger goes down).
    func warmUp() {
        guard settings.soundsEnabled else { return }
        startEngineIfNeeded()
    }

    func tick() { play(.tick, haptic: .alignment) }
    func open() { play(.open, haptic: nil) }
    func select() { play(.select, haptic: .levelChange) }
    func page() { play(.page, haptic: .alignment) }
    func close() { play(.close, haptic: nil) }
    func success() { play(.success, haptic: nil) }
    func failure() { play(.failure, haptic: .generic) }

    // MARK: Playback

    private func play(_ sound: Sound, haptic: NSHapticFeedbackManager.FeedbackPattern?) {
        if let haptic, settings.hapticsEnabled {
            NSHapticFeedbackManager.defaultPerformer.perform(haptic, performanceTime: .now)
        }
        guard settings.soundsEnabled, let buffer = buffers[sound] else { return }
        startEngineIfNeeded()
        guard engine.isRunning else { return }
        let player = players[nextPlayer]
        nextPlayer = (nextPlayer + 1) % players.count
        player.volume = Float(settings.soundVolume)
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        scheduleIdleStop()
    }

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { scheduleIdleStop(); return }
        do {
            try engine.start()
            scheduleIdleStop()
        } catch {
            NSLog("%@", "Klick: audio engine failed: \(error)")
        }
    }

    /// Stop the engine when idle so the audio hardware can sleep.
    private func scheduleIdleStop() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.players.forEach { $0.stop() }
            self.engine.pause()
        }
    }

    // MARK: Synthesis

    private struct Partial {
        var frequency: Double
        var endFrequency: Double? = nil
        var amplitude: Double
        var decay: Double // seconds (time constant)
        var delay: Double = 0
    }

    private func makeBuffer(for sound: Sound) -> AVAudioPCMBuffer {
        let partials: [Partial]
        let noiseAmount: Double
        switch sound {
        case .tick:
            partials = [Partial(frequency: 210, amplitude: 0.55, decay: 0.006),
                        Partial(frequency: 420, amplitude: 0.12, decay: 0.003)]
            noiseAmount = 0.10
        case .page:
            partials = [Partial(frequency: 250, amplitude: 0.55, decay: 0.007),
                        Partial(frequency: 175, amplitude: 0.35, decay: 0.008, delay: 0.035)]
            noiseAmount = 0.08
        case .open:
            partials = [Partial(frequency: 120, endFrequency: 210, amplitude: 0.5, decay: 0.022),
                        Partial(frequency: 360, amplitude: 0.06, decay: 0.01)]
            noiseAmount = 0.04
        case .select:
            partials = [Partial(frequency: 190, amplitude: 0.6, decay: 0.008),
                        Partial(frequency: 260, amplitude: 0.5, decay: 0.010, delay: 0.045)]
            noiseAmount = 0.10
        case .close:
            partials = [Partial(frequency: 200, endFrequency: 130, amplitude: 0.35, decay: 0.014)]
            noiseAmount = 0.03
        case .success:
            partials = [Partial(frequency: 230, amplitude: 0.45, decay: 0.009),
                        Partial(frequency: 310, amplitude: 0.42, decay: 0.012, delay: 0.06)]
            noiseAmount = 0.06
        case .failure:
            partials = [Partial(frequency: 160, amplitude: 0.5, decay: 0.012),
                        Partial(frequency: 120, amplitude: 0.5, decay: 0.016, delay: 0.07)]
            noiseAmount = 0.05
        }

        let sampleRate = format.sampleRate
        let length = (partials.map { $0.delay + $0.decay * 7 }.max() ?? 0.05) + 0.005
        let frameCount = AVAudioFrameCount(length * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        var rng = SystemRandomNumberGenerator()
        var lowpass = 0.0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var sample = 0.0
            for p in partials where t >= p.delay {
                let local = t - p.delay
                let attack = min(local / 0.0007, 1) // 0.7 ms attack avoids clicks
                let envelope = attack * exp(-local / p.decay)
                let freq: Double
                if let end = p.endFrequency {
                    let k = min(local / (p.decay * 5), 1)
                    freq = p.frequency + (end - p.frequency) * k
                } else {
                    freq = p.frequency
                }
                sample += sin(2 * .pi * freq * local) * envelope * p.amplitude
            }
            // Short filtered noise transient = the "click" of the taptic mass.
            if t < 0.002 {
                let white = Double.random(in: -1...1, using: &rng)
                lowpass += (white - lowpass) * 0.35
                sample += lowpass * noiseAmount * (1 - t / 0.002)
            }
            data[frame] = Float(sample * 0.5)
        }
        return buffer
    }
}
