import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Broad family a selected file belongs to; decides which wheel pages appear.
enum FileKind: String {
    case image, pdf, video, audio, document, spreadsheet, presentation, subtitle, ebook, archive, folder, other
    /// A GIF with more than one frame: converts to video, not to still images.
    case animatedImage
}

/// A file or folder selected in Finder.
struct FileItem: Hashable, Identifiable {
    let url: URL
    let contentType: UTType?
    let isDirectory: Bool
    let isPackage: Bool
    let size: Int64
    /// GIF with more than one frame (read once here: `kind` is asked often).
    let isAnimatedGIF: Bool

    var id: URL { url }

    init(url: URL) {
        self.url = url.standardizedFileURL
        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey, .isDirectoryKey, .isPackageKey, .fileSizeKey, .totalFileAllocatedSizeKey,
        ])
        contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        isDirectory = values?.isDirectory ?? false
        isPackage = values?.isPackage ?? false
        size = Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
        isAnimatedGIF = !isDirectory && url.pathExtension.lowercased() == "gif" && Self.frameCount(of: url) > 1
    }

    /// Number of frames ImageIO sees, without decoding any of them.
    private static func frameCount(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    var name: String { url.lastPathComponent }
    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }
    var directory: URL { url.deletingLastPathComponent() }

    var kind: FileKind {
        if isDirectory && !isPackage { return .folder }
        // Extension checks first: these types are often unknown to the system or
        // conform to something broader (CSV is plain text, EPUB may be a package).
        switch ext {
        case "srt", "vtt": return .subtitle
        case "csv", "tsv", "xlsx", "xls", "ods", "numbers": return .spreadsheet
        case "pptx", "ppt", "key", "odp": return .presentation
        case "epub": return .ebook
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz": return isPackage ? .other : .archive
        // Containers AVFoundation can't open: offering conversions would only fail.
        case "mkv", "webm", "avi", "wmv", "asf", "flv", "ogv", "rm", "rmvb", "wma": return .other
        default: break
        }
        if isAnimatedGIF { return .animatedImage }
        guard let type = contentType else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .presentation) { return .presentation }
        if FileItem.documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return .other
    }

    static let documentTypes: [UTType] = [
        .plainText, .rtf, .rtfd, .html, .flatRTFD,
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"),
        UTType("org.oasis-open.opendocument.text"),
        UTType("net.daringfireball.markdown"),
        UTType("com.apple.finder.textclipping"),
        UTType("com.apple.iwork.pages.sffpages"),
        UTType("com.apple.iwork.pages.pages"),
    ].compactMap { $0 }
}

extension Array where Element == FileItem {
    /// The shared kind of every item, or `nil` when the selection is mixed.
    var commonKind: FileKind? {
        guard let first = first?.kind else { return nil }
        return allSatisfy { $0.kind == first } ? first : nil
    }

    var totalSize: Int64 { reduce(0) { $0 + $1.size } }
}
