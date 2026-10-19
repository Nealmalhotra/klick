import AppKit
import PDFKit
import WebKit

/// Renders files macOS can only *preview* — PowerPoint, Keynote and Pages documents — into a PDF
/// with one page per slide/page, using the same Quick Look generators as Finder (`qlmanage -p`).
/// No Office or iWork app needed:
/// * iWork documents come back as one vector PDF per page/slide (or a single `Preview.pdf` for
///   pre-2013 files), which are concatenated.
/// * PowerPoint (and Keynote '09) comes back as HTML with one absolutely positioned `div.slide`
///   (`div.slideStyle`) per slide; each is printed to a PDF page with WebKit.
enum DocumentPreview {
    static func pdf(for item: FileItem, progress: JobProgress) async throws -> PDFDocument {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("klick-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try await runQuickLook(item.url, output: folder, progress: progress)
        progress.report(0.4)
        guard let preview = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "qlpreview" })
        else { throw KlickError.failed("Quick Look couldn't render \(item.name)") }

        let document: PDFDocument?
        let html = preview.appendingPathComponent("Preview.html")
        if let data = try? Data(contentsOf: preview.appendingPathComponent("Preview.pdf")) {
            document = PDFDocument(data: data)
        } else if let source = try? String(contentsOf: html, encoding: .utf8) {
            if source.contains("class=\"slide\"") || source.contains("class=\"slideStyle") {
                document = try await SlideRenderer.render(html, in: preview, progress: progress)
            } else {
                document = concatenatedAttachments(source, in: preview)
            }
        } else {
            document = nil
        }
        guard let document, document.pageCount > 0 else { throw KlickError.failed("Quick Look couldn't render \(item.name)") }
        try progress.checkCancelled()
        return document
    }

    /// The text layer of a rendered document, reflowed into paragraphs: PDF lines are joined again
    /// unless a larger gap or a short line ends the paragraph. Fonts survive.
    static func text(from document: PDFDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let selection = page.selection(for: page.bounds(for: .mediaBox)) else { continue }
            let lines = selection.selectionsByLine().compactMap { line -> (text: NSAttributedString, bounds: CGRect)? in
                guard let text = line.attributedString,
                      !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return (text, line.bounds(for: page))
            }
            let widest = lines.map(\.bounds.width).max() ?? 0
            var previous: CGRect?
            for line in lines {
                let text = NSMutableAttributedString(attributedString: line.text)
                while let last = text.string.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
                    text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                }
                var separator = "\n"
                if let previous, previous.width >= widest * 0.8 {
                    let gap = previous.minY - line.bounds.maxY
                    if gap > -line.bounds.height / 2 && gap < line.bounds.height * 0.5 { separator = " " }
                }
                if result.length > 0 {
                    result.append(NSAttributedString(string: separator, attributes: text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]))
                }
                result.append(text)
                previous = line.bounds
            }
        }
        return result
    }

    /// iWork previews list one PDF per page as `<img src="AttachmentN.pdf">`, in reading order.
    private static func concatenatedAttachments(_ html: String, in folder: URL) -> PDFDocument? {
        let pattern = try? NSRegularExpression(pattern: #"<img[^>]*src="([^"]+\.pdf)""#, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        let files = (pattern?.matches(in: html, range: range) ?? []).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
        let result = PDFDocument()
        for file in files {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)), let part = PDFDocument(data: data) else { continue }
            for index in 0..<part.pageCount {
                if let page = part.page(at: index) { result.insert(page, at: result.pageCount) }
            }
        }
        return result.pageCount > 0 ? result : nil
    }

    /// `qlmanage -p -o <folder> <file>` writes `<file>.qlpreview/` (Preview.html|pdf + attachments).
    private static func runQuickLook(_ url: URL, output: URL, progress: JobProgress) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        process.arguments = ["-p", "-o", output.path, url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(300)
        while process.isRunning {
            if progress.isCancelled || Date() > deadline {
                process.terminate()
                try progress.checkCancelled()
                throw KlickError.failed("Quick Look took too long to render \(url.lastPathComponent)")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Prints each slide `div` of an HTML Quick Look preview to its own PDF page.
@MainActor
private final class SlideRenderer: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?

    static func render(_ html: URL, in folder: URL, progress: JobProgress) async throws -> PDFDocument {
        let renderer = SlideRenderer()
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900), configuration: configuration)
        webView.navigationDelegate = renderer
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            renderer.loaded = continuation
            webView.loadFileURL(html, allowingReadAccessTo: folder)
        }

        // Slide frames in document coordinates (the page stacks them vertically).
        let script = """
        Array.from(document.querySelectorAll('div.slide, div.slideStyle')).map(function (slide) {
            var r = slide.getBoundingClientRect();
            return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height];
        })
        """
        let frames = (try await webView.evaluateJavaScript(script) as? [[Double]] ?? []).filter { $0.count == 4 && $0[2] > 0 && $0[3] > 0 }
        let document = PDFDocument()
        for (index, frame) in frames.enumerated() {
            try progress.checkCancelled()
            let pdf = WKPDFConfiguration()
            pdf.rect = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
            let data = try await webView.pdf(configuration: pdf)
            if let page = PDFDocument(data: data)?.page(at: 0) { document.insert(page, at: document.pageCount) }
            progress.report(0.4 + 0.4 * Double(index + 1) / Double(frames.count))
        }
        return document
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }
}
