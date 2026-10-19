import SwiftUI

/// "Organize PDF": a grid of page thumbnails to drag into a new order, turn or delete,
/// saved as `<name> Organized.pdf` next to the original.
enum OrganizePDFEditor {
    private static let cardWidth: CGFloat = 620
    /// Card height used by everything but the grid: title bar, toolbar, footer, paddings.
    private static let reservedHeight: CGFloat = 230

    @MainActor static func present(for item: FileItem) {
        guard let model = OrganizePDFModel(item: item, gridWidth: cardWidth - 36) else {
            Feedback.shared.failure()
            Toast.shared.showMessage("Couldn't open \(item.name)", symbol: "exclamationmark.triangle.fill")
            return
        }
        let anchor = EditorWindowController.anchorOverride ?? NSEvent.mouseLocation
        let screenHeight = NSScreen.containing(anchor)?.visibleFrame.height ?? 800
        let maxHeight = min(max(screenHeight * 0.85 - reservedHeight, 200), 560)
        let viewport = min(model.metrics.contentHeight(count: model.pages.count), maxHeight)
        EditorWindowController.present(width: cardWidth) { close in
            OrganizePDFView(model: model, viewportHeight: viewport, close: close)
        }
    }
}

struct OrganizePDFView: View {
    @ObservedObject var model: OrganizePDFModel
    let viewportHeight: CGFloat
    let close: () -> Void

    @State private var saving = false

    var body: some View {
        EditorShell(title: "Organize PDF", onClose: close) {
            VStack(spacing: 12) {
                toolbar
                OrganizeGrid(model: model)
                    .frame(height: viewportHeight)
                    .background(
                        RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous))
            }
        } footer: {
            KlickSecondaryButton(title: "Reset", action: model.reset)
                .disabled(!model.isModified || saving)
            Spacer()
            KlickPrimaryButton(title: "Save", isBusy: saving, isEnabled: model.isModified, action: save)
        }
        .background(EditorCanvas.KeyInterceptor(handler: model.handleKey))
        .task { await model.loadThumbnails() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.summary)
                    .font(.system(size: 13, weight: .semibold))
                    .contentTransition(.numericText())
                Text(model.selection.isEmpty ? "Drag to reorder · click to select" : "R to turn · ⌫ to delete")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .animation(Theme.springSnappy, value: model.summary)
            Spacer(minLength: 12)
            toolButton("rotate.left", help: "Rotate Left (⇧R)") { model.rotateSelection(by: -90) }
                .disabled(model.selection.isEmpty || saving)
            toolButton("rotate.right", help: "Rotate Right (R)") { model.rotateSelection(by: 90) }
                .disabled(model.selection.isEmpty || saving)
            toolButton("trash", help: "Delete (⌫)", tint: .red) { model.deleteSelection() }
                .disabled(!model.canDeleteSelection || saving)
        }
    }

    private func toolButton(_ symbol: String, help: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ToolbarIcon(symbol: symbol, tint: tint)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .help(help)
    }

    private func save() {
        guard model.isModified, !saving else { return }
        saving = true
        let item = model.item
        let order = model.pages.map { (index: $0.source, rotation: $0.rotation) }
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try PDFConverter.organize(item, pages: order)
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

/// Toolbar symbol that visibly dims while its button is disabled (nothing selected).
private struct ToolbarIcon: View {
    let symbol: String
    let tint: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .opacity(isEnabled ? 1 : 0.35)
            .frame(width: 22, height: 22)
            .animation(Theme.springSnappy, value: isEnabled)
    }
}

// MARK: - Grid

/// Pages laid out by hand (not a `LazyVGrid`) so a reorder animates every tile to its new slot
/// while the dragged one follows the pointer. One mouse surface covers the grid: it accepts the
/// first click of the non-activating panel and keeps drags from moving the window.
private struct OrganizeGrid: View {
    @ObservedObject var model: OrganizePDFModel

    var body: some View {
        let metrics = model.metrics
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    let lifted = model.dragging == page.id
                    let hovered = model.hovered == page.id && model.dragging == nil
                    OrganizeTile(
                        page: page,
                        number: index + 1,
                        visibleSize: model.visibleSize(of: page),
                        thumbnail: model.thumbnails[page.source],
                        box: metrics.thumbnailBox,
                        selected: model.selection.contains(page.id),
                        lifted: lifted,
                        buttons: hovered ? model.tileButtons : [],
                        hoveredButton: hovered ? model.hoveredButton : nil
                    )
                    .frame(width: metrics.cell.width, height: metrics.cell.height, alignment: .top)
                    .position(model.tileCenter(of: page, at: index))
                    .zIndex(lifted ? 1 : 0)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: metrics.contentHeight(count: model.pages.count), alignment: .topLeading)
            .overlay {
                EditorCanvas.MouseInput(
                    onDown: model.pointerDown,
                    onDrag: model.pointerDragged,
                    onUp: model.pointerUp,
                    cursor: model.cursor
                )
                .onHover { if !$0 { model.pointerExited() } }
            }
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Tile

/// A page thumbnail with its number; the hovered one shows turn and delete buttons
/// (hit-tested by the model, which shares the button geometry).
private struct OrganizeTile: View {
    let page: OrganizePage
    let number: Int
    let visibleSize: CGSize
    let thumbnail: CGImage?
    let box: CGSize
    let selected: Bool
    let lifted: Bool
    let buttons: [OrganizePDFModel.TileButton]
    let hoveredButton: OrganizePDFModel.TileButton?

    private typealias Metrics = OrganizePDFModel.Metrics

    var body: some View {
        let visible = visibleSize
        VStack(spacing: 8) {
            paper
                // Laid out unturned, then rotated: the turned page exactly fills `visible`.
                .frame(
                    width: page.isQuarterTurned ? visible.height : visible.width,
                    height: page.isQuarterTurned ? visible.width : visible.height
                )
                .rotationEffect(.degrees(Double(page.rotation)))
                .frame(width: visible.width, height: visible.height)
                .shadow(color: .black.opacity(lifted ? 0.28 : 0.14), radius: lifted ? 14 : 3, y: lifted ? 8 : 1)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2.5)
                        .padding(-5)
                        .opacity(selected ? 1 : 0)
                        .scaleEffect(selected ? 1 : 1.06)
                }
                .overlay(alignment: .topTrailing) {
                    if !buttons.isEmpty {
                        HStack(spacing: Metrics.buttonSpacing) {
                            ForEach(buttons, id: \.self) { tileButton($0) }
                        }
                        .padding(Metrics.buttonInset)
                        .transition(.scale(scale: 0.7, anchor: .topTrailing).combined(with: .opacity))
                    }
                }
                .frame(width: box.width, height: box.height)
                .scaleEffect(lifted ? 1.07 : 1)

            Text("\(number)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .frame(minWidth: 24, minHeight: 18)
                .background {
                    Capsule().fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                }
                .contentTransition(.numericText())
                .opacity(lifted ? 0 : 1)
        }
        .padding(.top, Metrics.boxTop)
        .animation(Theme.springSnappy, value: lifted)
        .animation(Theme.springSnappy, value: selected)
    }

    /// The page white with its thumbnail on top (a soft placeholder until it's rendered).
    private var paper: some View {
        ZStack {
            Color.white
            if let thumbnail {
                Image(decorative: thumbnail, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .transition(.opacity)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func tileButton(_ button: OrganizePDFModel.TileButton) -> some View {
        let hot = hoveredButton == button
        return Image(systemName: button.symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(button == .delete ? Color.red : Color.primary)
            .frame(width: Metrics.buttonSize, height: Metrics.buttonSize)
            .glassEffect(.regular, in: Circle())
            .scaleEffect(hot ? 1.12 : 1)
            .animation(Theme.springSnappy, value: hot)
    }
}
