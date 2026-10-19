import SwiftUI

/// The picture with every mark drawn on top, the mouse surface and, while a label
/// is being typed, its text field.
struct AnnotateCanvas: View {
    @ObservedObject var model: AnnotateModel
    let preview: CGImage?

    @FocusState private var textFocused: Bool

    var body: some View {
        let layout = model.layout
        let marks = model.visibleAnnotations
        ZStack(alignment: .topLeading) {
            EditorCanvas.Photo(image: preview)

            Canvas { context, _ in
                context.scaleBy(x: layout.scale, y: layout.scale)
                context.withCGContext { AnnotationRenderer.draw(marks, in: $0) }
            }

            if marks.isEmpty && model.editingText == nil {
                EditorCanvas.Hint(symbol: model.tool.symbol, text: model.tool.hint)
                    .id(model.tool)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }

            EditorCanvas.MouseInput(
                onDown: model.pointerDown(at:),
                onDrag: model.pointerDragged(to:),
                onUp: model.pointerUp(at:),
                cursor: model.cursor(at:)
            )

            if let label = model.editingText {
                labelField(label)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .clipShape(RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .animation(Theme.springSoft, value: marks.isEmpty)
        .animation(Theme.springSoft, value: model.tool)
    }

    /// In-place field styled like the rendered label, framed by a dashed accent outline.
    private func labelField(_ label: Annotation) -> some View {
        let scale = model.layout.scale
        let fontSize = label.size * scale
        let origin = label.points.first ?? .zero
        let placeholder = "Type here"
        let textWidth = AnnotationRenderer.textWidth(label.text.isEmpty ? placeholder : label.text, fontSize: label.size) * scale
        let padding = CGSize(width: 6, height: 3)

        return TextField(placeholder, text: Binding(
            get: { model.editingText?.text ?? "" },
            set: { model.editingText?.text = $0 }
        ))
        .textFieldStyle(.plain)
        .font(Font(AnnotationRenderer.font(size: fontSize) as CTFont))
        .foregroundStyle(label.color.color)
        .tint(label.color == .white ? Theme.accent : label.color.color)
        .focused($textFocused)
        .frame(width: textWidth + fontSize, alignment: .leading)
        .padding(.horizontal, padding.width)
        .padding(.vertical, padding.height)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        .offset(x: origin.x * scale - padding.width, y: origin.y * scale - padding.height)
        .id(label.id)
        .onAppear { textFocused = true }
    }
}
