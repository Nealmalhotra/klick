import Foundation

/// Semantic, well-formed XHTML from `DocumentBlock`s (`<h1>`, `<p>`, nested `<ul>/<ol>`, `<pre>`,
/// `<blockquote>`, `<strong>`, `<a>`, `<img/>`). Used for EPUB chapters and clean HTML output.
enum DocumentHTMLWriter {
    /// Where an image goes: returns the `src` for its data (a file inside the EPUB, or a data URI).
    typealias ImageSource = (_ data: Data, _ ext: String) -> String

    /// Body markup for `blocks`. Headings get `id="h<index>"` (index into `blocks`) for navigation.
    static func body(_ blocks: [DocumentBlock], indices: Range<Int>? = nil, image: ImageSource) -> String {
        var html = ""
        var openLists: [Bool] = [] // ordered flag per open list; each has an open <li>
        func tag(_ ordered: Bool) -> String { ordered ? "ol" : "ul" }
        func closeLists(to depth: Int) {
            while openLists.count > depth { html += "</li></\(tag(openLists.removeLast()))>\n" }
        }

        for index in indices ?? blocks.indices {
            let block = blocks[index]
            let content = inline(block.runs, image: image)
            switch block.kind {
            case .listItem(let ordered, let depth):
                closeLists(to: depth)
                if openLists.count == depth {
                    if openLists.last == ordered {
                        html += "</li>\n"
                    } else {
                        closeLists(to: depth - 1)
                    }
                }
                while openLists.count < depth {
                    if openLists.count == depth - 1 {
                        html += "<\(tag(ordered))>\n"
                        openLists.append(ordered)
                    } else {
                        html += "<ul>\n<li>" // skipped nesting levels
                        openLists.append(false)
                    }
                }
                html += "<li>" + content
            case .heading(let level):
                closeLists(to: 0)
                html += "<h\(level) id=\"h\(index)\">\(content)</h\(level)>\n"
            case .paragraph:
                closeLists(to: 0)
                html += "<p>\(content)</p>\n"
            case .code:
                closeLists(to: 0)
                html += "<pre><code>\(escape(block.plainText))</code></pre>\n"
            case .table:
                closeLists(to: 0)
                html += "<table>\n"
                for (row, cells) in block.cells.enumerated() {
                    // The first row is a header when it's set in bold (as Markdown and most documents do).
                    let header = row == 0 && cells.joined().contains { !$0.text.isEmpty } && cells.joined().allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                    let tag = header ? "th" : "td"
                    html += "<tr>" + cells.map { "<\(tag)>\(inline($0.map { var run = $0; if header { run.bold = false }; return run }, image: image))</\(tag)>" }.joined() + "</tr>\n"
                }
                html += "</table>\n"
            case .quote:
                closeLists(to: 0)
                html += "<blockquote><p>\(content)</p></blockquote>\n"
            }
        }
        closeLists(to: 0)
        return html
    }

    /// A standalone HTML5 page with images embedded as data URIs.
    static func page(_ blocks: [DocumentBlock], title: String) -> String {
        let body = body(blocks) { data, ext in
            "data:\(mimeType(ext));base64,\(data.base64EncodedString())"
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    static let stylesheet = """
    body { font-family: -apple-system, Helvetica, sans-serif; line-height: 1.5; max-width: 42em; margin: 2em auto; padding: 0 1em; }
    img { max-width: 100%; height: auto; }
    pre { background: #f4f4f4; padding: 0.75em; overflow-x: auto; white-space: pre-wrap; }
    code { font-family: Menlo, monospace; font-size: 0.9em; }
    blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #ccc; color: #555; }
    table { border-collapse: collapse; } th, td { border: 1px solid #ccc; padding: 0.3em 0.6em; text-align: left; }
    """

    static func mimeType(_ ext: String) -> String {
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }

    static func escape(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            // Control characters are invalid in XML.
            case "\t", "\n", "\r": output.unicodeScalars.append(scalar)
            case _ where scalar.value < 0x20 || scalar.value == 0xFFFE || scalar.value == 0xFFFF: continue
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }

    private static func inline(_ runs: [DocumentBlock.Run], image: ImageSource) -> String {
        var html = ""
        for run in runs {
            if let picture = run.image {
                html += "<img src=\"\(escape(image(picture.data, picture.ext)))\" alt=\"\"/>"
                continue
            }
            var text = escape(run.text)
                .replacingOccurrences(of: "\u{2028}", with: "<br/>")
                .replacingOccurrences(of: "\n", with: "<br/>")
            if run.code { text = "<code>\(text)</code>" }
            if run.italic { text = "<em>\(text)</em>" }
            if run.bold { text = "<strong>\(text)</strong>" }
            if run.strike { text = "<del>\(text)</del>" }
            if let link = run.link { text = "<a href=\"\(escape(link.absoluteString))\">\(text)</a>" }
            html += text
        }
        return html
    }
}
