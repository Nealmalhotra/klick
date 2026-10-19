import AppKit
import SwiftUI

/// Hooks from the shelf view back to its window controller.
@MainActor
struct ShelfActions {
    var close: () -> Void
    var toggleCollapsed: () -> Void
    var dragBegan: () -> Void
    var dragMoved: (NSPoint) -> Void
    var dragEnded: (CGVector) -> Void
    var filesDropped: ([URL]) -> Void
    /// A drag out of the shelf finished with `operation` for these items.
    var dragOutEnded: (Set<UUID>, NSDragOperation) -> Void
}

/// The Float shelf: a narrow Liquid Glass card listing the floated files, or a slim tab
/// when collapsed against a screen edge.
struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let actions: ShelfActions

    private typealias M = ShelfModel.Metrics

    var body: some View {
        let size = model.cardSize
        ZStack {
            if model.collapsed {
                tab.transition(.opacity.combined(with: .scale(scale: 0.85)))
            } else {
                card.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: model.collapsed ? size.width / 2 : M.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: model.collapsed ? size.width / 2 : M.cornerRadius, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: model.dropTargeted ? 2 : 0)
                .allowsHitTesting(false)
        }
        .scaleEffect(model.dropTargeted ? 1.03 : 1)
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !model.isDraggingOut else { return false }
            actions.filesDropped(files)
            return true
        } isTargeted: { targeted in
            let value = targeted && !model.isDraggingOut
            withAnimation(Theme.springSnappy) { model.dropTargeted = value }
            if value && model.collapsed { actions.toggleCollapsed() }
        }
        // Grow in like the wheel: from small, blurred and transparent.
        .scaleEffect(model.visible ? 1 : 0.5, anchor: .center)
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible ? 0 : 8)
        .padding(M.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.edge == .right ? .topTrailing : .topLeading)
        .animation(Theme.springSoft, value: model.collapsed)
        .animation(Theme.springSnappy, value: model.dropTargeted)
    }

    // MARK: Expanded

    private var card: some View {
        VStack(spacing: 0) {
            header
            HairlineDivider()
            list
            if model.items.count > 1 {
                dragAll
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        ZStack {
            ShelfMoveHandle(onBegan: actions.dragBegan, onMoved: actions.dragMoved, onEnded: actions.dragEnded)
            Text(model.items.count == 1 ? "1 File" : "\(model.items.count) Files")
                .font(.system(size: 12.5, weight: .semibold))
                .contentTransition(.numericText())
                .allowsHitTesting(false)
            HStack {
                ShelfIconButton(symbol: "xmark", help: "Clear shelf", action: actions.close)
                Spacer()
                ShelfIconButton(symbol: model.edge == .right ? "chevron.right" : "chevron.left", help: "Tuck away", action: actions.toggleCollapsed)
            }
            .padding(.horizontal, 8)
        }
        .frame(height: M.headerHeight)
    }

    private var list: some View {
        ScrollView(.vertical) {
            VStack(spacing: M.tileSpacing) {
                ForEach(model.items) { item in
                    ShelfTile(
                        item: item,
                        thumbnail: model.thumbnails[item.id],
                        hovered: model.hovered == item.id,
                        model: model,
                        actions: actions
                    )
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.vertical, M.listPadding)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .scrollDisabled(model.items.count <= M.maxVisibleRows)
    }

    private var dragAll: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Drag All")
                .font(.system(size: 12, weight: .semibold))
        }
        .frame(width: M.tileSize.width, height: 30)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .overlay {
            ShelfDragSource(
                urls: model.items.map(\.url),
                image: model.items.first.flatMap { model.thumbnails[$0.id] },
                onBegan: { model.isDraggingOut = true },
                onEnded: { operation in actions.dragOutEnded(Set(model.items.map(\.id)), operation) }
            )
        }
        .help("Drag every file at once")
        .frame(height: M.footerHeight, alignment: .top)
    }

    // MARK: Collapsed

    private var tab: some View {
        ZStack {
            ShelfMoveHandle(onBegan: actions.dragBegan, onMoved: actions.dragMoved, onEnded: actions.dragEnded, onClick: actions.toggleCollapsed)
            VStack(spacing: 10) {
                Text("\(model.items.count)")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.accentGradient))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 5, y: 2)
                Image(systemName: model.edge == .right ? "chevron.left" : "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
        }
        .help("Show shelf")
    }
}

/// One floated file: thumbnail + name, draggable, with a remove button on hover.
private struct ShelfTile: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    let hovered: Bool
    let model: ShelfModel
    let actions: ShelfActions

    private typealias M = ShelfModel.Metrics

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
                }
            }
            .frame(width: M.thumbnailSide, height: M.thumbnailSide)
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
            .scaleEffect(hovered ? 1.05 : 1)

            Text(item.name)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 6)
        }
        .frame(width: M.tileSize.width, height: M.tileSize.height)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(hovered ? 0.08 : 0))
        )
        .overlay {
            ShelfDragSource(
                urls: [item.url],
                image: thumbnail,
                onHover: { inside in
                    if inside { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil }
                },
                onBegan: { model.isDraggingOut = true },
                onEnded: { operation in actions.dragOutEnded([item.id], operation) },
                onDoubleClick: { NSWorkspace.shared.open(item.url) }
            )
        }
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button {
                    Feedback.shared.tick()
                    model.remove([item.id])
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .help("Remove from shelf")
            }
        }
        .animation(Theme.springSnappy, value: hovered)
        .help(item.url.path)
    }
}

/// Small round glass-ish icon button used in the shelf header.
private struct ShelfIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07)))
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(Theme.springSnappy, value: hovering)
        .onHover { hovering = $0 }
        .help(help)
    }
}
