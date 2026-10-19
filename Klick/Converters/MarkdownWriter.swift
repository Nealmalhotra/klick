import Foundation

/// Attributed text → CommonMark: headings, emphasis, inline code, links, nested lists, quotes and
/// fenced code blocks. Images have no place to live next to a single `.md`, so they're left out.
enum MarkdownWriter {
    static func markdown(from text: NSAttributedString) -> String {
        var output = ""
        var previous: DocumentBlock.Kind?
        var numbers: [(ordered: Bool, next: Int)] = [] // per list depth
        for block in DocumentBlock.blocks(from: text) {
            var number = 1
            if case .listItem(let ordered, let depth) = block.kind {
                if numbers.count > depth { numbers.removeLast(numbers.count - depth) }
                while numbers.count < depth { numbers.append((ordered, 1)) }
                if numbers[depth - 1].ordered != ordered { numbers[depth - 1] = (ordered, 1) }
                number = numbers[depth - 1].next
                numbers[depth - 1].next += 1
            } else {
                numbers = []
            }
            let line = render(block, number: number)
            guard !line.isEmpty else { continue }
            if let previous {
                // List items stay tight, everything else is separated by a blank line.
                let bothItems = { if case .listItem = previous, case .listItem = block.kind { return true }; return false }()
                output += bothItems ? "\n" : "\n\n"
            }
            output += line
            previous = block.kind
        }
        return output + "\n"
    }

    private static func render(_ block: DocumentBlock, number: Int) -> String {
        switch block.kind {
        case .heading(let level):
            return String(repeating: "#", count: level) + " " + inline(block.runs).replacingOccurrences(of: "\n", with: " ")
        case .paragraph:
            return escapeLineStart(inline(block.runs))
        case .listItem(let ordered, let depth):
            let indent = String(repeating: "    ", count: depth - 1)
            let body = inline(block.runs).replacingOccurrences(of: "\n", with: "\n" + indent + "    ")
            return indent + (ordered ? "\(number). " : "- ") + body
        case .code:
            let code = block.plainText
            let fence = code.contains("```") ? "~~~" : "```"
            return fence + "\n" + code + "\n" + fence
        case .table:
            let columns = block.cells.map(\.count).max() ?? 0
            guard columns > 0 else { return "" }
            // The header row is bold by definition; drop the redundant emphasis.
            var cells = block.cells
            if cells[0].joined().allSatisfy({ $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                cells[0] = cells[0].map { $0.map { var run = $0; run.bold = false; return run } }
            }
            let rows = cells.map { row in
                "| " + (0..<columns).map { column in
                    column < row.count ? inline(row[column]).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\\\n", with: "<br>") : ""
                }.joined(separator: " | ") + " |"
            }
            let rule = "|" + String(repeating: " --- |", count: columns)
            return ([rows[0], rule] + rows.dropFirst()).joined(separator: "\n")
        case .quote:
            return escapeLineStart(inline(block.runs)).split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> " + $0 }.joined(separator: "\n")
        }
    }

    /// Inline runs with emphasis markers kept tight against the words (`**bold** text`, not `** bold **`).
    private static func inline(_ runs: [DocumentBlock.Run]) -> String {
        var output = ""
        for run in runs where run.image == nil {
            var text = run.text.replacingOccurrences(of: "\u{2028}", with: "\n")
            let leading = String(text.prefix { $0 == " " })
            let trailing = String(text.reversed().prefix { $0 == " " })
            text = String(text.dropFirst(leading.count).dropLast(trailing.count))
            guard !text.isEmpty else { output += leading + trailing; continue }

            if run.code {
                let ticks = text.contains("`") ? "``" : "`"
                text = ticks + (text.hasPrefix("`") ? " " : "") + text + (text.hasSuffix("`") ? " " : "") + ticks
            } else {
                text = escape(text).replacingOccurrences(of: "\n", with: "\\\n")
                if run.strike { text = "~~\(text)~~" }
                if run.bold && run.italic {
                    text = "***\(text)***"
                } else if run.bold {
                    text = "**\(text)**"
                } else if run.italic {
                    text = "*\(text)*"
                }
            }
            if let link = run.link {
                let target = link.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
                text = "[\(text)](\(target))"
            }
            output += leading + text + trailing
        }
        return output
    }

    private static func escape(_ text: String) -> String {
        var output = ""
        for character in text {
            if "\\`*_[]<>".contains(character) { output.append("\\") }
            output.append(character)
        }
        return output
    }

    /// Escapes characters that would turn a paragraph into a heading, list or quote.
    private static func escapeLineStart(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            if line.range(of: #"^(#{1,6}\s|[-+]\s|>|\d+[.)]\s)"#, options: .regularExpression) != nil {
                if let digits = line.range(of: #"^\d+"#, options: .regularExpression) {
                    return line[digits] + "\\" + line[digits.upperBound...]
                }
                return "\\" + line
            }
            return line
        }.joined(separator: "\n")
    }
}
