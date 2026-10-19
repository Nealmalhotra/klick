import AppKit
import Foundation

extension ActionCatalog {
    // MARK: - Documents

    /// Every `DocumentFormat` except the source's own; RTF, then ODT, drop out when the wheel
    /// would exceed nine segments (Pages, RTFD, clippings, mixed selections).
    static func documentConvertPage(_ items: [FileItem]) -> WheelPage {
        let exts = Set(items.map(\.ext))
        var targets = DocumentFormat.allCases.filter { format in
            exts.count > 1 || !format.matches(extension: exts.first ?? "")
        }
        for spare in [DocumentFormat.rtf, .odt] where targets.count > 9 {
            targets.removeAll { $0 == spare }
        }
        return WheelPage(id: PageID.convert, title: "Convert", actions: targets.map { format in
            perFile("convert.\(format.ext)", format.title, verb: "Converting to \(format.title)") { item, p in
                try await DocumentConverter.convert(item, to: format, progress: p)
            }
        })
    }

    // MARK: - Presentations

    static func presentationConvertPage(_ items: [FileItem]) -> WheelPage {
        guard items.allSatisfy(PresentationConverter.canConvert) else {
            return WheelPage(id: PageID.convert, title: "Convert", actions: [])
        }
        return WheelPage(id: PageID.convert, title: "Convert", actions: PresentationConverter.formats.map { format in
            perFile("convert.\(format.ext)", format.title, verb: "Converting to \(format.title)") { item, p in
                try await PresentationConverter.convert(item, to: format, progress: p)
            }
        })
    }

    // MARK: - E-books

    static func ebookConvertPage(_ items: [FileItem]) -> WheelPage {
        WheelPage(id: PageID.convert, title: "Convert", actions: EPUBReader.formats.map { format in
            perFile("convert.\(format.ext)", format.title, verb: "Converting to \(format.title)") { item, p in
                try await EPUBReader.convert(item, to: format, progress: p)
            }
        })
    }
}
