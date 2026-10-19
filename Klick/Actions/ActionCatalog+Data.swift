import AppKit
import Foundation

extension ActionCatalog {
    // MARK: - Spreadsheets

    /// XLSX, ODS, CSV, TSV and PDF, minus the format of the selection (XLS is read-only).
    /// Numbers documents can't be read, so they get no convert page.
    static func spreadsheetConvertPage(_ items: [FileItem]) -> WheelPage {
        guard items.allSatisfy(SpreadsheetConverter.canRead) else {
            return WheelPage(id: PageID.convert, title: "Convert", actions: [])
        }
        let exts = Set(items.map(\.ext))
        let targets = SpreadsheetFormat.allCases.filter { exts.count > 1 || exts.first != $0.ext }
        return WheelPage(id: PageID.convert, title: "Convert", actions: targets.map { format in
            perFile("convert.\(format.ext)", format.title, verb: "Converting to \(format.title)") { item, p in
                try await SpreadsheetConverter.convert(item, to: format, progress: p)
            }
        })
    }

    // MARK: - Subtitles

    static func subtitleConvertPage(_ items: [FileItem]) -> WheelPage {
        let exts = Set(items.map(\.ext))
        let targets = SubtitleFormat.allCases.filter { exts.count > 1 || exts.first != $0.ext }
        return WheelPage(id: PageID.convert, title: "Convert", actions: targets.map { format in
            perFile("convert.\(format.ext)", format.title, verb: "Converting to \(format.title)") { item, p in
                [try SubtitleConverter.convert(item, to: format, progress: p)]
            }
        })
    }

    // MARK: - Archives

    /// ZIP, TAR and GZIP (`.tar.gz`), minus the format of the selection.
    static func archiveConvertPage(_ items: [FileItem]) -> WheelPage {
        let sources = Set(items.map { ArchiveFormat(sourceExtension: $0.ext) })
        let current = sources.count == 1 ? sources.first ?? nil : nil
        let targets = ArchiveFormat.allCases.filter { $0 != current }
        return WheelPage(id: PageID.convert, title: "Convert", actions: targets.map { format in
            perFile("convert.\(format.rawValue)", format.title, verb: "Converting to \(format.title)") { item, p in
                [try ArchiveConverter.convert(item, to: format, progress: p)]
            }
        })
    }

    static func archiveToolsPage(_ items: [FileItem]) -> WheelPage {
        WheelPage(id: PageID.tools, title: "Tools", actions: [
            perFile("tool.extract", "EXTRACT", symbol: "archivebox", verb: "Extracting") { item, p in
                [try ArchiveConverter.extract(item, progress: p)]
            },
        ])
    }
}
