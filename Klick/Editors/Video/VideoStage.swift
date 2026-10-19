import AVFoundation
import SwiftUI

/// Sizes shared by the video editor cards.
enum VideoEditorLayout {
    static let cardWidth: CGFloat = 520
    static let contentWidth: CGFloat = cardWidth - 36
    /// Tallest the video gets, so portrait clips leave room for the controls.
    static let maxStageHeight: CGFloat = 420

    /// Aspect-fit size of the video inside `width` × the tallest stage the screen allows.
    /// - Parameter reservedHeight: card height taken by everything except the video.
    @MainActor
    static func stageSize(for pixelSize: CGSize, width: CGFloat = contentWidth, reservedHeight: CGFloat) -> CGSize {
        let anchor = EditorWindowController.anchorOverride ?? NSEvent.mouseLocation
        let screenHeight = NSScreen.containing(anchor)?.visibleFrame.height ?? 800
        let maxHeight = min(maxStageHeight, max(160, screenHeight * 0.85 - reservedHeight))
        let scale = min(width / max(pixelSize.width, 1), maxHeight / max(pixelSize.height, 1))
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }
}

/// The video itself, in a rounded frame like the image editors' canvases.
struct VideoStage<Overlay: View>: View {
    @ObservedObject var clip: VideoClip
    let size: CGSize
    @ViewBuilder var overlay: Overlay

    var body: some View {
        ZStack(alignment: .topLeading) {
            VideoPlayerSurface(player: clip.player)
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            overlay
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity)
    }
}

extension VideoStage where Overlay == EmptyView {
    init(clip: VideoClip, size: CGSize) {
        self.init(clip: clip, size: size) { EmptyView() }
    }
}

/// `AVPlayerLayer` host. The layer is the view's backing layer, so it always fills the view.
struct VideoPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerView { PlayerView(player: player) }

    func updateNSView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()

        init(player: AVPlayer) {
            super.init(frame: .zero)
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func makeBackingLayer() -> CALayer { playerLayer }
    }
}

/// Round glass play / pause button next to the timeline.
struct VideoPlayButton: View {
    @ObservedObject var clip: VideoClip
    @State private var hovering = false

    var body: some View {
        Button(action: clip.togglePlayback) {
            Image(systemName: clip.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .scaleEffect(hovering ? 1.05 : 1)
        .animation(Theme.springSnappy, value: hovering)
        .onHover { hovering = $0 }
        .help(clip.isPlaying ? "Pause (Space)" : "Play (Space)")
    }
}

/// A caption over a monospaced value ("Start / 0:01.20"), used under the timeline.
struct VideoReadout: View {
    let title: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
    }
}
