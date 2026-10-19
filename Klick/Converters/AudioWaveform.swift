import AVFoundation

/// Overview of a file's amplitude: the loudest sample of each of `peaks.count`
/// equal slices, for drawing waveforms.
struct AudioWaveform {
    /// Normalized 0...1 peaks (the loudest slice is 1).
    let peaks: [Float]
    let duration: Double
    let sampleRate: Double
    let channels: Int

    /// Decodes `url` once. `progress` receives 0...1.
    static func load(_ url: URL, buckets: Int, progress: ((Double) -> Void)? = nil) async throws -> AudioWaveform {
        let source = try await AudioSource.open(url)
        let framesPerBucket = max(Double(source.length) / Double(buckets), 1)
        var peaks = [Float](repeating: 0, count: buckets)
        var position = 0
        while let buffer = try source.read() {
            try Task.checkCancellation()
            guard let data = buffer.floatChannelData else { continue }
            for channel in 0..<Int(buffer.format.channelCount) {
                let samples = data[channel]
                var frame = 0
                while frame < Int(buffer.frameLength) {
                    let bucket = min(Int(Double(position + frame) / framesPerBucket), buckets - 1)
                    // Last frame of this bucket inside the buffer.
                    let bucketEnd = min(Int((Double(bucket + 1) * framesPerBucket).rounded(.up)) - position, Int(buffer.frameLength))
                    var peak = peaks[bucket]
                    for index in frame..<max(bucketEnd, frame + 1) { peak = max(peak, abs(samples[index])) }
                    peaks[bucket] = peak
                    frame = max(bucketEnd, frame + 1)
                }
            }
            position += Int(buffer.frameLength)
            progress?(min(Double(position) / Double(source.length), 1))
        }
        let loudest = max(peaks.max() ?? 0, 0.0001)
        return AudioWaveform(
            peaks: peaks.map { $0 / loudest },
            duration: Double(position) / source.format.sampleRate,
            sampleRate: source.format.sampleRate,
            channels: source.channelCount
        )
    }
}
