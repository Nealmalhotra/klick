import AVFoundation
import SwiftUI

/// A video opened in an editor: its size and length, a player to preview it and the
/// filmstrip shown in the timeline.
@MainActor
final class VideoClip: ObservableObject {
    let item: FileItem
    let asset: AVURLAsset
    let info: VideoInfo
    let player: AVPlayer

    /// Where the playhead is, in seconds (follows playback and scrubbing).
    @Published private(set) var time: Double = 0
    @Published private(set) var isPlaying = false
    /// Evenly spaced frames for the timeline; nil until decoded.
    @Published private(set) var thumbnails: [CGImage?] = []

    /// Playback stays inside this range (the trim selection); nil plays the whole clip.
    var playbackRange: ClosedRange<Double>?
    /// Rate `play()` uses (the Speed editor previews its choice).
    var rate: Float = 1 {
        didSet { if isPlaying { player.rate = rate } }
    }

    var duration: Double { info.seconds }
    /// Displayed size in pixels (rotation applied).
    var pixelSize: CGSize { info.displaySize }

    private var timeObserver: Any?
    private var pendingSeek: Double?
    private var seekTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?

    /// Opens `item` and hands it to `open`, or tells the user why it can't be edited.
    static func open(_ item: FileItem, then open: @escaping @MainActor (VideoClip) -> Void) {
        Task {
            do {
                let asset = try await VideoExport.loadAsset(item)
                let info = try await VideoExport.info(of: asset)
                guard info.seconds > 0.1 else { throw KlickError.failed("\(item.name) is too short to edit") }
                open(VideoClip(item: item, asset: asset, info: info))
            } catch {
                Feedback.shared.failure()
                let message = (error as? KlickError)?.errorDescription ?? "Couldn't open \(item.name)"
                Toast.shared.showMessage(message, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private init(item: FileItem, asset: AVURLAsset, info: VideoInfo) {
        self.item = item
        self.asset = asset
        self.info = info
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: playerItem)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(to: time.seconds) }
        }
    }

    /// Stops playback and background work; call when the editor goes away.
    func shutdown() {
        player.pause()
        isPlaying = false
        thumbnailTask?.cancel()
        seekTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
    }

    // MARK: Playback

    func togglePlayback() {
        isPlaying ? pause() : play()
        Feedback.shared.tick()
    }

    func play() {
        let range = playbackRange ?? 0...duration
        // From the start of the selection when the playhead is outside it or at its end.
        if time < range.lowerBound - 0.01 || time >= range.upperBound - 0.05 {
            seek(to: range.lowerBound)
        }
        isPlaying = true
        player.playImmediately(atRate: rate)
    }

    func pause() {
        guard isPlaying else { return }
        player.pause()
        isPlaying = false
    }

    /// Frame-accurate seek. While a seek is running only the latest target is kept,
    /// so scrubbing stays responsive however fast the pointer moves.
    func seek(to seconds: Double) {
        time = min(max(seconds, 0), duration)
        pendingSeek = time
        guard seekTask == nil else { return }
        seekTask = Task { [weak self] in
            while let self, let target = self.pendingSeek {
                self.pendingSeek = nil
                _ = await self.player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            self?.seekTask = nil
        }
    }

    /// Moves the playhead by whole frames (arrow keys).
    func step(by frames: Int) {
        pause()
        seek(to: time + Double(frames) * info.frameDuration.seconds)
    }

    private func playerMoved(to seconds: Double) {
        guard seconds.isFinite, seekTask == nil else { return }
        time = min(max(seconds, 0), duration)
        guard isPlaying else { return }
        if let range = playbackRange, seconds >= range.upperBound {
            pause()
            seek(to: range.upperBound)
        } else if player.timeControlStatus == .paused {
            // Reached the end of the clip.
            isPlaying = false
        }
    }

    // MARK: Frames

    /// Decodes `count` evenly spaced frames for the timeline, about `height` points tall.
    func loadThumbnails(count: Int, height: CGFloat) {
        guard thumbnails.count != count else { return }
        thumbnailTask?.cancel()
        thumbnails = Array(repeating: nil, count: count)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let aspect = pixelSize.width / max(pixelSize.height, 1)
        generator.maximumSize = CGSize(width: height * 2 * aspect, height: height * 2)
        let spacing = duration / Double(count)
        let tolerance = CMTime(seconds: spacing / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) * spacing, preferredTimescale: 600) }

        thumbnailTask = Task { [weak self] in
            var index = 0
            for await result in generator.images(for: times) {
                guard let self, !Task.isCancelled, index < self.thumbnails.count else { return }
                if let image = try? result.image {
                    withAnimation(.easeOut(duration: 0.2)) { self.thumbnails[index] = image }
                }
                index += 1
            }
        }
    }

    /// The displayed frame at `seconds`, at most `maxSide` pixels on its longest side.
    func frame(at seconds: Double, maxSide: CGFloat = 2048) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    // MARK: Keyboard

    /// Space plays / pauses, ← → step one frame, Esc stops playback before the editor closes.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              !(event.window?.firstResponder is NSText) // typing in a field
        else { return false }
        switch event.keyCode {
        case VideoKey.space:
            togglePlayback()
            return true
        case VideoKey.left:
            step(by: -1)
            return true
        case VideoKey.right:
            step(by: 1)
            return true
        case EditorCanvas.KeyCode.escape:
            pause()
            return false
        default:
            return false
        }
    }
}

/// Virtual key codes the video editors react to (besides `EditorCanvas.KeyCode`).
enum VideoKey {
    static let space: UInt16 = 49
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let b: UInt16 = 11
    static let i: UInt16 = 34
    static let o: UInt16 = 31
}

/// Time labels: `0:04.25`, `12:03.50`, `1:02:03.40`.
enum VideoTime {
    static func format(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded())
        let (h, m, s, cs) = (hundredths / 360_000, hundredths / 6000 % 60, hundredths / 100 % 60, hundredths % 100)
        let tail = String(format: "%02d.%02d", s, cs)
        return h > 0 ? String(format: "%d:%02d:", h, m) + tail : "\(m):" + tail
    }
}
