import AppKit
import Foundation

/// Decides which wheel pages (and in which clockwise order, starting at 12 o'clock)
/// are offered for a Finder selection.
///
/// Every selection gets up to three pages, like the three wheels of the original:
/// **Convert** (Shift), **Tools** (Command) and **File** actions (Control). The pages
/// for each family of files live in `ActionCatalog+<Family>.swift`.
enum ActionCatalog {
    /// Page ids, in wheel order.
    enum PageID {
        static let convert = "convert"
        static let tools = "tools"
        static let file = "file"
    }

    static func pages(for items: [FileItem]) -> [WheelPage] {
        guard !items.isEmpty else { return [] }
        var pages: [WheelPage] = []

        switch items.commonKind {
        case .pdf:
            pages = [pdfConvertPage(items), pdfToolsPage(items)]
        case .image:
            pages = [imageConvertPage(items), imageToolsPage(items)]
        case .video:
            pages = [videoConvertPage(items), videoToolsPage(items)]
        case .animatedImage:
            pages = [animatedGIFConvertPage(items), animatedGIFToolsPage(items)]
        case .audio:
            pages = [audioConvertPage(items), audioToolsPage(items)]
        case .document:
            pages = [documentConvertPage(items)]
        case .spreadsheet:
            pages = [spreadsheetConvertPage(items)]
        case .presentation:
            pages = [presentationConvertPage(items)]
        case .subtitle:
            pages = [subtitleConvertPage(items)]
        case .ebook:
            pages = [ebookConvertPage(items)]
        case .archive:
            pages = [archiveConvertPage(items), archiveToolsPage(items)]
        case .folder, .other, .none:
            break
        }
        pages.append(filePage(items))
        return pages.filter { !$0.actions.isEmpty }
    }

    /// Looks an action up by id (used by the debug CLI).
    static func action(id: String, for items: [FileItem]) -> KlickAction? {
        pages(for: items).flatMap(\.actions).first { $0.id == id }
    }

    // MARK: - Builders

    static func perFile(
        _ id: String, _ title: String, symbol: String? = nil, verb: String,
        work: @escaping (FileItem, JobProgress) async throws -> [URL]
    ) -> KlickAction {
        KlickAction(id: id, title: title, symbol: symbol, kind: .perFile(verb: verb, work: work))
    }

    static func batch(
        _ id: String, _ title: String, symbol: String? = nil, verb: String,
        work: @escaping ([FileItem], JobProgress) async throws -> [URL]
    ) -> KlickAction {
        KlickAction(id: id, title: title, symbol: symbol, kind: .batch(verb: verb, work: work))
    }

    static func editor(
        _ id: String, _ title: String, symbol: String?,
        open: @escaping @MainActor ([FileItem]) -> Void
    ) -> KlickAction {
        KlickAction(id: id, title: title, symbol: symbol, kind: .editor(open))
    }

    static func instant(
        _ id: String, _ title: String, symbol: String?, confirmation: String?,
        perform: @escaping @MainActor ([FileItem]) -> Void
    ) -> KlickAction {
        KlickAction(id: id, title: title, symbol: symbol, kind: .instant(confirmation: confirmation, perform: perform))
    }
}
