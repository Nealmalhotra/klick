import AppKit
import SwiftUI

enum AnnotateTool: String, CaseIterable, Identifiable {
    case pen, highlighter, arrow, rectangle, ellipse, text

    var id: Self { self }

    var symbol: String {
        switch self {
        case .pen: "scribble.variable"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        }
    }

    /// Hint shown on an empty canvas.
    var hint: String {
        switch self {
        case .pen: "Draw freely · hold ⇧ for a straight line"
        case .highlighter: "Drag over text to highlight · ⇧ keeps it straight"
        case .arrow: "Drag to point at something · ⇧ snaps the angle"
        case .rectangle: "Drag to frame an area · ⇧ for a square"
        case .ellipse: "Drag to circle an area · ⇧ for a circle"
        case .text: "Click anywhere to add a label"
        }
    }
}

/// Ink colors, defined in sRGB so the preview and the saved file match.
enum InkColor: String, CaseIterable, Identifiable {
    case accent, yellow, green, blue, purple, black, white

    var id: Self { self }

    var cgColor: CGColor {
        switch self {
        case .accent: Theme.accentNS.cgColor
        case .yellow: CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case .green: CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .blue: CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1)
        case .purple: CGColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    var color: Color { Color(cgColor: cgColor) }

    /// Contrasting halo drawn around text so labels read on any background.
    var outline: CGColor {
        switch self {
        case .yellow, .white: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75)
        default: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        }
    }

    var title: String { self == .accent ? "Orange" : rawValue.capitalized }
}

enum InkSize: Int, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    /// Line width — or font size, for text — in canvas points.
    func value(for tool: AnnotateTool) -> CGFloat {
        switch tool {
        case .highlighter: [10, 18, 28][rawValue]
        case .text: [14, 20, 30][rawValue]
        default: [3, 5, 9][rawValue]
        }
    }

    var dotDiameter: CGFloat { [5, 8, 12][rawValue] }
    var title: String { ["Small", "Medium", "Large"][rawValue] }
}

/// One mark on the image. Geometry is in full-resolution image pixels (top-left
/// origin), so the preview and the saved file are drawn from the same data.
struct Annotation: Identifiable, Equatable {
    let id = UUID()
    var tool: AnnotateTool
    var color: InkColor
    /// Line width, or font size for text, in image pixels.
    var size: CGFloat
    /// The freehand path, the two ends of a line or arrow, two opposite corners
    /// of a shape, or the top-left corner of a text label.
    var points: [CGPoint]
    var text = ""
}

/// State of the Annotate editor: the marks, the one being drawn, the label being
/// typed and an undo history of snapshots.
@MainActor
final class AnnotateModel: ObservableObject {
    @Published var tool: AnnotateTool = .pen {
        didSet { if tool != oldValue { endTextEditing() } }
    }
    @Published var color: InkColor = .accent {
        didSet { restyleEditingText() }
    }
    @Published var size: InkSize = .medium {
        didSet { restyleEditingText() }
    }

    @Published private(set) var annotations: [Annotation] = []
    /// The mark being dragged out right now.
    @Published private(set) var draft: Annotation?
    /// The label being typed; shown in a text field instead of on the canvas.
    @Published var editingText: Annotation?

    @Published private var undoStack: [[Annotation]] = []
    @Published private var redoStack: [[Annotation]] = []

    let layout: EditorCanvas.Layout

    private var rawPoints: [CGPoint] = []
    private var currentPoint: CGPoint = .zero
    private var tracking = false

    init(layout: EditorCanvas.Layout) {
        self.layout = layout
    }

    /// Marks to draw on the canvas (everything but the label being edited, plus the draft).
    var visibleAnnotations: [Annotation] {
        annotations.filter { $0.id != editingText?.id } + (draft.map { [$0] } ?? [])
    }

    var hasContent: Bool {
        !annotations.isEmpty || !(editingText?.text.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    var canUndo: Bool { !undoStack.isEmpty && editingText == nil && draft == nil }
    var canRedo: Bool { !redoStack.isEmpty && editingText == nil && draft == nil }

    // MARK: History

    func undo() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        Feedback.shared.tick()
    }

    func redo() {
        guard canRedo, let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        Feedback.shared.tick()
    }

    /// Removes every mark (undoable).
    func clear() {
        editingText = nil
        guard !annotations.isEmpty else { return }
        apply { $0.removeAll() }
        Feedback.shared.tick()
    }

    private func apply(_ change: (inout [Annotation]) -> Void) {
        undoStack.append(annotations)
        redoStack.removeAll()
        change(&annotations)
    }

    // MARK: Pointer

    func pointerDown(at location: CGPoint) {
        let point = layout.imagePoint(location)
        tracking = false
        if editingText != nil {
            endTextEditing()
            return
        }
        if tool == .text {
            beginText(at: point)
            return
        }
        tracking = true
        rawPoints = [point]
        currentPoint = point
        draft = Annotation(tool: tool, color: color, size: size.value(for: tool) / layout.scale, points: [point])
    }

    func pointerDragged(to location: CGPoint) {
        guard tracking else { return }
        let point = layout.imagePoint(location)
        currentPoint = point
        if let last = rawPoints.last, hypot(point.x - last.x, point.y - last.y) * layout.scale >= 1.5 {
            rawPoints.append(point)
        }
        updateDraft()
    }

    func pointerUp(at location: CGPoint) {
        guard tracking else { return }
        pointerDragged(to: location)
        tracking = false
        if let mark = draft, isMeaningful(mark) {
            apply { $0.append(mark) }
        }
        draft = nil
        rawPoints = []
    }

    func cursor(at location: CGPoint) -> NSCursor {
        tool == .text ? .iBeam : .crosshair
    }

    /// Rebuilds the draft from the raw input, applying Shift constraints.
    private func updateDraft() {
        guard var mark = draft, let start = rawPoints.first else { return }
        let constrained = NSEvent.modifierFlags.contains(.shift)
        switch mark.tool {
        case .pen, .highlighter:
            mark.points = constrained
                ? [start, snappedToAngle(currentPoint, from: start)]
                : rawPoints + (rawPoints.last == currentPoint ? [] : [currentPoint])
        case .arrow:
            mark.points = [start, constrained ? snappedToAngle(currentPoint, from: start) : currentPoint]
        case .rectangle, .ellipse:
            mark.points = [start, constrained ? squared(currentPoint, from: start) : currentPoint]
        case .text:
            return
        }
        draft = mark
    }

    /// Drops accidental clicks for everything but the pen (a click with it leaves a dot).
    /// Labels are never drafted: they are typed.
    private func isMeaningful(_ mark: Annotation) -> Bool {
        guard let start = mark.points.first, let end = mark.points.last else { return false }
        let minimum = 3 / layout.scale
        switch mark.tool {
        case .pen:
            return true
        case .highlighter, .arrow:
            return mark.points.contains { hypot($0.x - start.x, $0.y - start.y) >= minimum * 2 }
        case .rectangle, .ellipse:
            return abs(end.x - start.x) >= minimum && abs(end.y - start.y) >= minimum
        case .text:
            return false
        }
    }

    private func snappedToAngle(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let length = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    private func squared(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    // MARK: Text

    /// Edits the label under `point`, or starts a new one with its first line centered on it.
    private func beginText(at point: CGPoint) {
        let slop = 4 / layout.scale
        if let hit = annotations.last(where: {
            $0.tool == .text && AnnotationRenderer.textBounds(of: $0).insetBy(dx: -slop, dy: -slop).contains(point)
        }) {
            editingText = hit
        } else {
            let fontSize = size.value(for: .text) / layout.scale
            let height = AnnotationRenderer.lineHeight(fontSize: fontSize)
            editingText = Annotation(
                tool: .text, color: color, size: fontSize,
                points: [CGPoint(x: point.x, y: point.y - height / 2)]
            )
        }
        Feedback.shared.tick()
    }

    /// Commits the label being typed (an emptied label is removed).
    func endTextEditing() {
        guard var label = editingText else { return }
        editingText = nil
        label.text = label.text.trimmingCharacters(in: .whitespaces)
        let index = annotations.firstIndex { $0.id == label.id }
        switch (index, label.text.isEmpty) {
        case (let index?, true):
            apply { $0.remove(at: index) }
        case (let index?, false) where annotations[index] != label:
            apply { $0[index] = label }
        case (nil, false):
            apply { $0.append(label) }
        default:
            break
        }
    }

    /// Picking a color or size while typing restyles the label.
    private func restyleEditingText() {
        guard editingText != nil else { return }
        editingText?.color = color
        editingText?.size = size.value(for: .text) / layout.scale
    }

    // MARK: Keyboard

    /// Return / Enter / Esc finish the label being typed (clipboard shortcuts reach
    /// the field through the app's hidden Edit menu). Shift changes reshape the draft.
    func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            if draft != nil { updateDraft() }
            return false
        }
        guard editingText != nil else { return false }
        let composing = (event.window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
        let finishing = [EditorCanvas.KeyCode.returnKey, EditorCanvas.KeyCode.enter, EditorCanvas.KeyCode.escape]
        if !composing, finishing.contains(event.keyCode) {
            endTextEditing()
            return true
        }
        return false
    }
}
