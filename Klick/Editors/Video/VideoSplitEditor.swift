import SwiftUI

/// "Split Video": cut at markers placed on the timeline, or into equal parts, saving
/// `<name> Part 1.<ext>`, `<name> Part 2.<ext>`... (streams copied, no quality loss).
enum VideoSplitEditor {
    private static let reservedHeight: CGFloat = 340

    @MainActor static func present(for item: FileItem) {
        VideoClip.open(item) { clip in
            let stage = VideoEditorLayout.stageSize(for: clip.pixelSize, reservedHeight: reservedHeight)
            EditorWindowController.present(width: VideoEditorLayout.cardWidth) { close in
                VideoSplitView(clip: clip, stageSize: stage, close: close)
            }
        }
    }
}

private enum SplitMode: String, CaseIterable {
    case markers = "At Markers"
    case equal = "Equal Parts"
}

struct VideoSplitView: View {
    @ObservedObject var clip: VideoClip
    let stageSize: CGSize
    let close: () -> Void

    @State private var mode = SplitMode.markers
    @State private var markers: [VideoSplitMarker] = []
    @State private var selection: VideoSplitMarker.ID?
    @State private var parts = 2
    @State private var equalMarkers: [VideoSplitMarker] = []

    private static let partChoices = [2, 3, 4, 5, 6, 8, 10]

    private var shownMarkers: [VideoSplitMarker] { mode == .markers ? markers : equalMarkers }
    private var cutPoints: [Double] { shownMarkers.map(\.time).sorted() }
    private var minimumGap: Double { max(0.1, clip.info.frameDuration.seconds) }

    /// The playhead is somewhere a new cut makes sense: inside the clip, away from other cuts.
    private var canSplitHere: Bool {
        clip.time > minimumGap && clip.time < clip.duration - minimumGap
            && !markers.contains { abs($0.time - clip.time) < minimumGap }
    }

    var body: some View {
        EditorShell(title: "Split Video", onClose: dismiss) {
            VStack(spacing: 14) {
                VideoStage(clip: clip, size: stageSize)

                HStack(spacing: 10) {
                    VideoPlayButton(clip: clip)
                    VideoTimeline(
                        clip: clip,
                        markers: Binding(get: { shownMarkers }, set: { if mode == .markers { markers = $0 } }),
                        selectedMarker: $selection,
                        markersLocked: mode == .equal
                    )
                }

                HStack {
                    EditorSectionLabel(title: "Split")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: SplitMode.allCases, selection: $mode, label: \.rawValue)
                        .frame(width: 236)
                }

                ZStack {
                    if mode == .markers { markerControls } else { equalControls }
                }
                .frame(height: 34)
            }
            .animation(Theme.springSnappy, value: mode)
        } footer: {
            KlickSecondaryButton(title: "Reset") {
                withAnimation(Theme.springSnappy) {
                    markers.removeAll()
                    selection = nil
                }
                Feedback.shared.tick()
            }
            .disabled(mode != .markers || markers.isEmpty)
            Spacer()
            Text(cutPoints.isEmpty ? "" : "\(cutPoints.count + 1) parts")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .animation(Theme.springSnappy, value: cutPoints.count)
            KlickPrimaryButton(title: "Save", isEnabled: !cutPoints.isEmpty, action: save)
        }
        .background(EditorCanvas.KeyInterceptor(handler: handleKey))
        .onAppear { updateEqualMarkers() }
        .onChange(of: parts) { _, _ in updateEqualMarkers() }
        .onChange(of: mode) { _, _ in selection = nil }
    }

    private var markerControls: some View {
        HStack(spacing: 8) {
            Button(action: addMarker) {
                Label("Split at Playhead", systemImage: "scissors")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 2)
                    .frame(minHeight: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!canSplitHere)
            .help("Split at Playhead (B)")

            Button(action: removeSelected) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(minWidth: 18, minHeight: 22)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .disabled(selection == nil)
            .help("Remove Marker (Delete)")

            Spacer()
            if markers.isEmpty {
                Text("Move the playhead to where a part ends")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
    }

    private var equalControls: some View {
        HStack {
            EditorSectionLabel(title: "Parts")
            Spacer(minLength: 12)
            AccentSegmentedPicker(options: Self.partChoices, selection: $parts, label: { String($0) }, compact: true)
                .frame(width: 236)
        }
    }

    // MARK: Editing

    private func addMarker() {
        guard canSplitHere else { return }
        clip.pause()
        let marker = VideoSplitMarker(time: clip.time)
        withAnimation(Theme.springSnappy) {
            markers.append(marker)
            selection = marker.id
        }
        Feedback.shared.tick()
    }

    private func removeSelected() {
        guard let selection else { return }
        withAnimation(Theme.springSnappy) {
            markers.removeAll { $0.id == selection }
            self.selection = nil
        }
        Feedback.shared.tick()
    }

    private func updateEqualMarkers() {
        let length = clip.duration / Double(parts)
        withAnimation(Theme.springSnappy) {
            equalMarkers = (1..<parts).map { VideoSplitMarker(time: Double($0) * length) }
        }
    }

    /// B splits at the playhead, Delete removes the selected marker.
    private func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .keyDown, mode == .markers, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch event.keyCode {
            case VideoKey.b:
                addMarker()
                return true
            case EditorCanvas.KeyCode.delete where selection != nil, EditorCanvas.KeyCode.forwardDelete where selection != nil:
                removeSelected()
                return true
            case EditorCanvas.KeyCode.escape where selection != nil:
                withAnimation(Theme.springSnappy) { selection = nil }
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
        let points = cutPoints
        guard !points.isEmpty else { return }
        let item = clip.item
        dismiss()
        VideoJob.start("Splitting video", item: item) { progress in
            try await VideoTools.split(item, at: points, progress: progress)
        }
    }
}
