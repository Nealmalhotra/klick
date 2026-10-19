import SwiftUI

/// "Change Speed": pick 0.5× – 4×, preview it at that rate, then Save `<name> 2x.<ext>`
/// (re-encoded at the source frame rate, audio kept at its natural pitch).
enum VideoSpeedEditor {
    static let cardWidth: CGFloat = 440
    private static let reservedHeight: CGFloat = 320

    @MainActor static func present(for item: FileItem) {
        VideoClip.open(item) { clip in
            let stage = VideoEditorLayout.stageSize(for: clip.pixelSize, width: cardWidth - 36, reservedHeight: reservedHeight)
            EditorWindowController.present(width: cardWidth) { close in
                VideoSpeedView(clip: clip, stageSize: stage, close: close)
            }
        }
    }
}

struct VideoSpeedView: View {
    @ObservedObject var clip: VideoClip
    let stageSize: CGSize
    let close: () -> Void

    @State private var speed: Double = 2

    var body: some View {
        EditorShell(title: "Change Speed", onClose: dismiss) {
            VStack(spacing: 14) {
                VideoStage(clip: clip, size: stageSize) {
                    rateBadge
                }

                HStack(spacing: 10) {
                    VideoPlayButton(clip: clip)
                    VideoTimeline(clip: clip)
                }

                HStack {
                    EditorSectionLabel(title: "Speed")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: VideoTools.speeds, selection: $speed, label: Self.label)
                        .frame(width: 236)
                }

                HStack {
                    VideoReadout(title: "Duration", value: VideoTime.format(clip.duration))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.top, 12)
                    VideoReadout(title: "New duration", value: VideoTime.format(clip.duration / speed))
                    Spacer()
                    if clip.info.hasAudio {
                        Label("Pitch preserved", systemImage: "waveform")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                }
                .animation(Theme.springSnappy, value: speed)
            }
        } footer: {
            Spacer()
            KlickPrimaryButton(title: "Save", action: save)
        }
        .background(EditorCanvas.KeyInterceptor(handler: clip.handleKey))
        .onAppear { clip.rate = Float(speed) }
        .onChange(of: speed) { _, newSpeed in clip.rate = Float(newSpeed) }
    }

    /// The previewed rate, in the corner of the video.
    private var rateBadge: some View {
        Text(Self.label(speed))
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .contentTransition(.numericText())
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: Capsule())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .animation(Theme.springSnappy, value: speed)
            .allowsHitTesting(false)
    }

    static func label(_ speed: Double) -> String {
        VideoTools.speedLabel(speed).replacingOccurrences(of: "x", with: "×")
    }

    private func dismiss() {
        clip.shutdown()
        close()
    }

    private func save() {
        let item = clip.item
        let speed = speed
        dismiss()
        VideoJob.start("Changing speed to \(Self.label(speed))", item: item) { progress in
            [try await VideoTools.changeSpeed(item, by: speed, progress: progress)]
        }
    }
}
