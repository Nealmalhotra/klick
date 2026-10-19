import Combine
import Foundation

/// Observable state of the wheel currently on screen.
final class WheelModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case shown
        /// Fading out; `committed` when an action was picked (quick burst) vs. cancelled (shrink).
        case dismissing(committed: Bool)
    }

    let items: [FileItem]
    let pages: [WheelPage]

    @Published var pageIndex = 0
    @Published var hovered: Int?
    @Published var phase: Phase = .hidden
    /// Bumped on every page change so the view can re-run its entry animation.
    @Published var pageToken = 0

    init(items: [FileItem], pages: [WheelPage]) {
        self.items = items
        self.pages = pages
    }

    var page: WheelPage { pages[pageIndex] }
    var actions: [KlickAction] { page.actions }

    var hoveredAction: KlickAction? {
        guard let hovered, actions.indices.contains(hovered) else { return nil }
        return actions[hovered]
    }

    /// Text in the hub pill: hovered action, else the selection's size (like "1.1 MB").
    var hubText: String {
        if let action = hoveredAction { return action.title }
        return defaultHubText
    }

    var defaultHubText: String {
        let size = ByteCountFormatter.klickString(items.totalSize)
        if items.count == 1 {
            return items[0].kind == .folder ? "FOLDER" : size
        }
        return "\(items.count) FILES"
    }

    func flip(by delta: Int) {
        guard pages.count > 1 else { return }
        pageIndex = (pageIndex + delta + pages.count) % pages.count
        hovered = nil
        pageToken += 1
    }
}
