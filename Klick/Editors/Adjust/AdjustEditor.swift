import SwiftUI

/// "Edit Image": live exposure / color / detail adjustments plus rotate & flip,
/// saved as a new `<name> Edited.<ext>` next to the original.
enum AdjustEditor {
    private static let width: CGFloat = 380

    @MainActor static func present(for item: FileItem) {
        let previewHeight = previewHeight(for: item, width: width - 36)
        EditorWindowController.present(width: width) { close in
            AdjustEditorView(item: item, previewHeight: previewHeight, close: close)
        }
    }

    /// Preview height that suits the image's shape: wide images don't float in
    /// empty space, tall ones get more room (fixed afterwards so the card never resizes).
    private static func previewHeight(for item: FileItem, width: CGFloat) -> CGFloat {
        guard let size = ImageIOKit.orientedPixelSize(item.url), size.width > 0, size.height > 0 else { return 260 }
        return min(max(width * size.height / size.width, 200), 290)
    }
}

struct AdjustEditorView: View {
    let previewHeight: CGFloat
    let close: () -> Void
    @StateObject private var model: AdjustModel
    @State private var tab: AdjustTab = .light
    @State private var isComparing = false

    /// Fixed so switching tabs never resizes the card.
    private static let sliderAreaHeight: CGFloat = 4 * 20 + 3 * 10

    init(item: FileItem, previewHeight: CGFloat, close: @escaping () -> Void) {
        self.previewHeight = previewHeight
        self.close = close
        _model = StateObject(wrappedValue: AdjustModel(item: item))
    }

    var body: some View {
        EditorShell(title: "Edit Image", onClose: close) {
            VStack(spacing: 14) {
                AdjustPreview(
                    original: model.original,
                    preview: model.preview,
                    geometry: model.geometry,
                    isComparing: isComparing,
                    isLoading: model.isLoading
                )
                .frame(height: previewHeight)

                toolRow

                AccentSegmentedPicker(options: AdjustTab.allCases, selection: $tab, label: \.title)

                VStack(spacing: 10) {
                    ForEach(tab.sliders) { slider in
                        AdjustSliderRow(slider: slider, value: $model.adjustments[dynamicMember: slider.keyPath])
                    }
                }
                .id(tab)
                .transition(.opacity.combined(with: .offset(y: 3)))
                .frame(height: Self.sliderAreaHeight)
            }
        } footer: {
            KlickSecondaryButton(title: "Reset") {
                model.reset()
                Feedback.shared.tick()
            }
            .disabled(!model.isModified || model.isSaving)

            ZStack {
                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)

            KlickPrimaryButton(title: "Save", isBusy: model.isSaving, isEnabled: model.isModified, action: save)
        }
        .task { await model.load() }
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    AdjustToolButton(symbol: "rotate.left", help: "Rotate Left (⌘L)") { transform { $0.rotate(clockwise: false) } }
                        .keyboardShortcut("l", modifiers: .command)
                    AdjustToolButton(symbol: "rotate.right", help: "Rotate Right (⌘R)") { transform { $0.rotate(clockwise: true) } }
                        .keyboardShortcut("r", modifiers: .command)
                    AdjustToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal") {
                        transform { $0.flipHorizontally() }
                    }
                    .padding(.leading, 6)
                    AdjustToolButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical") {
                        transform { $0.flipVertically() }
                    }
                }
            }
            Spacer(minLength: 0)
            AdjustCompareButton(isComparing: $isComparing)
                .disabled(model.original == nil)
        }
    }

    private func transform(_ change: (inout ImageGeometry) -> Void) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { change(&model.geometry) }
        Feedback.shared.tick()
    }

    private func save() {
        Task {
            if await model.save() {
                Feedback.shared.success()
                close()
                Toast.shared.showMessage("Saved")
            } else {
                Feedback.shared.failure()
            }
        }
    }
}

// MARK: - Preview

/// Aspect-fit preview. Rotation and flips are SwiftUI transforms (so they animate
/// like a card turning over); the pixels underneath only carry the color work.
private struct AdjustPreview: View {
    let original: CGImage?
    let preview: CGImage?
    let geometry: ImageGeometry
    let isComparing: Bool
    let isLoading: Bool

    private let cornerRadius: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            if let original {
                let fitted = fittedSize(for: original, in: proxy.size)
                let sideways = geometry.quarterTurns % 2 == 1
                let size = sideways ? CGSize(width: fitted.height, height: fitted.width) : fitted
                ZStack {
                    pixels(preview ?? original)
                    pixels(original)
                        .opacity(isComparing ? 1 : 0)
                }
                .frame(width: size.width, height: size.height)
                .background {
                    if ImageIOKit.hasAlpha(original) { CheckerboardView() }
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background {
                    // The shadow belongs to the card, not to the (possibly transparent) pixels.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .rotationEffect(.degrees(geometry.rotation))
                .rotation3DEffect(.degrees(geometry.flipX), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                .rotation3DEffect(.degrees(geometry.flipY), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

                if isComparing {
                    Text("Original")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.bottom, (proxy.size.height - fitted.height) / 2 + 10)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
                }
            } else {
                Group {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isComparing)
        .animation(Theme.springSoft, value: original != nil)
    }

    private func pixels(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
    }

    /// On-screen size of the image once rotated, aspect-fit in `box`.
    private func fittedSize(for image: CGImage, in box: CGSize) -> CGSize {
        let sideways = geometry.quarterTurns % 2 == 1
        let width = CGFloat(sideways ? image.height : image.width)
        let height = CGFloat(sideways ? image.width : image.height)
        let scale = min(box.width / max(width, 1), box.height / max(height, 1))
        return CGSize(width: width * scale, height: height * scale)
    }
}
