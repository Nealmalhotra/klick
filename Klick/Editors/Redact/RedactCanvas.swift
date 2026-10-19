import SwiftUI

/// The picture with every box showing the live effect, the selection chrome and
/// the mouse surface.
struct RedactCanvas: View {
    @ObservedObject var model: RedactModel

    var body: some View {
        let layout = model.layout
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                EditorCanvas.Photo(image: model.preview)
                ForEach(model.boxes) { box in
                    RedactBoxView(
                        popsIn: box.popsIn,
                        frame: layout.viewRect(box.rect),
                        canvasSize: layout.size,
                        style: model.style,
                        effect: model.effects[model.style]
                    )
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            if let box = model.selectedBox {
                RedactSelection(frame: layout.viewRect(box.rect), badge: model.badgeCenter(for: box))
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
        .frame(width: layout.size.width, height: layout.size.height)
        .animation(Theme.springSoft, value: model.notice)
        .animation(Theme.springSoft, value: model.boxes.isEmpty)
    }
}

/// One redaction: its slice of the styled preview, or solid black.
private struct RedactBoxView: View {
    let frame: CGRect
    let canvasSize: CGSize
    let style: RedactStyle
    let effect: CGImage?

    @State private var shown: Bool

    init(popsIn: Bool, frame: CGRect, canvasSize: CGSize, style: RedactStyle, effect: CGImage?) {
        self.frame = frame
        self.canvasSize = canvasSize
        self.style = style
        self.effect = effect
        _shown = State(initialValue: !popsIn)
    }

    var body: some View {
        // Thin lines of text get a gentler radius so they still read as boxes, not pills.
        let shape = RoundedRectangle(cornerRadius: min(4, min(frame.width, frame.height) * 0.25), style: .continuous)
        let outlined = style != .black
        fill
            .frame(width: frame.width, height: frame.height)
            .clipShape(shape)
            // Two-tone hairline: keeps a blurred box visible over flat areas, on any background.
            .overlay { shape.inset(by: 0.5).strokeBorder(Color.white.opacity(outlined ? 0.3 : 0), lineWidth: 0.75) }
            .overlay { shape.strokeBorder(Color.black.opacity(outlined ? 0.18 : 0), lineWidth: 0.5) }
            .animation(.easeInOut(duration: 0.22), value: style)
            .scaleEffect(shown ? 1 : 0.3)
            .opacity(shown ? 1 : 0)
            .position(x: frame.midX, y: frame.midY)
            .onAppear {
                guard !shown else { return }
                withAnimation(.spring(response: 0.34, dampingFraction: 0.58)) { shown = true }
            }
    }

    @ViewBuilder private var fill: some View {
        if style != .black, let effect {
            Image(decorative: effect, scale: 1)
                .resizable()
                .frame(width: canvasSize.width, height: canvasSize.height)
                .offset(x: -frame.minX, y: -frame.minY)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        } else {
            Color.black
        }
    }
}

/// Accent outline around the selected box and its × badge (clicks on the badge
/// are resolved by the model, which knows its geometry).
private struct RedactSelection: View {
    let frame: CGRect
    let badge: CGPoint

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .shadow(color: Theme.accent.opacity(0.45), radius: 5)
                .frame(width: frame.width + 6, height: frame.height + 6)
                .position(x: frame.midX, y: frame.midY)

            Image(systemName: "xmark")
                .font(.system(size: 8.5, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: RedactModel.badgeRadius * 2, height: RedactModel.badgeRadius * 2)
                .background(Circle().fill(Theme.accentGradient))
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .position(badge)
        }
        .allowsHitTesting(false)
    }
}
