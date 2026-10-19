import AppKit

/// EPUB → attributed text: `META-INF/container.xml` → OPF package → spine chapters (XHTML, with
/// their images) in reading order. Handles zipped `.epub` files and the folder packages Apple
/// Books keeps in its library.
enum EPUBReader {
    struct Book {
        let title: String?
        let chapters: [URL]
    }

    /// Book title + chapter files. `root` is the unzipped (or folder) book.
    static func book(at root: URL) throws -> Book {
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let container = try? XMLDocument(contentsOf: containerURL, options: []),
              let rootfile = try? container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue
        else { throw KlickError.failed("Not a valid EPUB (container.xml is missing)") }

        let packageURL = root.appendingPathComponent(rootfile.removingPercentEncoding ?? rootfile)
        guard let package = try? XMLDocument(contentsOf: packageURL, options: []) else {
            throw KlickError.failed("Not a valid EPUB (\(rootfile) is missing)")
        }
        let base = packageURL.deletingLastPathComponent()
        var manifest: [String: URL] = [:]
        for item in (try? package.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']")) ?? [] {
            guard let element = item as? XMLElement,
                  let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL
            else { continue }
            manifest[id] = url
        }
        let spine = (try? package.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref")) ?? []
        let chapters = spine.compactMap { $0.stringValue.flatMap { manifest[$0] } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !chapters.isEmpty else { throw KlickError.failed("This EPUB has no readable chapters") }
        let title = try? package.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").first?.stringValue
        return Book(title: title?.trimmingCharacters(in: .whitespacesAndNewlines), chapters: chapters)
    }

    /// The whole book as one attributed string; chapters start on a new paragraph.
    /// Runs the WebKit-backed HTML importer, hence main thread.
    @MainActor
    static func attributedText(of item: FileItem, progress: JobProgress) throws -> NSAttributedString {
        if !item.isDirectory && ((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0 {
            throw KlickError.failed("\(item.name) is empty")
        }
        let unzipped: URL? = item.isDirectory ? nil : try ZipPackage.extract(item.url)
        defer { if let unzipped { try? FileManager.default.removeItem(at: unzipped) } }
        let book = try book(at: unzipped ?? item.url)

        let text = NSMutableAttributedString()
        for (index, chapter) in book.chapters.enumerated() {
            try progress.checkCancelled()
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
                .baseURL: chapter,
            ]
            guard let part = try? NSMutableAttributedString(url: chapter, options: options, documentAttributes: nil) else { continue }
            // Links between chapters point into the temporary folder: keep their text, drop the link.
            part.enumerateAttribute(.link, in: NSRange(location: 0, length: part.length)) { value, range, _ in
                let url = value as? URL ?? (value as? String).flatMap(URL.init(string:))
                if url?.isFileURL == true { part.removeAttribute(.link, range: range) }
            }
            // Images are loaded from the temporary folder; keep their bytes before it goes away.
            part.enumerateAttribute(.attachment, in: NSRange(location: 0, length: part.length)) { value, _, _ in
                guard let attachment = value as? NSTextAttachment, attachment.fileWrapper == nil else { return }
                if let image = attachment.image, let tiff = image.tiffRepresentation {
                    attachment.fileWrapper = FileWrapper(regularFileWithContents: tiff)
                    attachment.fileWrapper?.preferredFilename = "image.tiff"
                }
            }
            let trimmed = part.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || part.string.contains("\u{FFFC}") else { continue }
            if text.length > 0 && !text.string.hasSuffix("\n") { text.append(NSAttributedString(string: "\n")) }
            text.append(part)
            progress.report(0.1 + 0.4 * Double(index + 1) / Double(book.chapters.count))
        }
        guard text.length > 0 else { throw KlickError.failed("No text found in \(item.name)") }
        return DocumentConverter.addingListMarkers(to: text)
    }
}

extension EPUBReader {
    static let formats: [DocumentFormat] = [.pdf, .docx, .txt, .md, .html]

    /// `Book.epub` → `Book.pdf` / `.docx` / `.txt` / `.md` / `.html` (images embedded in the HTML).
    static func convert(_ item: FileItem, to format: DocumentFormat, progress: JobProgress) async throws -> [URL] {
        progress.report(0.05)
        // Import on the main thread (WebKit), write in the background.
        let book = try await MainActor.run { ImportedText(text: try attributedText(of: item, progress: progress)) }
        progress.report(0.5)
        let outputs = try DocumentConverter.export(book.text, for: item, to: format, semanticHTML: true, semanticDOCX: true, progress: progress)
        progress.report(1)
        return outputs
    }
}

/// Hands the imported book from the main thread to the writer; the main thread doesn't touch it afterwards.
private struct ImportedText: @unchecked Sendable {
    let text: NSAttributedString
}
