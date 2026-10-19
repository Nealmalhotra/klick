import Foundation

/// Archive targets offered on the archive wheel. GZIP means a gzipped tarball (`Name.tar.gz`), like Tangerine.
enum ArchiveFormat: String, CaseIterable {
    case zip, tar, gzip

    var title: String { rawValue.uppercased() }

    var ext: String {
        switch self {
        case .zip: return "zip"
        case .tar: return "tar"
        case .gzip: return "tar.gz"
        }
    }

    /// The format a source archive already is, so the wheel doesn't offer it.
    init?(sourceExtension ext: String) {
        switch ext {
        case "zip": self = .zip
        case "tar": self = .tar
        case "gz", "tgz": self = .gzip
        default: return nil
        }
    }
}

/// Extracts and re-packs archives with the system tools only: `bsdtar` (libarchive reads zip, tar,
/// gzip, bzip2, xz, rar and 7z), `ditto` for zip, and `gzip`/`bzip2` for single compressed files.
enum ArchiveConverter {
    /// Double extensions stripped as a whole, so `Site.tar.gz` is called `Site`.
    private static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst"]

    /// `Photos.zip` → `Photos.tar.gz`: extracts to a temporary folder, then packs its contents.
    static func convert(_ item: FileItem, to format: ArchiveFormat, progress: JobProgress) throws -> URL {
        progress.report(0.05)
        let staging = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        try extract(item, into: staging, progress: progress)
        let entries = try topLevelEntries(of: staging, archive: item)
        progress.report(0.5)

        let output = uniqueURL(named: baseName(of: item), ext: format.ext, in: item.directory)
        switch format {
        case .zip:
            // Plain zip without AppleDouble/quarantine extras, contents at the archive root.
            try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", staging.path, output.path],
                    cleanup: output, progress: progress)
        case .tar, .gzip:
            let compression = format == .gzip ? ["-z"] : []
            try run("/usr/bin/bsdtar", ["-c"] + compression + ["-f", output.path, "--no-mac-metadata", "-C", staging.path, "--"] + entries,
                    cleanup: output, progress: progress)
        }
        progress.report(1)
        return output
    }

    /// Extracts next to the archive. A single top-level item (folder or file) lands directly
    /// (`Project.zip` → `Project`), several go into a folder named after the archive; nothing is overwritten.
    static func extract(_ item: FileItem, progress: JobProgress) throws -> URL {
        progress.report(0.05)
        // Same volume as the destination, so the final move is instant.
        let sameVolume = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: item.url, create: true)
        let staging = try sameVolume ?? temporaryFolder()
        defer { try? FileManager.default.removeItem(at: staging) }
        try extract(item, into: staging, progress: progress)
        let entries = try topLevelEntries(of: staging, archive: item)
        progress.report(0.9)

        let fm = FileManager.default
        do {
            if entries.count == 1 {
                let output = OutputNaming.unique(item.directory.appendingPathComponent(entries[0]))
                try fm.moveItem(at: staging.appendingPathComponent(entries[0]), to: output)
                progress.report(1)
                return output
            }
            let folder = try OutputNaming.makeFolder(named: baseName(of: item), in: item.directory)
            for entry in entries {
                try fm.moveItem(at: staging.appendingPathComponent(entry), to: folder.appendingPathComponent(entry))
            }
            progress.report(1)
            return folder
        } catch {
            throw KlickError.failed("Couldn't extract \(item.name) here")
        }
    }

    // MARK: - Helpers

    /// `Site.tar.gz` → `Site`, `notes.txt.gz` → `notes.txt`, `Photos.zip` → `Photos`.
    static func baseName(of item: FileItem) -> String {
        let name = item.name
        for ext in compoundExtensions where name.lowercased().hasSuffix("." + ext) {
            return String(name.dropLast(ext.count + 1))
        }
        return item.baseName
    }

    /// Unpacks into `folder`. Zip goes through `ditto` (like Archive Utility), everything else through
    /// `bsdtar`; plain `.gz`/`.bz2`/`.xz` files that aren't tarballs are decompressed as a single file.
    private static func extract(_ item: FileItem, into folder: URL, progress: JobProgress) throws {
        if item.ext == "zip" {
            do {
                try run("/usr/bin/ditto", ["-x", "-k", item.url.path, folder.path], cleanup: nil, progress: progress)
                return
            } catch KlickError.cancelled {
                throw KlickError.cancelled
            } catch {
                try clear(folder) // fall through to bsdtar, which knows more zip variants
            }
        }
        do {
            // A dummy passphrase makes encrypted archives fail right away instead of prompting on a terminal.
            try run("/usr/bin/bsdtar", ["-x", "--passphrase", "klick-no-password", "-f", item.url.path, "-C", folder.path],
                    cleanup: nil, progress: progress)
        } catch KlickError.failed(let message) {
            try clear(folder)
            let lowercased = message.lowercased()
            if ["passphrase", "password", "encrypted"].contains(where: lowercased.contains) {
                throw KlickError.failed("\(item.name) is password-protected")
            }
            guard ["gz", "bz2", "xz"].contains(item.ext), try decompressSingleFile(item, into: folder, progress: progress) else {
                throw KlickError.failed("\(item.name) is damaged or not a supported archive")
            }
        }
    }

    /// `notes.txt.gz` → `notes.txt`. Returns false when the file isn't a compressed stream either.
    private static func decompressSingleFile(_ item: FileItem, into folder: URL, progress: JobProgress) throws -> Bool {
        let output = folder.appendingPathComponent(item.baseName.isEmpty ? "Untitled" : item.baseName)
        switch item.ext {
        case "gz", "bz2":
            let tool = item.ext == "gz" ? "/usr/bin/gzip" : "/usr/bin/bzip2"
            FileManager.default.createFile(atPath: output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            do {
                try run(tool, ["-d", "-c", item.url.path], cleanup: nil, progress: progress, standardOutput: handle)
            } catch KlickError.cancelled {
                throw KlickError.cancelled
            } catch {
                return false
            }
            return true
        case "xz":
            // The Compression framework's LZMA codec reads the .xz container.
            guard let data = try? Data(contentsOf: item.url),
                  let decompressed = try? (data as NSData).decompressed(using: .lzma) as Data else { return false }
            try decompressed.write(to: output)
            return true
        default:
            return false
        }
    }

    /// What the archive holds at its root, minus Finder/Archive Utility leftovers.
    private static func topLevelEntries(of folder: URL, archive item: FileItem) throws -> [String] {
        let fm = FileManager.default
        try? fm.removeItem(at: folder.appendingPathComponent("__MACOSX"))
        try? fm.removeItem(at: folder.appendingPathComponent(".DS_Store"))
        let entries = (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []
        guard !entries.isEmpty else { throw KlickError.failed("\(item.name) is empty") }
        return entries
    }

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("klick-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func clear(_ folder: URL) throws {
        let fm = FileManager.default
        for entry in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: entry)
        }
    }

    /// `Name.tar.gz`, `Name 2.tar.gz`, ... (`OutputNaming.unique` would split the double extension).
    private static func uniqueURL(named name: String, ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(name).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Runs a tool to completion, terminating it if the job is cancelled. On failure `cleanup` is removed
    /// and the tool's last error line becomes the message (e.g. a wrong password or a damaged archive).
    private static func run(
        _ tool: String, _ arguments: [String], cleanup: URL?, progress: JobProgress, standardOutput: FileHandle? = nil
    ) throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("klick-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput ?? FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: log)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        while exited.wait(timeout: .now() + 0.2) == .timedOut {
            if progress.isCancelled { process.terminate() }
        }
        if progress.isCancelled {
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            throw KlickError.cancelled
        }
        guard process.terminationStatus == 0 else {
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            let errors = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let message = errors.split(whereSeparator: \.isNewline).last { !$0.contains("Error exit delayed") }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw KlickError.failed(message.isEmpty ? "\(name) failed (exit code \(process.terminationStatus))" : message)
        }
    }
}
