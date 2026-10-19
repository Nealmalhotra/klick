import AppKit

/// Reads Finder text clippings (`.textClipping`, what you get by dragging selected text to the
/// desktop). Current macOS stores the pasteboard flavors as a property list in the data fork
/// (`UTI-Data` → UTI → data); older clippings keep them as `RTF ` / `utf8` / `utxt` / `TEXT`
/// resources in the resource fork. The richest flavor wins.
enum DocumentClipping {
    static func read(_ url: URL) -> NSAttributedString? {
        if let data = try? Data(contentsOf: url), !data.isEmpty,
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let flavors = plist["UTI-Data"] as? [String: Any] {
            return text(fromFlavors: flavors)
        }
        if let fork = try? Data(contentsOf: url.appendingPathComponent("..namedfork/rsrc")), !fork.isEmpty {
            return text(fromResourceFork: fork)
        }
        return nil
    }

    private static func text(fromFlavors flavors: [String: Any]) -> NSAttributedString? {
        func data(_ type: String) -> Data? {
            switch flavors[type] {
            case let data as Data: return data
            case let string as String: return Data(string.utf8)
            default: return nil
            }
        }
        if let rtf = data("public.rtf"), let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return text
        }
        if let rtfd = data("com.apple.flat-rtfd"), let text = NSAttributedString(rtfd: rtfd, documentAttributes: nil) {
            return text
        }
        if let utf8 = data("public.utf8-plain-text"), let string = String(data: utf8, encoding: .utf8) {
            return plain(string)
        }
        if let utf16 = data("public.utf16-plain-text"), let string = String(data: utf16, encoding: .utf16LittleEndian) {
            return plain(string)
        }
        if let text = flavors["public.plain-text"] as? String { return plain(text) }
        return nil
    }

    private static func plain(_ string: String) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: MarkdownReader.bodyFont])
    }

    // MARK: - Resource fork

    /// Classic resource fork: header (data offset, map offset) → type list → reference lists → data.
    private static func text(fromResourceFork fork: Data) -> NSAttributedString? {
        let bytes = [UInt8](fork)
        func u16(_ at: Int) -> Int? { at + 2 <= bytes.count ? Int(bytes[at]) << 8 | Int(bytes[at + 1]) : nil }
        func u32(_ at: Int) -> Int? {
            guard at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        guard let dataOffset = u32(0), let mapOffset = u32(4),
              let typeListOffset = u16(mapOffset + 24), let typeCount = u16(mapOffset + typeListOffset).map({ $0 + 1 })
        else { return nil }
        let typeList = mapOffset + typeListOffset

        var resources: [String: Data] = [:]
        for index in 0..<typeCount {
            let entry = typeList + 2 + index * 8
            guard entry + 8 <= bytes.count, let referenceOffset = u16(entry + 6) else { break }
            let type = String(bytes: bytes[entry..<entry + 4], encoding: .macOSRoman) ?? ""
            // First resource of each type: 3-byte data offset after id (2), name offset (2), attributes (1).
            let reference = typeList + referenceOffset
            guard let offset = u32(reference + 4).map({ $0 & 0xFFFFFF }), let length = u32(dataOffset + offset) else { continue }
            let start = dataOffset + offset + 4
            guard start + length <= bytes.count else { continue }
            resources[type] = Data(bytes[start..<start + length])
        }
        if let rtf = resources["RTF "], let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            return text
        }
        if let utf8 = resources["utf8"], let string = String(data: utf8, encoding: .utf8) { return plain(string) }
        if let utxt = resources["utxt"], let string = String(data: utxt, encoding: .utf16BigEndian) { return plain(string) }
        if let text = resources["TEXT"], let string = String(data: text, encoding: .macOSRoman) { return plain(string) }
        return nil
    }
}
