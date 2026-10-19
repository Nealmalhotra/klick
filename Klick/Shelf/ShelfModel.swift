import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A file kept on the Float shelf.
struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    /// File reference (`file:///.file/id=…`): follows the file when it is moved or renamed.
    let reference: NSURL?

    init(url: URL) {
        self.url = url.standardizedFileURL
        reference = (url as NSURL).fileReferenceURL() as NSURL?
    }

    var name: String { url.lastPathComponent }

    /// Where the file is now, or nil once it is gone (deleted or moved to the Trash).
    var currentURL: URL? {
        let resolved = reference?.filePathURL?.standardizedFileURL ?? url
        guard FileManager.default.fileExists(atPath: resolved.path),
              !resolved.pathComponents.contains(".Trash")
        else { return nil }
        return resolved
    }
}

/// Screen edge the shelf is pinned to.
enum ShelfEdge {
    case left, right
}

/// State of the Float shelf, shared by `FloatShelf` (window) and `ShelfView` (content).
@MainActor
final class ShelfModel: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]
    /// nil while the shelf floats freely.
    @Published var edge: ShelfEdge?
    @Published var collapsed = false
    /// Drives the grow-in / shrink-out animation.
    @Published var visible = false
    @Published var dropTargeted = false
    @Published var hovered: UUID?
    /// True while a drag started on the shelf is in flight (the shelf doesn't light up for its own files).
    var isDraggingOut = false

    // MARK: Metrics

    enum Metrics {
        /// Transparent margin around the card so its shadow isn't clipped.
        static let margin: CGFloat = 30
        static let width: CGFloat = 132
        static let headerHeight: CGFloat = 42
        static let tileSize = CGSize(width: 112, height: 94)
        static let tileSpacing: CGFloat = 4
        static let listPadding: CGFloat = 10
        static let footerHeight: CGFloat = 44
        static let maxVisibleRows = 4
        static let thumbnailSide: CGFloat = 62
        static let cornerRadius: CGFloat = 26
        static let tabSize = CGSize(width: 38, height: 118)
        /// Gap between a pinned shelf and the screen edge.
        static let edgeInset: CGFloat = 8
    }

    /// Size of the glass card for the current state.
    var cardSize: CGSize {
        if collapsed { return Metrics.tabSize }
        let rows = CGFloat(min(max(items.count, 1), Metrics.maxVisibleRows))
        let list = rows * Metrics.tileSize.height + (rows - 1) * Metrics.tileSpacing + Metrics.listPadding * 2
        let footer = items.count > 1 ? Metrics.footerHeight : 0
        return CGSize(width: Metrics.width, height: Metrics.headerHeight + 1 + list + footer)
    }

    // MARK: Items

    /// Appends the files that aren't on the shelf yet; returns how many were new.
    @discardableResult
    func add(_ urls: [URL]) -> Int {
        let known = Set(items.map { $0.url.standardizedFileURL.path })
        var seen = known
        let fresh = urls
            .map(\.standardizedFileURL)
            .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
            .map(ShelfItem.init(url:))
        guard !fresh.isEmpty else { return 0 }
        withAnimation(Theme.springSoft) { items.append(contentsOf: fresh) }
        fresh.forEach(loadThumbnail)
        return fresh.count
    }

    func remove(_ ids: Set<UUID>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        withAnimation(Theme.springSoft) { items.removeAll { ids.contains($0.id) } }
        for id in ids { thumbnails[id] = nil }
        if let hovered, ids.contains(hovered) { self.hovered = nil }
    }

    func removeAll() {
        items.removeAll()
        thumbnails.removeAll()
        hovered = nil
    }

    /// Drops files that disappeared and follows the ones that were moved or renamed.
    func refreshFromDisk() {
        var gone: Set<UUID> = []
        for index in items.indices {
            guard let current = items[index].currentURL else {
                gone.insert(items[index].id)
                continue
            }
            if current != items[index].url { items[index].url = current }
        }
        if !gone.isEmpty { remove(gone) }
    }

    // MARK: Thumbnails

    private func loadThumbnail(for item: ShelfItem) {
        thumbnails[item.id] = NSWorkspace.shared.icon(forFile: item.url.path)
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: CGSize(width: Metrics.thumbnailSide, height: Metrics.thumbnailSide),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor [weak self] in
                guard let self, self.items.contains(where: { $0.id == id }) else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.thumbnails[id] = image }
            }
        }
    }
}
