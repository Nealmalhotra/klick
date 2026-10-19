import SwiftUI

/// "Trim Video": drag the handles of the filmstrip to keep a part of the clip, preview it,
/// then Save `<name> Trimmed.<ext>` (streams copied, no quality loss).
enum VideoTrimEditor {
    /// Card height used by everything but the video: title bar, timeline, readouts, footer.
    private static let reservedHeight: CGFloat = 290

    @MainActor static func present(for item: FileItem) {
        VideoClip.open(item) { clip in
            let stage = VideoEditorLayout.stageSize(for: clip.pixelSize, reservedHeight: reservedHeight)
            EditorWindowController.present(width: VideoEditorLayout.cardWidth) { close in
                VideoTrimView(clip: clip, stageSize: stage, close: close)
            }
        }
    }
}

struct VideoTrimView: View {
    @ObservedObject var clip: VideoClip
    let stageSize: CGSize
    let close: () -> Void

    @State private var range: ClosedRange<Double>

    init(clip: VideoClip, stageSize: CGSize, close: @escaping () -> Void) {
        self.clip = clip
        self.stageSize = stageSize
        self.close = close
        _range = State(initialValue: 0...clip.duration)
    }

    private var isWholeClip: Bool {
        range.lowerBound < 0.01 && range.upperBound > clip.duration - 0.01
    }

    var body: some View {
        EditorShell(title: "Trim Video", onClose: dismiss) {
            VStack(spacing: 14) {
                VideoStage(clip: clip, size: stageSize)

                HStack(spacing: 10) {
                    VideoPlayButton(clip: clip)
                    VideoTimeline(clip: clip, trim: $range)
                }

                HStack {
                    VideoReadout(title: "Start", value: VideoTime.format(range.lowerBound))
                    Spacer()
                    VideoReadout(title: "Length", value: VideoTime.format(range.upperBound - range.lowerBound), alignment: .center)
                    Spacer()
                    VideoReadout(title: "End", value: VideoTime.format(range.upperBound), alignment: .trailing)
                }
                .padding(.leading, 48)
            }
        } footer: {
            KlickSecondaryButton(title: "Reset") {
                withAnimation(Theme.springSoft) { range = 0...clip.duration }
                Feedback.shared.tick()
            }
            .disabled(isWholeClip)
            Spacer()
            KlickPrimaryButton(title: "Save", isEnabled: !isWholeClip, action: save)
        }
        .background(EditorCanvas.KeyInterceptor(handler: handleKey))
        .onAppear { clip.playbackRange = range }
        .onChange(of: range) { _, newRange in clip.playbackRange = newRange }
    }

    /// I / O set the start / end at the playhead, like most video editors.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            let minimum = max(0.1, clip.info.frameDuration.seconds)
            switch event.keyCode {
            case VideoKey.i where clip.time < range.upperBound - minimum:
                withAnimation(Theme.springSnappy) { range = clip.time...range.upperBound }
                Feedback.shared.tick()
                return true
            case VideoKey.o where clip.time > range.lowerBound + minimum:
                withAnimation(Theme.springSnappy) { range = range.lowerBound...clip.time }
                Feedback.shared.tick()
                return true
            default:
                break
            }
        }
        return clip.handleKey(event)
    }

    private func dismiss() {
        clip.shutdown()
        close()
    }

    private func save() {
        guard !isWholeClip else { return }
        let item = clip.item
        let range = range
        dismiss()
        VideoJob.start("Trimming video", item: item) { progress in
            [try await VideoTools.trim(item, to: range, progress: progress)]
        }
    }
}
