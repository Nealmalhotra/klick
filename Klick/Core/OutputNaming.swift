import Foundation

/// Builds non-destructive, Finder-style output names next to the source file:
/// `Page 001.pdf` → `Page 001.jpg`, `Page 001 Cropped.jpg`, `Page 001 2.jpg` ...
enum OutputNaming {
    /// Output URL in the source folder.
    /// - Parameters:
    ///   - source: the original file.
    ///   - suffix: optional word appended to the base name ("Cropped", "Compressed").
    ///   - ext: extension of the output, without dot.
    static func url(for source: URL, suffix: String? = nil, ext: String) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        let name = [base, suffix].compactMap { $0 }.joined(separator: " ")
        let directory = source.deletingLastPathComponent()
        return unique(directory.appendingPathComponent(name).appendingPathExtension(ext))
    }

    /// Output URL with an explicit file name inside `directory`.
    static func url(named name: String, ext: String, in directory: URL) -> URL {
        unique(directory.appendingPathComponent(name).appendingPathExtension(ext))
    }

    /// Creates (and returns) a fresh folder, e.g. `Page 001 Pages`.
    static func makeFolder(named name: String, in directory: URL) throws -> URL {
        let url = unique(directory.appendingPathComponent(name))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Appends " 2", " 3", ... until the path is free.
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var counter = 2
        while true {
            var candidate = directory.appendingPathComponent("\(base) \(counter)")
            if !ext.isEmpty { candidate = candidate.appendingPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
    }
}
