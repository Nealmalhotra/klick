import SwiftUI

/// "Bleep" card: drag across the waveform to mark words, preview them bleeped, then
/// Save `<name> Bleeped.<ext>` with every mark replaced by a 1 kHz tone (or silence).
enum BleepEditor {
    @MainActor static func present(for item: FileItem) {
        EditorWindowController.present(width: AudioEditorKit.cardWidth) { close in
            BleepView(item: item, close: close)
        }
    }
}

enum BleepMode: String, CaseIterable, Hashable {
    case bleep = "Bleep", silence = "Silence"
}

struct BleepMark: Identifiable, Equatable {
    let id = UUID()
    /// Seconds.
    var start: Double
    var end: Double
}

@MainActor
final class BleepModel: ObservableObject {
    let item: FileItem
    let player: AudioPreviewPlayer

    @Published private(set) var waveform: AudioWaveform?
    @Published private(set) var marks: [BleepMark] = [] {
        didSet { player.bleepRanges = marks.map { $0.start...$0.end } }
    }
    @Published var selection: BleepMark.ID?
    @Published var mode: BleepMode = .bleep {
        didSet { player.bleepSilence = mode == .silence }
    }
    @Published private(set) var isSaving = false

    private enum DragKind {
        case create(anchor: Double, id: BleepMark.ID)
        case resizeStart(BleepMark.ID)
        case resizeEnd(BleepMark.ID)
        case none
    }
    private var drag: DragKind = .none

    init(item: FileItem) {
        self.item = item
        player = AudioPreviewPlayer(url: item.url)
    }

    var duration: Double { waveform?.duration ?? 0 }

    func load(width: CGFloat, close: @escaping () -> Void) async {
        guard waveform == nil else { return }
        guard let waveform = await AudioEditorKit.loadWaveform(item, width: width) else { return close() }
        self.waveform = waveform
    }

    // MARK: Mouse (times in seconds; `tolerance` is how close counts as grabbing an edge)

    func mouseDown(at time: Double, tolerance: Double) {
        if let (mark, isStart) = edge(near: time, tolerance: tolerance) {
            selection = mark.id
            drag = isStart ? .resizeStart(mark.id) : .resizeEnd(mark.id)
        } else if let mark = marks.first(where: { ($0.start...$0.end).contains(time) }) {
            selection = mark.id
            drag = .none
        } else {
            let mark = BleepMark(start: time, end: time)
            marks.append(mark)
            selection = mark.id
            drag = .create(anchor: time, id: mark.id)
        }
    }

    func mouseDragged(to time: Double) {
        let time = min(max(time, 0), duration)
        switch drag {
        case .create(let anchor, let id):
            update(id) { $0.start = min(anchor, time); $0.end = max(anchor, time) }
        case .resizeStart(let id):
            update(id) { $0.start = min(time, $0.end - 0.02) }
        case .resizeEnd(let id):
            update(id) { $0.end = max(time, $0.start + 0.02) }
        case .none:
            break
        }
    }

    func mouseUp(at time: Double) {
        defer { drag = .none }
        if case .create(_, let id) = drag, let mark = marks.first(where: { $0.id == id }), mark.end - mark.start < 0.04 {
            // A click, not a drag: move the playhead instead of marking.
            marks.removeAll { $0.id == id }
            selection = nil
            seek(to: time)
            return
        }
        if case .none = drag { return }
        Feedback.shared.tick()
        mergeOverlaps()
    }

    func cursor(at time: Double, tolerance: Double) -> NSCursor {
        edge(near: time, tolerance: tolerance) != nil ? .resizeLeftRight : .iBeam
    }

    private func edge(near time: Double, tolerance: Double) -> (BleepMark, Bool)? {
        for mark in marks {
            if abs(mark.start - time) <= tolerance { return (mark, true) }
            if abs(mark.end - time) <= tolerance { return (mark, false) }
        }
        return nil
    }

    private func update(_ id: BleepMark.ID, _ change: (inout BleepMark) -> Void) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        change(&marks[index])
    }

    /// Joins marks that ended up overlapping, keeping them sorted.
    private func mergeOverlaps() {
        var merged: [BleepMark] = []
        for mark in marks.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, mark.start <= last.end {
                merged[merged.count - 1].end = max(last.end, mark.end)
                if selection == mark.id { selection = last.id }
            } else {
                merged.append(mark)
            }
        }
        if merged != marks { marks = merged }
    }

    // MARK: Editing

    func remove(_ id: BleepMark.ID) {
        withAnimation(Theme.springSnappy) { marks.removeAll { $0.id == id } }
        if selection == id { selection = nil }
        Feedback.shared.tick()
    }

    func clear() {
        withAnimation(Theme.springSnappy) { marks.removeAll() }
        selection = nil
    }

    // MARK: Playback

    /// Plays the whole file from the playhead, with the marks bleeped.
    func togglePlay() {
        guard waveform != nil else { return }
        if player.isPlaying { return player.stop() }
        let from = player.position < duration - 0.05 ? player.position : 0
        player.play(from: from, to: duration)
    }

    func seek(to time: Double) {
        let time = min(max(time, 0), duration)
        if player.isPlaying { player.play(from: time, to: duration) } else { player.position = time }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 49: // Space
            togglePlay()
            return true
        case EditorCanvas.KeyCode.delete, EditorCanvas.KeyCode.forwardDelete:
            guard let selection else { return false }
            remove(selection)
            return true
        default:
            return false
        }
    }

    // MARK: Export

    func save(close: @escaping () -> Void) {
        guard !marks.isEmpty, !isSaving else { return }
        player.stop()
        isSaving = true
        let item = item
        let ranges = marks.map { $0.start...$0.end }
        let silence = mode == .silence
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await AudioTools.bleep(item, ranges: ranges, silence: silence, progress: JobProgress())
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

struct BleepView: View {
    let close: () -> Void
    @StateObject private var model: BleepModel

    init(item: FileItem, close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: BleepModel(item: item))
    }

    var body: some View {
        EditorShell(title: "Bleep", onClose: closeEditor) {
            VStack(spacing: 14) {
                WaveformWell(isLoaded: model.waveform != nil) {
                    BleepTimeline(model: model, player: model.player)
                }
                BleepControls(model: model, player: model.player)
            }
        } footer: {
            KlickSecondaryButton(title: "Clear", action: model.clear)
                .disabled(model.marks.isEmpty || model.isSaving)
            Spacer()
            KlickPrimaryButton(title: "Save", isBusy: model.isSaving, isEnabled: !model.marks.isEmpty) {
                model.save(close: closeEditor)
            }
        }
        .background(EditorCanvas.KeyInterceptor(handler: model.handleKey))
        .task { await model.load(width: BleepTimeline.waveformWidth, close: close) }
        .onDisappear { model.player.shutdown() }
    }

    private func closeEditor() {
        model.player.shutdown()
        close()
    }
}

private struct BleepControls: View {
    @ObservedObject var model: BleepModel
    @ObservedObject var player: AudioPreviewPlayer

    var body: some View {
        HStack(spacing: 12) {
            PlayPauseButton(isPlaying: player.isPlaying, action: model.togglePlay)
                .disabled(model.waveform == nil)
            TimeCaption(title: "Playhead", seconds: player.position)
                .frame(width: 64, alignment: .leading)
            Spacer()
            AccentSegmentedPicker(options: BleepMode.allCases, selection: $model.mode, label: \.rawValue)
                .frame(width: 176)
        }
    }
}

/// Waveform with the marked ranges; drag to add, drag an edge to resize, click to seek.
private struct BleepTimeline: View {
    @ObservedObject var model: BleepModel
    @ObservedObject var player: AudioPreviewPlayer

    static let inset: CGFloat = 10
    static let waveformWidth = AudioEditorKit.cardWidth - 36 - inset * 2

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - Self.inset * 2
            let height = geo.size.height

            ZStack(alignment: .topLeading) {
                WaveformBars(peaks: model.waveform?.peaks ?? [], highlight: model.marks.map { fraction($0.start)...fraction($0.end) })
                    .padding(.vertical, 12)
                    .frame(width: width, height: height)
                    .offset(x: Self.inset)

                EditorCanvas.MouseInput(
                    onDown: { model.mouseDown(at: time(at: $0.x, width: width), tolerance: tolerance(width)) },
                    onDrag: { model.mouseDragged(to: time(at: $0.x, width: width)) },
                    onUp: { model.mouseUp(at: time(at: $0.x, width: width)) },
                    cursor: { model.cursor(at: time(at: $0.x, width: width), tolerance: tolerance(width)) }
                )

                ForEach(model.marks) { mark in
                    let selected = model.selection == mark.id
                    let x0 = x(for: mark.start, width: width), x1 = x(for: mark.end, width: width)
                    let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                    shape
                        .fill(Theme.accent.opacity(selected ? 0.24 : 0.14))
                        .overlay(shape.strokeBorder(Theme.accent.opacity(selected ? 1 : 0.7), lineWidth: selected ? 2 : 1.5))
                        .frame(width: max(x1 - x0, 3), height: height - 8)
                        .offset(x: x0, y: 4)
                        .allowsHitTesting(false)

                    if selected, x1 - x0 > 0 {
                        Button { model.remove(mark.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Theme.accentGradient))
                                .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove (Delete)")
                        .offset(x: x1 - 8, y: -4)
                        .transition(.scale.combined(with: .opacity))
                    }
                }

                if player.isPlaying || player.position > 0.01 {
                    Playhead()
                        .frame(height: height - 14)
                        .offset(x: x(for: player.position, width: width) - 3.5, y: 7)
                }

                if model.marks.isEmpty, model.waveform != nil {
                    EditorCanvas.Hint(symbol: "hand.draw", text: "Drag across the words to bleep")
                        .transition(.opacity)
                }
            }
            .animation(Theme.springSnappy, value: model.selection)
            .animation(.easeOut(duration: 0.2), value: model.marks.isEmpty)
        }
    }

    /// Edge grab distance: 6 points, in seconds.
    private func tolerance(_ width: CGFloat) -> Double {
        Double(6 / max(width, 1)) * model.duration
    }

    private func fraction(_ time: Double) -> Double {
        model.duration > 0 ? time / model.duration : 0
    }

    private func x(for time: Double, width: CGFloat) -> CGFloat {
        Self.inset + CGFloat(fraction(time)) * width
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        min(max(Double((x - Self.inset) / max(width, 1)) * model.duration, 0), model.duration)
    }
}
