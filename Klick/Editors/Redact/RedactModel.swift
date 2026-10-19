import AppKit
import SwiftUI

enum RedactStyle: String, CaseIterable, Identifiable {
    case black, blur, pixelate

    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// What the Vision buttons look for.
enum RedactTarget {
    case text, faces

    var title: String { self == .text ? "Detect Text" : "Detect Faces" }
    var symbol: String { self == .text ? "text.viewfinder" : "person.crop.square" }
    var notFound: String { self == .text ? "No text found" : "No faces found" }

    func found(_ count: Int) -> String {
        switch self {
        case .text: count == 1 ? "Covered 1 line of text" : "Covered \(count) lines of text"
        case .faces: count == 1 ? "Covered 1 face" : "Covered \(count) faces"
        }
    }
}

/// One area to hide, in image pixels (top-left origin).
struct RedactBox: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect
    /// Detected boxes pop in; drawn ones are already on screen while being dragged out.
    var popsIn = false
}

/// State of the Redact editor: the boxes, the selection, the style previews and
/// the Vision detections.
@MainActor
final class RedactModel: ObservableObject {
    struct Notice: Hashable {
        let symbol: String
        let text: String
    }

    @Published var style: RedactStyle = .black
    @Published private(set) var boxes: [RedactBox] = []
    @Published private(set) var selection: RedactBox.ID?
    @Published private(set) var preview: CGImage?
    /// The whole preview with each style applied; boxes show their slice of it.
    @Published private(set) var effects: [RedactStyle: CGImage] = [:]
    @Published private(set) var detecting: RedactTarget?
    @Published private(set) var notice: Notice?
    @Published private(set) var isMoving = false

    let item: FileItem
    let layout: EditorCanvas.Layout

    static let badgeRadius: CGFloat = 10

    private enum Drag {
        case none
        case drawing(RedactBox.ID, origin: CGPoint)
        case moving(RedactBox.ID, from: CGRect, grab: CGPoint)
    }

    private var drag = Drag.none
    private var noticeTask: Task<Void, Never>?

    init(item: FileItem, layout: EditorCanvas.Layout) {
        self.item = item
        self.layout = layout
    }

    var selectedBox: RedactBox? { boxes.first { $0.id == selection } }

    /// Decodes the preview, then renders the Blur and Pixelate looks once.
    func load() async {
        guard let image = await layout.loadPreview(of: item.url) else { return }
        preview = image
        effects = await Task.detached(priority: .userInitiated) {
            var effects: [RedactStyle: CGImage] = [:]
            for style in [RedactStyle.blur, .pixelate] {
                effects[style] = RedactRenderer.previewEffect(style, for: image)
            }
            return effects
        }.value
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

    // MARK: Pointer

    /// Badge position in canvas points: the box's top-right corner, kept inside the canvas.
    func badgeCenter(for box: RedactBox) -> CGPoint {
        let frame = layout.viewRect(box.rect)
        let inset = Self.badgeRadius + 3
        return CGPoint(
            x: min(max(frame.maxX, inset), layout.size.width - inset),
            y: min(max(frame.minY, inset), layout.size.height - inset)
        )
    }

    private func badgeContains(_ location: CGPoint) -> Bool {
        guard let box = selectedBox else { return false }
        let center = badgeCenter(for: box)
        return hypot(location.x - center.x, location.y - center.y) <= Self.badgeRadius + 3
    }

    private func box(at location: CGPoint) -> RedactBox? {
        boxes.last { layout.viewRect($0.rect).insetBy(dx: -2, dy: -2).contains(location) }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), layout.pixelSize.width), y: min(max(point.y, 0), layout.pixelSize.height))
    }

    func pointerDown(at location: CGPoint) {
        if let box = selectedBox, badgeContains(location) {
            delete(box.id)
            drag = .none
            return
        }
        let point = layout.imagePoint(location)
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
        let origin = clamped(point)
        let box = RedactBox(rect: CGRect(origin: origin, size: .zero))
        boxes.append(box)
        drag = .drawing(box.id, origin: origin)
    }

    func pointerDragged(to location: CGPoint) {
        let point = layout.imagePoint(location)
        switch drag {
        case .drawing(let id, let origin):
            let corner = clamped(point)
            update(id) {
                $0.rect = CGRect(x: min(origin.x, corner.x), y: min(origin.y, corner.y),
                                 width: abs(corner.x - origin.x), height: abs(corner.y - origin.y))
            }
        case .moving(let id, let start, let grab):
            isMoving = true
            var rect = start.offsetBy(dx: point.x - grab.x, dy: point.y - grab.y)
            rect.origin.x = min(max(rect.minX, 0), layout.pixelSize.width - rect.width)
            rect.origin.y = min(max(rect.minY, 0), layout.pixelSize.height - rect.height)
            update(id) { $0.rect = rect }
        case .none:
            break
        }
    }

    func pointerUp(at location: CGPoint) {
        pointerDragged(to: location)
        if case .drawing(let id, _) = drag, let box = boxes.first(where: { $0.id == id }) {
            let minimum = 4 / layout.scale
            if box.rect.width < minimum || box.rect.height < minimum {
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

    // MARK: Detection

    /// Runs Vision and pops a box onto every hit, one after another.
    func detect(_ target: RedactTarget) {
        guard detecting == nil else { return }
        detecting = target
        let url = item.url
        let pixelSize = layout.pixelSize
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try RedactDetector.detect(target, in: url, pixelSize: pixelSize) }
            }.value

            switch result {
            case .failure:
                Feedback.shared.failure()
                show(Notice(symbol: "exclamationmark.triangle.fill", text: "Couldn't analyze the image"))
            case .success(let rects) where rects.isEmpty:
                Feedback.shared.failure()
                show(Notice(symbol: "magnifyingglass", text: target.notFound))
            case .success(let rects):
                let fresh = rects.filter { rect in !boxes.contains { $0.rect.coverage(of: rect) > 0.8 } }
                guard !fresh.isEmpty else {
                    show(Notice(symbol: "checkmark.circle.fill", text: "Already covered"))
                    break
                }
                show(Notice(symbol: "checkmark.circle.fill", text: target.found(fresh.count)))
                for (index, rect) in fresh.enumerated() {
                    boxes.append(RedactBox(rect: rect, popsIn: true))
                    if index < 8 { Feedback.shared.tick() }
                    try? await Task.sleep(for: .milliseconds(index < 12 ? 45 : 12))
                }
            }
            detecting = nil
        }
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
