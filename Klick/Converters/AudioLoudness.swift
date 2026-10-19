import AVFoundation

/// Integrated loudness (ITU-R BS.1770-4 / EBU R128) and sample peak of a stream,
/// measured in one pass.
final class LoudnessMeter {
    /// Gated integrated loudness in LUFS; nil for silence or very short clips.
    private(set) var integrated: Double?
    /// Highest absolute sample value seen.
    private(set) var peak: Float = 0

    private let channels: Int
    private var filters: [KWeighting]
    /// Frames per 100 ms step; a gating block is four steps (400 ms, 75% overlap).
    private let stepLength: Int
    private var stepEnergy = 0.0
    private var stepFrames = 0
    private var steps: [Double] = []

    init(sampleRate: Double, channels: Int) {
        self.channels = channels
        filters = (0..<channels).map { _ in KWeighting(sampleRate: sampleRate) }
        stepLength = max(Int(sampleRate / 10), 1)
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        var frame = 0
        while frame < frames {
            let count = min(stepLength - stepFrames, frames - frame)
            for channel in 0..<channels {
                // The LFE channel of 5.1 doesn't count (BS.1770 channel weights).
                let weight = (channels == 6 && channel == 3) ? 0.0 : 1.0
                let samples = data[channel]
                var energy = 0.0
                for index in frame..<frame + count {
                    let sample = samples[index]
                    peak = max(peak, abs(sample))
                    let weighted = filters[channel].process(Double(sample))
                    energy += weighted * weighted
                }
                stepEnergy += weight * energy
            }
            stepFrames += count
            frame += count
            if stepFrames == stepLength {
                steps.append(stepEnergy / Double(stepLength))
                stepEnergy = 0
                stepFrames = 0
            }
        }
    }

    /// Computes `integrated` from the gated 400 ms blocks.
    func finish() {
        if stepFrames > 0, steps.count < 4 { steps.append(stepEnergy / Double(stepFrames)) }
        var blocks: [Double] = []
        if steps.count >= 4 {
            for index in 3..<steps.count {
                let sum: Double = steps[index - 3] + steps[index - 2] + steps[index - 1] + steps[index]
                blocks.append(sum / 4)
            }
        } else {
            blocks = [steps.reduce(0, +) / Double(max(steps.count, 1))]
        }
        func loudness(_ energy: Double) -> Double { -0.691 + 10 * log10(energy) }

        let audible = blocks.filter { $0 > 0 && loudness($0) > -70 } // absolute gate
        guard !audible.isEmpty else { integrated = nil; return }
        let relativeGate = loudness(audible.reduce(0, +) / Double(audible.count)) - 10
        let gated = audible.filter { loudness($0) > relativeGate }
        integrated = loudness(gated.reduce(0, +) / Double(max(gated.count, 1)))
    }
}

/// The two-stage K-weighting filter (high shelf + high-pass) for any sample rate,
/// with the coefficients derived as in libebur128.
private struct KWeighting {
    private let b0, b1, b2, b3, b4: Double
    private let a1, a2, a3, a4: Double
    // Last four inputs and outputs.
    private var x1 = 0.0, x2 = 0.0, x3 = 0.0, x4 = 0.0
    private var y1 = 0.0, y2 = 0.0, y3 = 0.0, y4 = 0.0

    init(sampleRate rate: Double) {
        // Stage 1: high shelf, +4 dB above ~1.7 kHz.
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(.pi * f0 / rate)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1 + k / q + k * k
        let pb = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0]
        let pa = [1, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        // Stage 2: RLB high-pass at ~38 Hz.
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(.pi * f0 / rate)
        let rb = [1.0, -2.0, 1.0]
        let ra = [1, 2 * (k * k - 1) / (1 + k / q + k * k), (1 - k / q + k * k) / (1 + k / q + k * k)]
        // Cascade both biquads into one 4th-order filter.
        b0 = pb[0] * rb[0]
        b1 = pb[0] * rb[1] + pb[1] * rb[0]
        b2 = pb[0] * rb[2] + pb[1] * rb[1] + pb[2] * rb[0]
        b3 = pb[1] * rb[2] + pb[2] * rb[1]
        b4 = pb[2] * rb[2]
        a1 = pa[1] + ra[1]
        a2 = pa[1] * ra[1] + pa[2] + ra[2]
        a3 = pa[1] * ra[2] + pa[2] * ra[1]
        a4 = pa[2] * ra[2]
    }

    mutating func process(_ input: Double) -> Double {
        let output = b0 * input + b1 * x1 + b2 * x2 + b3 * x3 + b4 * x4 - a1 * y1 - a2 * y2 - a3 * y3 - a4 * y4
        x4 = x3; x3 = x2; x2 = x1; x1 = input
        y4 = y3; y3 = y2; y2 = y1; y1 = output
        return output
    }
}
