import CoreImage
import SwiftUI
import Vision

/// "Redact Video": draw boxes over a paused frame; they are blurred, pixelated or blacked
/// out for the whole clip, previewed live, and saved as `<name> Redacted.<ext>`.
enum VideoRedactEditor {
    private static let reservedHeight: CGFloat = 340

    @MainActor static func present(for item: FileItem) {
        VideoClip.open(item) { clip in
            let stage = VideoEditorLayout.stageSize(for: clip.pixelSize, reservedHeight: reservedHeight)
            EditorWindowController.present(width: VideoEditorLayout.cardWidth) { close in
                VideoRedactView(clip: clip, stageSize: stage, close: close)
            }
        }
    }
}

struct VideoRedactView: View {
    @ObservedObject var clip: VideoClip
    let stageSize: CGSize
    let close: () -> Void

    @StateObject private var model: VideoRedactModel

    init(clip: VideoClip, stageSize: CGSize, close: @escaping () -> Void) {
        self.clip = clip
        self.stageSize = stageSize
        self.close = close
        _model = StateObject(wrappedValue: VideoRedactModel(clip: clip, size: stageSize))
    }

    var body: some View {
        EditorShell(title: "Redact Video", onClose: dismiss) {
            VStack(spacing: 14) {
                VideoStage(clip: clip, size: stageSize) {
                    VideoRedactOverlay(model: model, clip: clip)
                }

                HStack(spacing: 10) {
                    VideoPlayButton(clip: clip)
                    VideoTimeline(clip: clip)
                }

                HStack {
                    EditorSectionLabel(title: "Style")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: VideoRedactModel.styles, selection: $model.style, label: \.title)
                        .frame(width: 252)
                }

                detectButton
            }
        } footer: {
            KlickSecondaryButton(title: "Reset", action: model.reset)
                .disabled(model.boxes.isEmpty)
            Spacer()
            KlickPrimaryButton(title: "Save", isEnabled: !model.boxes.isEmpty, action: save)
        }
        .background(EditorCanvas.KeyInterceptor { model.handleKey($0) || clip.handleKey($0) })
        .task { await model.attach() }
    }

    private var detectButton: some View {
        Button(action: model.detectFaces) {
            HStack(spacing: 7) {
                ZStack {
                    if model.detecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "person.crop.square")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 16, height: 16)
                Text("Detect Faces in This Frame")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(model.detecting)
        .animation(Theme.springSnappy, value: model.detecting)
    }

    private func dismiss() {
        clip.shutdown()
        close()
    }

    private func save() {
        guard !model.boxes.isEmpty else { return }
        let item = clip.item
        let regions = model.boxes.map(\.rect)
        let style = model.style
        dismiss()
        VideoJob.start("Redacting video", item: item) { progress in
            [try await VideoTools.redact(item, regions: regions, style: style, progress: progress)]
        }
    }
}

// MARK: - Model

/// Boxes (normalized, top-left origin), selection and face detection of the Redact Video
/// editor. The player renders through the same redaction as the export, so playback shows
/// exactly what will be saved. A paused player won't redraw its frame when the boxes change,
/// so edits are previewed on a still of that frame, rendered by the same Core Image code.
@MainActor
final class VideoRedactModel: ObservableObject {
    struct Notice: Hashable {
        let symbol: String
        let text: String
    }

    static let styles: [RedactStyle] = [.blur, .pixelate, .black]
    static let badgeRadius: CGFloat = 10

    @Published var style: RedactStyle = .blur {
        didSet { push() }
    }
    @Published private(set) var boxes: [RedactBox] = [] {
        didSet { push() }
    }
    @Published private(set) var selection: RedactBox.ID?
    @Published private(set) var detecting = false
    @Published private(set) var notice: Notice?
    @Published private(set) var isMoving = false
    /// The paused frame with the current boxes, and the playhead time it shows.
    @Published private(set) var still: (time: Double, image: CGImage)?

    let clip: VideoClip
    /// Stage size in points.
    let size: CGSize
    private let redaction = VideoRedaction()
    /// The untouched frame under the playhead, decoded once per position.
    private var source: (time: Double, image: CIImage)?
    private var renderTask: Task<Void, Never>?
    private var needsRender = false

    nonisolated private static let context = CIContext(options: [.cacheIntermediates: false])

    private enum Drag {
        case none
        case drawing(RedactBox.ID, origin: CGPoint)
        case moving(RedactBox.ID, from: CGRect, grab: CGPoint)
    }

    private var drag = Drag.none
    private var noticeTask: Task<Void, Never>?

    init(clip: VideoClip, size: CGSize) {
        self.clip = clip
        self.size = size
    }

    var selectedBox: RedactBox? { boxes.first { $0.id == selection } }

    /// Routes the player through the redaction, so playback and seeks show it.
    func attach() async {
        guard let composition = try? await VideoComposer.redacting(clip.asset, with: redaction) else { return }
        clip.player.currentItem?.videoComposition = composition
    }

    /// The still to show over the player: only while paused on the frame it was rendered for.
    var visibleStill: CGImage? {
        guard let still, !clip.isPlaying, abs(still.time - clip.time) < 0.0001 else { return nil }
        return still.image
    }

    private func push() {
        redaction.update(regions: boxes.map(\.rect).filter { $0.width > 0 && $0.height > 0 }, style: style)
        renderStill()
    }

    /// Re-renders the still for the playhead's frame. While a render runs only the latest
    /// state is kept, so dragging a box stays fluid.
    private func renderStill() {
        guard !clip.isPlaying else { return }
        needsRender = true
        guard renderTask == nil else { return }
        renderTask = Task { [weak self] in
            while let self, self.needsRender {
                self.needsRender = false
                let time = self.clip.time
                if self.source?.time != time {
                    let side = max(self.clip.pixelSize.width, self.clip.pixelSize.height)
                    guard let frame = try? await self.clip.frame(at: time, maxSide: side) else { break }
                    self.source = (time, CIImage(cgImage: frame))
                }
                guard let source = self.source?.image else { break }
                let (regions, style) = self.redaction.snapshot
                // Effects are applied at full resolution (their strength depends on it), then scaled to the stage.
                let scale = 2 * self.size.width / source.extent.width
                let image = await Task.detached(priority: .userInitiated) {
                    let output = VideoComposer.redact(source, regions: regions, style: style)
                        .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    return Self.context.createCGImage(output, from: output.extent.integral)
                }.value
                if let image, time == self.clip.time { self.still = (time, image) }
            }
            self?.renderTask = nil
        }
    }

    // MARK: Editing

    func delete(_ id: RedactBox.ID) {
        withAnimation(Theme.springSnappy) {
            boxes.removeAll { $0.id == id }
            if selection == id { selection = nil }
        }
        Feedback.shared.tick()
    }

    func reset() {
        guard !boxes.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            boxes.removeAll()
            selection = nil
        }
        Feedback.shared.tick()
    }

    private func update(_ id: RedactBox.ID, _ change: (inout RedactBox) -> Void) {
        guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
        change(&boxes[index])
    }

    // MARK: Geometry

    func viewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    /// Badge position in stage points: the box's top-right corner, kept inside the stage.
    func badgeCenter(for box: RedactBox) -> CGPoint {
        let frame = viewRect(box.rect)
        let inset = Self.badgeRadius + 3
        return CGPoint(x: min(max(frame.maxX, inset), size.width - inset),
                       y: min(max(frame.minY, inset), size.height - inset))
    }

    private func badgeContains(_ location: CGPoint) -> Bool {
        guard let box = selectedBox else { return false }
        let center = badgeCenter(for: box)
        return hypot(location.x - center.x, location.y - center.y) <= Self.badgeRadius + 3
    }

    private func box(at location: CGPoint) -> RedactBox? {
        boxes.last { viewRect($0.rect).insetBy(dx: -2, dy: -2).contains(location) }
    }

    // MARK: Pointer

    func pointerDown(at location: CGPoint) {
        clip.pause()
        if let box = selectedBox, badgeContains(location) {
            delete(box.id)
            drag = .none
            return
        }
        let point = normalized(location)
        if let hit = box(at: location) {
            if selection != hit.id {
                withAnimation(Theme.springSnappy) { selection = hit.id }
                Feedback.shared.tick()
            }
            drag = .moving(hit.id, from: hit.rect, grab: point)
            return
        }
        if selection != nil {
            withAnimation(Theme.springSnappy) { selection = nil }
        }
        let box = RedactBox(rect: CGRect(origin: point, size: .zero))
        boxes.append(box)
        drag = .drawing(box.id, origin: point)
    }

    func pointerDragged(to location: CGPoint) {
        let point = normalized(location)
        switch drag {
        case .drawing(let id, let origin):
            update(id) {
                $0.rect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y),
                                 width: abs(point.x - origin.x), height: abs(point.y - origin.y))
            }
        case .moving(let id, let start, let grab):
            isMoving = true
            var rect = start.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
            rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
            rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
            update(id) { $0.rect = rect }
        case .none:
            break
        }
    }

    func pointerUp(at location: CGPoint) {
        pointerDragged(to: location)
        if case .drawing(let id, _) = drag, let box = boxes.first(where: { $0.id == id }) {
            let frame = viewRect(box.rect)
            if frame.width < 4 || frame.height < 4 {
                boxes.removeAll { $0.id == id }
            } else {
                Feedback.shared.tick()
            }
        }
        drag = .none
        isMoving = false
    }

    func cursor(at location: CGPoint) -> NSCursor {
        if isMoving { return .closedHand }
        if badgeContains(location) { return .pointingHand }
        return box(at: location) == nil ? .crosshair : .openHand
    }

    /// Delete / Backspace removes the selected box and Esc deselects it; with no
    /// selection the keys keep their usual meaning (Esc closes the editor).
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let id = selection, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        case EditorCanvas.KeyCode.delete, EditorCanvas.KeyCode.forwardDelete:
            delete(id)
            return true
        case EditorCanvas.KeyCode.escape:
            withAnimation(Theme.springSnappy) { selection = nil }
            return true
        default:
            return false
        }
    }

    // MARK: Faces

    /// Looks for faces in the frame under the playhead and pops a box onto each.
    func detectFaces() {
        guard !detecting else { return }
        detecting = true
        clip.pause()
        let time = clip.time
        Task {
            var found: [CGRect]?
            if let frame = try? await clip.frame(at: time, maxSide: 3072) {
                found = await Task.detached(priority: .userInitiated) { try? Self.faces(in: frame) }.value
            }
            switch found {
            case nil:
                Feedback.shared.failure()
                show(Notice(symbol: "exclamationmark.triangle.fill", text: "Couldn't analyze the frame"))
            case let rects? where rects.isEmpty:
                Feedback.shared.failure()
                show(Notice(symbol: "magnifyingglass", text: "No faces found in this frame"))
            case let rects?:
                let fresh = rects.filter { rect in !boxes.contains { $0.rect.coverage(of: rect) > 0.8 } }
                guard !fresh.isEmpty else {
                    show(Notice(symbol: "checkmark.circle.fill", text: "Already covered"))
                    break
                }
                show(Notice(symbol: "checkmark.circle.fill", text: fresh.count == 1 ? "Covered 1 face" : "Covered \(fresh.count) faces"))
                for (index, rect) in fresh.enumerated() {
                    boxes.append(RedactBox(rect: rect, popsIn: true))
                    if index < 8 { Feedback.shared.tick() }
                    try? await Task.sleep(for: .milliseconds(45))
                }
            }
            detecting = false
        }
    }

    /// Face boxes, normalized with a top-left origin, grown to take in forehead and hair.
    nonisolated private static func faces(in image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return (request.results ?? []).map { observation in
            let box = observation.boundingBox // bottom-left origin
            let face = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            return CGRect(x: face.minX - face.width * 0.15, y: face.minY - face.height * 0.35,
                          width: face.width * 1.3, height: face.height * 1.47).intersection(unit)
        }
        .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }

    private func show(_ notice: Notice) {
        noticeTask?.cancel()
        withAnimation(Theme.springSoft) { self.notice = notice }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.notice = nil }
        }
    }
}

private extension CGRect {
    /// Fraction of `other`'s area that lies inside this rectangle.
    func coverage(of other: CGRect) -> CGFloat {
        let overlap = intersection(other)
        guard !overlap.isNull, other.width > 0, other.height > 0 else { return 0 }
        return overlap.width * overlap.height / (other.width * other.height)
    }
}

// MARK: - Overlay

/// Box outlines, the selection chrome, hints and the mouse surface, over the live video.
private struct VideoRedactOverlay: View {
    @ObservedObject var model: VideoRedactModel
    /// Observed for the playhead, which decides whether the still is shown.
    @ObservedObject var clip: VideoClip

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let still = model.visibleStill {
                Image(decorative: still, scale: 2)
                    .resizable()
                    .frame(width: model.size.width, height: model.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
            }

            ForEach(model.boxes) { box in
                VideoRedactBoxOutline(popsIn: box.popsIn, frame: model.viewRect(box.rect))
            }

            if let box = model.selectedBox {
                let frame = model.viewRect(box.rect)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .shadow(color: Theme.accent.opacity(0.45), radius: 5)
                        .frame(width: frame.width + 6, height: frame.height + 6)
                        .position(x: frame.midX, y: frame.midY)

                    Image(systemName: "xmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: VideoRedactModel.badgeRadius * 2, height: VideoRedactModel.badgeRadius * 2)
                        .background(Circle().fill(Theme.accentGradient))
                        .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .position(model.badgeCenter(for: box))
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            Group {
                if let notice = model.notice {
                    EditorCanvas.Hint(symbol: notice.symbol, text: notice.text)
                        .id(notice)
                } else if model.boxes.isEmpty {
                    EditorCanvas.Hint(symbol: "hand.draw", text: "Drag over anything you want to hide")
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))

            EditorCanvas.MouseInput(
                onDown: model.pointerDown(at:),
                onDrag: model.pointerDragged(to:),
                onUp: model.pointerUp(at:),
                cursor: model.cursor(at:)
            )
        }
        .frame(width: model.size.width, height: model.size.height)
        .animation(Theme.springSoft, value: model.notice)
        .animation(Theme.springSoft, value: model.boxes.isEmpty)
    }
}

/// Two-tone hairline around a redaction, so it stays findable over any picture
/// (the effect itself is rendered into the video).
private struct VideoRedactBoxOutline: View {
    let frame: CGRect
    @State private var shown: Bool

    init(popsIn: Bool, frame: CGRect) {
        self.frame = frame
        _shown = State(initialValue: !popsIn)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: min(4, min(frame.width, frame.height) * 0.25), style: .continuous)
        ZStack {
            shape.inset(by: 0.5).strokeBorder(Color.white.opacity(0.55), lineWidth: 0.75)
            shape.strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5)
        }
        .frame(width: frame.width, height: frame.height)
        .scaleEffect(shown ? 1 : 0.3)
        .opacity(shown ? 1 : 0)
        .position(x: frame.midX, y: frame.midY)
        .allowsHitTesting(false)
        .onAppear {
            guard !shown else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { shown = true }
        }
    }
}
