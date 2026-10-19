import Foundation

/// Subtitle targets offered on the subtitle wheel.
enum SubtitleFormat: String, CaseIterable {
    case srt, vtt, txt

    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }
}

/// SRT ↔ WebVTT, plus TXT (just the dialogue). Tolerates BOMs, CRLF, legacy encodings, missing
/// cue numbers, `,` or `.` milliseconds, VTT headers/NOTE/STYLE/REGION blocks and cue settings.
/// Basic styling (`<b>`, `<i>`, `<u>`) survives SRT ↔ VTT; other tags are dropped.
enum SubtitleConverter {
    struct Cue {
        var start: Int // milliseconds
        var end: Int
        var text: String
    }

    /// `Movie.srt` → `Movie.vtt`.
    static func convert(_ item: FileItem, to format: SubtitleFormat, progress: JobProgress) throws -> URL {
        progress.report(0.1)
        guard let data = try? Data(contentsOf: item.url), let source = SpreadsheetCSV.decode(data) else {
            throw KlickError.unreadable(item.name)
        }
        let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let isVTT = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
        let cues = parse(text, vtt: isVTT)
        guard !cues.isEmpty else { throw KlickError.failed("No subtitles found in \(item.name)") }
        try progress.checkCancelled()
        progress.report(0.6)

        let output: String
        switch format {
        case .srt: output = srt(cues, fromVTT: isVTT)
        case .vtt: output = vtt(cues, fromVTT: isVTT)
        case .txt: output = plainText(cues)
        }
        let url = OutputNaming.url(for: item.url, ext: format.ext)
        do {
            try Data(output.utf8).write(to: url, options: .atomic)
        } catch {
            throw KlickError.failed("Couldn't write \(url.lastPathComponent)")
        }
        progress.report(1)
        return url
    }

    // MARK: - Parsing

    /// Splits into blank-line separated blocks; a block is a cue when one of its lines is a timing line.
    static func parse(_ text: String, vtt: Bool) -> [Cue] {
        var cues: [Cue] = []
        let blocks = text.components(separatedBy: "\n").split { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        for (index, block) in blocks.enumerated() {
            let lines = Array(block)
            if vtt {
                if index == 0, lines[0].hasPrefix("WEBVTT") { continue }
                let keyword = lines[0].split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if ["NOTE", "STYLE", "REGION"].contains(keyword) && !lines[0].contains("-->") { continue }
            }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = timing(lines[timingIndex]) else { continue }
            let body = lines[(timingIndex + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }
            cues.append(Cue(start: start, end: end, text: body.joined(separator: "\n")))
        }
        return cues
    }

    /// `00:01:02,500 --> 00:01:04.000 align:start` → milliseconds (hours optional, `,` or `.`).
    private static func timing(_ line: String) -> (Int, Int)? {
        let sides = line.components(separatedBy: "-->")
        guard sides.count == 2,
              let start = timestamp(sides[0].trimmingCharacters(in: .whitespaces)),
              let endToken = sides[1].split(whereSeparator: \.isWhitespace).first,
              let end = timestamp(String(endToken)) else { return nil }
        return (start, end)
    }

    private static func timestamp(_ string: String) -> Int? {
        let parts = string.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let secondsParts = parts[parts.count - 1].split(separator: ".", omittingEmptySubsequences: false)
        guard let seconds = Int(secondsParts[0]) else { return nil }
        var milliseconds = 0
        if secondsParts.count > 1 {
            let digits = String(secondsParts[1].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            guard let value = Int(digits) else { return nil }
            milliseconds = value
        }
        guard let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours else { return nil }
        return ((hours * 60 + minutes) * 60 + seconds) * 1000 + milliseconds
    }

    // MARK: - Writing

    private static func srt(_ cues: [Cue], fromVTT: Bool) -> String {
        var output = ""
        var number = 0
        for cue in cues {
            let text = fromVTT ? convertTags(cue.text, keep: true, escapeForVTT: false) : cue.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            number += 1
            output += "\(number)\n\(format(cue.start, separator: ",")) --> \(format(cue.end, separator: ","))\n\(text)\n\n"
        }
        return output
    }

    private static func vtt(_ cues: [Cue], fromVTT: Bool) -> String {
        var output = "WEBVTT\n\n"
        for cue in cues {
            var text = fromVTT ? cue.text : convertTags(cue.text, keep: true, escapeForVTT: true)
            text = text.replacingOccurrences(of: "-->", with: "->") // not allowed inside a VTT cue
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            output += "\(format(cue.start, separator: ".")) --> \(format(cue.end, separator: "."))\n\(text)\n\n"
        }
        return output
    }

    /// Dialogue only: no numbers, timings or tags; repeated lines (rolling captions) appear once.
    private static func plainText(_ cues: [Cue]) -> String {
        var lines: [String] = []
        for cue in cues {
            let text = convertTags(cue.text, keep: false, escapeForVTT: false)
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != lines.last else { continue }
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ milliseconds: Int, separator: String) -> String {
        let value = max(milliseconds, 0)
        return String(format: "%02d:%02d:%02d%@%03d", value / 3_600_000, value / 60_000 % 60, value / 1000 % 60, separator, value % 1000)
    }

    // MARK: - Tags

    /// Rewrites cue markup: keeps `<b>`/`<i>`/`<u>` when `keep`, drops every other tag (`<font>`, `<v>`,
    /// `<c.class>`, karaoke timestamps, ASS `{\an8}` overrides), decodes entities, and re-escapes `&`/`<`/`>` for VTT.
    static func convertTags(_ text: String, keep: Bool, escapeForVTT: Bool) -> String {
        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].firstIndex(of: ">") {
                let inner = text[text.index(after: index)..<close]
                if let tag = tagName(inner) {
                    if keep, ["b", "i", "u"].contains(tag) {
                        output += inner.hasPrefix("/") ? "</\(tag)>" : "<\(tag)>"
                    }
                    index = text.index(after: close)
                    continue
                }
            }
            if character == "{", text[index...].dropFirst().first == "\\", let close = text[index...].firstIndex(of: "}") {
                index = text.index(after: close)
                continue
            }
            if character == "&", let semicolon = text[index...].prefix(10).firstIndex(of: ";"),
               let decoded = entity(String(text[text.index(after: index)..<semicolon])) {
                output += escapeForVTT ? escape(decoded) : decoded
                index = text.index(after: semicolon)
                continue
            }
            output += escapeForVTT ? escape(String(character)) : String(character)
            index = text.index(after: index)
        }
        return output
    }

    /// Lowercased tag name for things that look like markup (`i`, `/i`, `font color=…`, `v Bob`, `c.red`, `00:01.000`).
    private static func tagName(_ inner: Substring) -> String? {
        let body = inner.hasPrefix("/") ? inner.dropFirst() : inner
        guard let first = body.first else { return nil }
        if first.isNumber { return body.contains(":") && body.allSatisfy({ $0.isNumber || $0 == ":" || $0 == "." }) ? "timestamp" : nil }
        guard first.isLetter else { return nil }
        let name = body.prefix { $0.isLetter || $0.isNumber }
        return name.lowercased()
    }

    private static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        case "lrm": return "\u{200E}"
        case "rlm": return "\u{200F}"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let code = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return code.flatMap(UnicodeScalar.init).map { String(Character($0)) }
        }
    }

    private static func escape(_ string: String) -> String {
        switch string {
        case "&": return "&amp;"
        case "<": return "&lt;"
        case ">": return "&gt;"
        default: return string.count == 1 ? string : string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
    }
}
