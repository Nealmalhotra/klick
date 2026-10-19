import SwiftUI

/// "Annotate": draw, highlight, point and label on an image, saved as
/// `<name> Annotated.<ext>` next to the original.
enum AnnotateEditor {
    private static let cardWidth: CGFloat = 520
    /// Card height used by everything but the canvas: title bar, tool rows, footer, paddings.
    private static let reservedHeight: CGFloat = 236

    @MainActor static func present(for item: FileItem) {
        guard let layout = EditorCanvas.Layout.make(for: item, maxWidth: cardWidth - 36, reservedHeight: reservedHeight) else { return }
        EditorWindowController.present(width: cardWidth) { close in
            AnnotateView(item: item, layout: layout, close: close)
        }
    }
}

struct AnnotateView: View {
    let item: FileItem
    let close: () -> Void

    @StateObject private var model: AnnotateModel
    @State private var preview: CGImage?
    @State private var saving = false

    init(item: FileItem, layout: EditorCanvas.Layout, close: @escaping () -> Void) {
        self.item = item
        self.close = close
        _model = StateObject(wrappedValue: AnnotateModel(layout: layout))
    }

    var body: some View {
        EditorShell(title: "Annotate", onClose: close) {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    IconSegmentedPicker(options: AnnotateTool.allCases, selection: $model.tool, help: \.title) { tool in
                        Image(systemName: tool.symbol)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                    GlassSymbolButton(symbol: "arrow.uturn.backward", help: "Undo (⌘Z)", action: model.undo)
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!model.canUndo)
                    GlassSymbolButton(symbol: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: model.redo)
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!model.canRedo)
                }

                AnnotateCanvas(model: model, preview: preview)

                HStack(spacing: 8) {
                    InkColorPicker(selection: $model.color)
                    Spacer(minLength: 0)
                    IconSegmentedPicker(options: InkSize.allCases, selection: $model.size, segmentWidth: 34, help: \.title) { size in
                        Circle().frame(width: size.dotDiameter, height: size.dotDiameter)
                    }
                }
            }
        } footer: {
            KlickSecondaryButton(title: "Reset", action: model.clear)
                .disabled(!model.hasContent || saving)
            Spacer()
            KlickPrimaryButton(title: "Save", isBusy: saving, isEnabled: model.hasContent, action: save)
        }
        .background(EditorCanvas.KeyInterceptor(handler: model.handleKey))
        .task { preview = await model.layout.loadPreview(of: item.url) }
    }

    private func save() {
        model.endTextEditing()
        guard !model.annotations.isEmpty, !saving else { return }
        saving = true
        let annotations = model.annotations
        let source = item.url
        let pixelSize = model.layout.pixelSize
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try AnnotationRenderer.export(annotations, source: source, pixelSize: pixelSize)
                }.value
                Feedback.shared.success()
                close()
                Toast.shared.showMessage("Saved")
            } catch {
                saving = false
                Feedback.shared.failure()
                Toast.shared.showMessage(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }
}
