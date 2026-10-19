import AppKit
import PDFKit
import SwiftUI

/// One page in the Organize grid.
struct OrganizePage: Identifiable, Equatable {
    let id = UUID()
    /// Index of the page in the original document.
    let source: Int
    /// Extra clockwise turn in degrees. Not wrapped to 0..<360, so every turn animates the short way.
    var rotation = 0

    var isQuarterTurned: Bool { (rotation / 90).isMultiple(of: 2) == false }
}

/// State of the Organize editor: page order, turns, selection, live drag-to-reorder and thumbnails.
@MainActor
final class OrganizePDFModel: ObservableObject {
    /// Grid geometry, in points, inside the scrolling content.
    struct Metrics {
        let columns: Int
        let cell: CGSize
        let spacing: CGFloat
        let inset: CGFloat
        /// Area a page thumbnail is fitted into (the rest of the cell holds the page number).
        let thumbnailBox: CGSize

        /// Gap between the top of a cell and its thumbnail box.
        static let boxTop: CGFloat = 4
        /// The round turn / delete buttons shown on the hovered page.
        static let buttonSize: CGFloat = 22
        static let buttonInset: CGFloat = 4
        static let buttonSpacing: CGFloat = 4

        init(width: CGFloat, columns: Int = 5) {
            self.columns = columns
            spacing = 10
            inset = 12
            let cellWidth = ((width - inset * 2 - spacing * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
            thumbnailBox = CGSize(width: cellWidth - 14, height: (cellWidth * 1.22).rounded())
            cell = CGSize(width: cellWidth, height: thumbnailBox.height + 34)
        }

        func center(at index: Int) -> CGPoint {
            CGPoint(
                x: inset + CGFloat(index % columns) * (cell.width + spacing) + cell.width / 2,
                y: inset + CGFloat(index / columns) * (cell.height + spacing) + cell.height / 2
            )
        }

        /// Slot under `point`, clamped to the existing pages.
        func index(at point: CGPoint, count: Int) -> Int {
            let column = min(max(Int((point.x - inset + spacing / 2) / (cell.width + spacing)), 0), columns - 1)
            let row = max(Int((point.y - inset + spacing / 2) / (cell.height + spacing)), 0)
            return min(row * columns + column, count - 1)
        }

        func contentHeight(count: Int) -> CGFloat {
            let rows = max((count + columns - 1) / columns, 1)
            return inset * 2 + CGFloat(rows) * cell.height + CGFloat(rows - 1) * spacing
        }
    }

    @Published private(set) var pages: [OrganizePage]
    @Published private(set) var selection: Set<OrganizePage.ID> = []
    @Published private(set) var thumbnails: [Int: CGImage] = [:]
    /// The page following the pointer, and where its center is.
    @Published private(set) var dragging: OrganizePage.ID?
    @Published private(set) var dragCenter: CGPoint = .zero
    /// The page under the pointer (shows its buttons), and the button under it, if any.
    @Published private(set) var hovered: OrganizePage.ID?
    @Published private(set) var hoveredButton: TileButton?

    enum TileButton: CaseIterable {
        case rotate, delete

        var symbol: String { self == .rotate ? "rotate.right" : "trash" }
    }

    let item: FileItem
    let metrics: Metrics
    /// Size of every source page as displayed (crop box, page rotation applied).
    let pageSizes: [CGSize]

    private let original: [OrganizePage]
    private var history: [[OrganizePage]] = []
    private var anchor: OrganizePage.ID?
    private var grabOffset: CGSize = .zero
    private var press: (page: OrganizePage.ID?, start: CGPoint, button: TileButton?)?

    init?(item: FileItem, gridWidth: CGFloat) {
        guard let document = PDFDocument(url: item.url), !document.isLocked, document.pageCount > 0 else { return nil }
        self.item = item
        metrics = Metrics(width: gridWidth)
        pageSizes = (0..<document.pageCount).map { index in
            document.page(at: index).map(PDFConverter.displaySize) ?? CGSize(width: 612, height: 792)
        }
        original = pageSizes.indices.map { OrganizePage(source: $0) }
        pages = original
    }

    var isModified: Bool {
        pages.map(\.source) != original.map(\.source) || pages.contains { $0.rotation % 360 != 0 }
    }

    /// Selected pages, in grid order.
    var selectedIDs: [OrganizePage.ID] { pages.map(\.id).filter(selection.contains) }

    /// At least one page has to stay.
    var canDeleteSelection: Bool { !selection.isEmpty && selection.count < pages.count }

    var summary: String {
        let total = pages.count == 1 ? "1 page" : "\(pages.count) pages"
        return selection.isEmpty ? total : "\(selection.count) of \(total) selected"
    }

    func index(of id: OrganizePage.ID) -> Int? { pages.firstIndex { $0.id == id } }

    // MARK: Thumbnails

    /// Renders the thumbnails one after another, off the main thread; stops when the editor closes.
    func loadThumbnails() async {
        guard let renderer = ThumbnailRenderer(url: item.url) else { return }
        let maxPixels = max(metrics.thumbnailBox.width, metrics.thumbnailBox.height) * 2
        for index in pageSizes.indices {
            guard !Task.isCancelled else { return }
            let image = await Task.detached(priority: .userInitiated) {
                renderer.thumbnail(at: index, maxPixels: maxPixels)
            }.value
            if let image {
                withAnimation(.easeOut(duration: 0.22)) { thumbnails[index] = image }
            }
        }
    }

    // MARK: Selection

    /// Click selects one page (or deselects it), ⌘-click toggles, ⇧-click extends the range.
    func tap(_ id: OrganizePage.ID) {
        let flags = NSEvent.modifierFlags
        withAnimation(Theme.springSnappy) {
            if flags.contains(.command) {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else if flags.contains(.shift), let anchor, let from = index(of: anchor), let to = index(of: id) {
                selection = Set(pages[min(from, to)...max(from, to)].map(\.id))
            } else {
                selection = selection == [id] ? [] : [id]
            }
        }
        anchor = id
        Feedback.shared.tick()
    }

    func selectAll() {
        withAnimation(Theme.springSnappy) { selection = Set(pages.map(\.id)) }
    }

    func deselect() {
        guard !selection.isEmpty else { return }
        withAnimation(Theme.springSnappy) { selection = [] }
    }

    // MARK: Editing

    func rotate(_ ids: [OrganizePage.ID], by degrees: Int) {
        guard !ids.isEmpty else { return }
        record()
        withAnimation(Theme.springSoft) {
            for id in ids {
                if let index = index(of: id) { pages[index].rotation += degrees }
            }
        }
        Feedback.shared.tick()
    }

    func rotateSelection(by degrees: Int) { rotate(selectedIDs, by: degrees) }

    func delete(_ ids: Set<OrganizePage.ID>) {
        guard !ids.isEmpty, ids.count < pages.count else { return }
        record()
        withAnimation(Theme.springSoft) {
            pages.removeAll { ids.contains($0.id) }
            selection.subtract(ids)
        }
        Feedback.shared.tick()
    }

    func deleteSelection() { delete(selection) }

    func undo() {
        guard let previous = history.popLast() else { return }
        withAnimation(Theme.springSoft) {
            pages = previous
            selection = selection.filter { id in previous.contains { $0.id == id } }
        }
        Feedback.shared.tick()
    }

    func reset() {
        guard isModified else { return }
        record()
        withAnimation(Theme.springSoft) {
            // Keep the identities of surviving pages so they glide home instead of popping.
            let surviving = Dictionary(pages.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
            pages = original.map { page in
                guard var kept = surviving[page.source] else { return page }
                kept.rotation = (kept.rotation / 360) * 360
                return kept
            }
            selection = []
        }
        Feedback.shared.tick()
    }

    private func record() {
        history.append(pages)
        if history.count > 100 { history.removeFirst() }
    }

    // MARK: Geometry

    /// On-screen size of a page with its turn applied, fitted into the thumbnail box.
    func visibleSize(of page: OrganizePage) -> CGSize {
        let source = pageSizes[page.source]
        let width = max(source.width, 1), height = max(source.height, 1)
        let turned = page.isQuarterTurned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        let box = metrics.thumbnailBox
        let scale = min(box.width / turned.width, box.height / turned.height)
        return CGSize(width: (turned.width * scale).rounded(), height: (turned.height * scale).rounded())
    }

    /// Where a tile is drawn: its slot, or under the pointer while it's being dragged.
    func tileCenter(of page: OrganizePage, at index: Int) -> CGPoint {
        dragging == page.id ? dragCenter : metrics.center(at: index)
    }

    /// The buttons a page offers (no delete for the last one).
    var tileButtons: [TileButton] { pages.count > 1 ? TileButton.allCases : [.rotate] }

    /// Buttons of the page at `index`, in grid points: a row in the page's top-right corner.
    private func buttonFrames(of page: OrganizePage, at index: Int) -> [(TileButton, CGRect)] {
        let center = tileCenter(of: page, at: index)
        let boxCenterY = center.y - metrics.cell.height / 2 + Metrics.boxTop + metrics.thumbnailBox.height / 2
        let visible = visibleSize(of: page)
        let size = Metrics.buttonSize
        var maxX = center.x + visible.width / 2 - Metrics.buttonInset
        let minY = boxCenterY - visible.height / 2 + Metrics.buttonInset
        var frames: [(TileButton, CGRect)] = []
        for button in tileButtons.reversed() {
            frames.insert((button, CGRect(x: maxX - size, y: minY, width: size, height: size)), at: 0)
            maxX -= size + Metrics.buttonSpacing
        }
        return frames
    }

    private func page(at point: CGPoint) -> (OrganizePage, Int)? {
        for (index, page) in pages.enumerated().reversed() {
            let center = tileCenter(of: page, at: index)
            let cell = CGRect(x: center.x - metrics.cell.width / 2, y: center.y - metrics.cell.height / 2,
                              width: metrics.cell.width, height: metrics.cell.height)
            if cell.contains(point) { return (page, index) }
        }
        return nil
    }

    private func button(at point: CGPoint) -> (OrganizePage, TileButton)? {
        guard dragging == nil, let id = hovered, let index = index(of: id) else { return nil }
        let page = pages[index]
        return buttonFrames(of: page, at: index).first { $0.1.insetBy(dx: -2, dy: -2).contains(point) }.map { (page, $0.0) }
    }

    // MARK: Pointer

    /// Press on a page (select or start dragging it), on one of its buttons, or on the empty grid (deselect).
    func pointerDown(at point: CGPoint) {
        if let (page, button) = button(at: point) {
            press = (page.id, point, button)
        } else {
            press = (page(at: point)?.0.id, point, nil)
        }
    }

    func pointerDragged(to point: CGPoint) {
        guard let press, press.button == nil, let id = press.page else { return }
        if dragging == nil, hypot(point.x - press.start.x, point.y - press.start.y) < 4 { return }
        dragChanged(id, location: point, start: press.start)
    }

    func pointerUp(at point: CGPoint) {
        defer { press = nil }
        guard let press else { return }
        if dragging != nil {
            dragEnded()
        } else if let button = press.button, let id = press.page {
            // Act only when released over the same button, like a regular button.
            guard self.button(at: point).map({ $0.0.id == id && $0.1 == button }) == true else { return }
            switch button {
            case .rotate: rotate([id], by: 90)
            case .delete: delete([id])
            }
            updateHover(at: point)
        } else if let id = press.page {
            tap(id)
        } else {
            deselect()
        }
    }

    /// Tracks the hovered page and button, and picks the cursor.
    func cursor(at point: CGPoint) -> NSCursor {
        updateHover(at: point)
        if dragging != nil { return .closedHand }
        if hoveredButton != nil { return .pointingHand }
        return hovered == nil ? .arrow : .openHand
    }

    func pointerExited() {
        guard dragging == nil, hovered != nil || hoveredButton != nil else { return }
        withAnimation(Theme.springSnappy) {
            hovered = nil
            hoveredButton = nil
        }
    }

    private func updateHover(at point: CGPoint) {
        let page = dragging == nil ? page(at: point)?.0.id : dragging
        if page != hovered {
            withAnimation(Theme.springSnappy) { hovered = page }
        }
        let button = button(at: point)?.1
        if button != hoveredButton {
            withAnimation(Theme.springSnappy) { hoveredButton = button }
        }
    }

    // MARK: Drag to reorder

    /// Lifts the page on the first move, then slides the others out of the way as it crosses their slots.
    private func dragChanged(_ id: OrganizePage.ID, location: CGPoint, start: CGPoint) {
        guard let current = index(of: id) else { return }
        if dragging != id {
            let center = metrics.center(at: current)
            grabOffset = CGSize(width: start.x - center.x, height: start.y - center.y)
            record()
            withAnimation(Theme.springSnappy) {
                dragging = id
                dragCenter = center
                hoveredButton = nil
            }
            Feedback.shared.tick()
        }
        dragCenter = CGPoint(x: location.x - grabOffset.width, y: location.y - grabOffset.height)
        let target = metrics.index(at: dragCenter, count: pages.count)
        guard target != current else { return }
        withAnimation(Theme.springSnappy) {
            let page = pages.remove(at: current)
            pages.insert(page, at: target)
        }
        Feedback.shared.tick()
    }

    private func dragEnded() {
        guard dragging != nil else { return }
        // Nothing moved: forget the snapshot taken when the page was lifted.
        if history.last == pages { history.removeLast() }
        withAnimation(Theme.springSoft) { dragging = nil }
    }

    // MARK: Keyboard

    /// ⌫ deletes, R / ⇧R turns, ⌘A selects all, ⌘Z undoes, Esc deselects (and closes when nothing is selected).
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, flags) {
        case (EditorCanvas.KeyCode.delete, []), (EditorCanvas.KeyCode.forwardDelete, []):
            guard !selection.isEmpty else { return false }
            deleteSelection()
            return true
        case (EditorCanvas.KeyCode.escape, []):
            guard !selection.isEmpty else { return false }
            deselect()
            return true
        case (KeyCode.r, []):
            rotateSelection(by: 90)
            return !selection.isEmpty
        case (KeyCode.r, [.shift]):
            rotateSelection(by: -90)
            return !selection.isEmpty
        case (KeyCode.a, [.command]):
            selectAll()
            return true
        case (KeyCode.z, [.command]):
            undo()
            return true
        default:
            return false
        }
    }

    private enum KeyCode {
        static let a: UInt16 = 0
        static let r: UInt16 = 15
        static let z: UInt16 = 6
    }
}

/// Draws page thumbnails from its own copy of the document. Only used by one detached task at a
/// time (thumbnails render one after another), which is what makes the unchecked conformance safe.
private final class ThumbnailRenderer: @unchecked Sendable {
    private let document: PDFDocument

    init?(url: URL) {
        guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
        self.document = document
    }

    func thumbnail(at index: Int, maxPixels: CGFloat) -> CGImage? {
        guard let page = document.page(at: index) else { return nil }
        return try? PDFConverter.render(page, dpi: 144, maxPixels: maxPixels)
    }
}
