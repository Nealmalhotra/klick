import SwiftUI

/// "Trim Audio" card: drag the start and end handles over the waveform, preview the
/// selection, then Save `<name> Trimmed.<ext>` next to the original.
enum AudioTrimEditor {
    @MainActor static func present(for item: FileItem) {
        EditorWindowController.present(width: AudioEditorKit.cardWidth) { close in
            AudioTrimView(item: item, close: close)
        }
    }
}

@MainActor
final class AudioTrimModel: ObservableObject {
    let item: FileItem
    let player: AudioPreviewPlayer

    @Published private(set) var waveform: AudioWaveform?
    /// Selection, in seconds.
    @Published var start = 0.0
    @Published var end = 0.0
    @Published private(set) var isSaving = false

    init(item: FileItem) {
        self.item = item
        player = AudioPreviewPlayer(url: item.url)
    }

    var duration: Double { waveform?.duration ?? 0 }
    var length: Double { end - start }
    /// Shortest selection the handles allow.
    var minLength: Double { min(0.1, duration) }
    var isTrimmed: Bool { start > 0.01 || end < duration - 0.01 }

    func load(width: CGFloat, close: @escaping () -> Void) async {
        guard waveform == nil else { return }
        guard let waveform = await AudioEditorKit.loadWaveform(item, width: width) else { return close() }
        self.waveform = waveform
        end = waveform.duration
    }

    func setStart(_ value: Double) {
        start = min(max(value, 0), end - minLength)
        if player.isPlaying { player.stop() }
        player.position = start
    }

    func setEnd(_ value: Double) {
        end = max(min(value, duration), start + minLength)
        if player.isPlaying { player.stop() }
        if player.position > end { player.position = start }
    }

    /// Plays the selection from the playhead (or from the start once it has reached the end).
    func togglePlay() {
        guard waveform != nil else { return }
        if player.isPlaying { return player.stop() }
        let from = (start..<end - 0.05).contains(player.position) ? player.position : start
        player.play(from: from, to: end)
    }

    /// Moves the playhead; keeps playing from there when already playing.
    func seek(to time: Double) {
        let time = min(max(time, start), end)
        if player.isPlaying { player.play(from: time, to: end) } else { player.position = time }
    }

    func reset() {
        player.stop()
        withAnimation(Theme.springSoft) {
            start = 0
            end = duration
        }
        player.position = 0
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49 else { return false } // Space
        togglePlay()
        return true
    }

    func save(close: @escaping () -> Void) {
        guard isTrimmed, !isSaving else { return }
        player.stop()
        isSaving = true
        let item = item
        let range = start...end
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await AudioTools.trim(item, range: range, progress: JobProgress())
                }.value
                Feedback.shared.success()
                player.shutdown()
                close()
                Toast.shared.showMessage("Saved")
            } catch {
                isSaving = false
                Feedback.shared.failure()
                Toast.shared.showMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }
}

struct AudioTrimView: View {
    let close: () -> Void
    @StateObject private var model: AudioTrimModel

    init(item: FileItem, close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: AudioTrimModel(item: item))
    }

    var body: some View {
        EditorShell(title: "Trim Audio", onClose: closeEditor) {
            VStack(spacing: 14) {
                WaveformWell(isLoaded: model.waveform != nil) {
                    TrimTimeline(model: model, player: model.player)
                }
                TrimTransport(model: model, player: model.player)
            }
        } footer: {
            KlickSecondaryButton(title: "Reset", action: model.reset)
                .disabled(!model.isTrimmed || model.isSaving)
            Spacer()
            if model.waveform != nil {
                Text("\(AudioEditorKit.clock(model.length)) selected")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            KlickPrimaryButton(title: "Save", isBusy: model.isSaving, isEnabled: model.isTrimmed) {
                model.save(close: closeEditor)
            }
        }
        .background(EditorCanvas.KeyInterceptor(handler: model.handleKey))
        .task { await model.load(width: TrimTimeline.waveformWidth, close: close) }
        .onDisappear { model.player.shutdown() }
    }

    private func closeEditor() {
        model.player.shutdown()
        close()
    }
}

/// Start / play / end row under the waveform.
private struct TrimTransport: View {
    @ObservedObject var model: AudioTrimModel
    @ObservedObject var player: AudioPreviewPlayer

    var body: some View {
        HStack {
            TimeCaption(title: "Start", seconds: model.start)
            Spacer()
            PlayPauseButton(isPlaying: player.isPlaying, action: model.togglePlay)
                .disabled(model.waveform == nil)
            Spacer()
            TimeCaption(title: "End", seconds: model.end, alignment: .trailing)
        }
    }
}

/// Waveform with the accent selection frame and its two handles.
private struct TrimTimeline: View {
    @ObservedObject var model: AudioTrimModel
    @ObservedObject var player: AudioPreviewPlayer

    /// Inset that leaves room for the handles at both ends.
    static let inset: CGFloat = 14
    static let waveformWidth = AudioEditorKit.cardWidth - 36 - inset * 2

    private enum Edge { case start, end }
    private let handleWidth: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - Self.inset * 2
            let height = geo.size.height
            let x0 = x(for: model.start, width: width)
            let x1 = x(for: model.end, width: width)

            ZStack(alignment: .topLeading) {
                WaveformBars(peaks: model.waveform?.peaks ?? [], highlight: [fraction(model.start)...fraction(model.end)])
                    .padding(.vertical, 12)
                    .frame(width: width, height: height)
                    .offset(x: Self.inset)

                // Seek by clicking anywhere on the waveform.
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        model.seek(to: time(at: value.location.x, width: width))
                    })

                // Selection frame.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2.5)
                    .frame(width: max(x1 - x0 + handleWidth, handleWidth * 2), height: height - 6)
                    .offset(x: x0 - handleWidth / 2, y: 3)
                    .allowsHitTesting(false)

                if player.isPlaying || player.position > model.start + 0.01 {
                    Playhead()
                        .frame(height: height - 14)
                        .offset(x: x(for: player.position, width: width) - 3.5, y: 7)
                }

                handle(.start, width: width).offset(x: x0 - handleWidth / 2 - 9, y: 0)
                handle(.end, width: width).offset(x: x1 - handleWidth / 2 - 9, y: 0)
            }
            .coordinateSpace(name: Self.space)
        }
    }

    private func handle(_ edge: Edge, width: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return shape
            .fill(Theme.accentGradient)
            .overlay(Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 20))
            .overlay(shape.strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .frame(width: handleWidth, height: AudioEditorKit.waveformHeight - 6)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .padding(.horizontal, 9) // wider hit area
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(TrimTimeline.space))
                    .onChanged { value in
                        let t = time(at: value.location.x, width: width)
                        edge == .start ? model.setStart(t) : model.setEnd(t)
                    }
                    .onEnded { _ in Feedback.shared.tick() }
            )
    }

    static let space = "trim-timeline"

    private func fraction(_ time: Double) -> Double {
        model.duration > 0 ? time / model.duration : 0
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        Self.inset + CGFloat(fraction(time)) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        Double((x - Self.inset) / max(width, 1)) * model.duration
    }
}
