import SwiftUI

/// "Redact": cover text, faces or anything else with black boxes, blur or
/// pixelation, saved as `<name> Redacted.<ext>` next to the original.
enum RedactEditor {
    private static let cardWidth: CGFloat = 480
    /// Card height used by everything but the canvas: title bar, controls, footer, paddings.
    private static let reservedHeight: CGFloat = 240

    @MainActor static func present(for item: FileItem) {
        guard let layout = EditorCanvas.Layout.make(for: item, maxWidth: cardWidth - 36, reservedHeight: reservedHeight) else { return }
        EditorWindowController.present(width: cardWidth) { close in
            RedactView(item: item, layout: layout, close: close)
        }
    }
}

struct RedactView: View {
    let close: () -> Void

    @StateObject private var model: RedactModel
    @State private var saving = false

    init(item: FileItem, layout: EditorCanvas.Layout, close: @escaping () -> Void) {
        self.close = close
        _model = StateObject(wrappedValue: RedactModel(item: item, layout: layout))
    }

    var body: some View {
        EditorShell(title: "Redact", onClose: close) {
            VStack(spacing: 14) {
                RedactCanvas(model: model)

                HStack {
                    EditorSectionLabel(title: "Style")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: RedactStyle.allCases, selection: $model.style, label: \.title)
                        .frame(width: 252)
                }

                HStack(spacing: 8) {
                    detectButton(.text)
                    detectButton(.faces)
                }
            }
        } footer: {
            KlickSecondaryButton(title: "Reset", action: model.reset)
                .disabled(model.boxes.isEmpty || saving)
            Spacer()
            KlickPrimaryButton(title: "Save", isBusy: saving, isEnabled: !model.boxes.isEmpty, action: save)
        }
        .background(EditorCanvas.KeyInterceptor(handler: model.handleKey))
        .task { await model.load() }
    }

    private func detectButton(_ target: RedactTarget) -> some View {
        let busy = model.detecting == target
        return Button {
            model.detect(target)
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: target.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 16, height: 16)
                Text(target.title)
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity, minHeight: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(model.preview == nil || saving || (model.detecting != nil && !busy))
        .animation(Theme.springSnappy, value: busy)
    }

    private func save() {
        guard !model.boxes.isEmpty, !saving else { return }
        saving = true
        let boxes = model.boxes.map(\.rect)
        let style = model.style
        let source = model.item.url
        let pixelSize = model.layout.pixelSize
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try RedactRenderer.export(boxes, style: style, source: source, pixelSize: pixelSize)
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
