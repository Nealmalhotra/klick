import Foundation

/// Minimal ZIP container support for the formats built on it (DOCX, PPTX, XLSX,
/// ODS, EPUB…), using the system `zip` / `ditto` tools.
enum ZipPackage {
    /// Writes `entries` (archive path → contents) to `url`.
    /// - Parameter storedFirst: entry written first and uncompressed (EPUB's `mimetype`).
    static func write(_ entries: [String: Data], to url: URL, storedFirst: String? = nil) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("klick-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for (path, data) in entries {
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        try? FileManager.default.removeItem(at: url)
        if let storedFirst {
            try run("/usr/bin/zip", ["-X", "-0", "-q", url.path, storedFirst], in: staging)
        }
        let rest = entries.keys.filter { $0 != storedFirst }.sorted()
        guard !rest.isEmpty else { return }
        try run("/usr/bin/zip", ["-X", "-9", "-q", url.path] + rest, in: staging)
    }

    /// Extracts `url` into a fresh temporary folder and returns it. The caller removes it.
    static func extract(_ url: URL) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("klick-unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            try run("/usr/bin/ditto", ["-x", "-k", url.path, folder.path], in: nil)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw KlickError.unreadable(url.lastPathComponent)
        }
        return folder
    }

    /// Reads one entry without extracting the whole archive, or nil when it's missing.
    static func read(_ entry: String, from url: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    private static func run(_ tool: String, _ arguments: [String], in directory: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw KlickError.failed("\(URL(fileURLWithPath: tool).lastPathComponent) failed (exit code \(process.terminationStatus))")
        }
    }
}
