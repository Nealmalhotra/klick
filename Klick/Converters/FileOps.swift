import AppKit

/// Generic file operations: archives, disk images, duplicates, AirDrop, paths and Terminal.
enum FileOps {
    /// Like Finder's Compress: one item → `Folder.zip` / `Photo.jpg.zip`, several → `Archive.zip`
    /// next to the first item. Paths inside the archive are relative to the folder holding the selection.
    static func zip(_ items: [FileItem], progress: JobProgress) throws -> [URL] {
        guard let first = items.first else { throw KlickError.failed("Nothing to compress") }
        progress.report(0.05)
        if items.count == 1 {
            let output = OutputNaming.url(named: first.name, ext: "zip", in: first.directory)
            // --keepParent stores a folder as `Folder/...`; a single file goes at the archive root.
            let options = ["-c", "-k", "--sequesterRsrc"] + (first.isDirectory ? ["--keepParent"] : [])
            try run("/usr/bin/ditto", options + [first.url.path, output.path], output: output, progress: progress)
            return [output]
        }
        let root = commonAncestor(of: items.map(\.directory))
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // "./" keeps names starting with "-" from being read as options.
        let paths = items.map { "./" + $0.url.path.dropFirst(rootPath.count) }
        let output = OutputNaming.url(named: "Archive", ext: "zip", in: first.directory)
        try run("/usr/bin/zip", ["-r", "-y", "-q", output.path] + paths, in: root, output: output, progress: progress)
        return [output]
    }

    /// `Folder` → `Folder.dmg`: a compressed, read-only (UDZO) disk image named after the folder.
    static func diskImage(_ item: FileItem, progress: JobProgress) throws -> URL {
        progress.report(0.05)
        let output = OutputNaming.url(named: item.name, ext: "dmg", in: item.directory)
        try run("/usr/bin/hdiutil", [
            "create", "-volname", item.name, "-srcfolder", item.url.path, "-format", "UDZO", "-ov", output.path,
        ], output: output, progress: progress)
        return output
    }

    /// Finder-style copy next to the original: `Photo copy.jpg`, then `Photo copy 2.jpg`, ...
    static func duplicate(_ item: FileItem, progress: JobProgress) throws -> URL {
        let output = item.isDirectory && !item.isPackage
            ? OutputNaming.unique(item.directory.appendingPathComponent("\(item.name) copy"))
            : OutputNaming.url(for: item.url, suffix: "copy", ext: item.url.pathExtension)
        do {
            try FileManager.default.copyItem(at: item.url, to: output) // clones on APFS
        } catch {
            throw KlickError.failed("Couldn't duplicate \(item.name)")
        }
        progress.report(1)
        return output
    }

    @MainActor static func airDrop(_ items: [FileItem]) {
        let urls = items.map(\.url)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            NSSound.beep()
            return
        }
        NSApp.activate() // menu-bar app: bring the AirDrop sheet to the front
        service.perform(withItems: urls)
    }

    /// Puts the files themselves on the clipboard, ready to paste in Finder or another app.
    @MainActor static func copyToClipboard(_ items: [FileItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items.map { $0.url as NSURL })
    }

    /// Asks for a destination folder, then moves the originals there (never overwriting).
    @MainActor static func move(_ items: [FileItem]) {
        guard let first = items.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = items.count == 1 ? "Move “\(first.name)” to…" : "Move \(items.count) items to…"
        panel.directoryURL = first.directory
        NSApp.activate()
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        var moved = 0
        var failure: String?
        for item in items {
            let target = OutputNaming.unique(destination.appendingPathComponent(item.name))
            guard target.deletingLastPathComponent().standardizedFileURL != item.directory.standardizedFileURL else { continue }
            do {
                try FileManager.default.moveItem(at: item.url, to: target)
                moved += 1
            } catch {
                failure = "Couldn't move \(item.name)"
            }
        }
        if let failure, moved == 0 {
            Feedback.shared.failure()
            Toast.shared.showMessage(failure, symbol: "exclamationmark.triangle.fill")
        } else if moved > 0 {
            Feedback.shared.success()
            Toast.shared.showMessage(moved == 1 ? "Moved to \(destination.lastPathComponent)" : "\(moved) items moved to \(destination.lastPathComponent)")
        }
    }

    @MainActor static func copyPaths(_ items: [FileItem]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items.map(\.url.path).joined(separator: "\n"), forType: .string)
    }

    /// Opens a Terminal window in the folder (or in the file's enclosing folder).
    @MainActor static func openTerminal(at item: FileItem) {
        let folder = item.isDirectory && !item.isPackage ? item.url : item.directory
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("%@", "Klick: couldn't open Terminal at \(folder.path): \(error)") }
        }
    }

    // MARK: - Helpers

    /// Runs a command-line tool to completion, terminating it if the job is cancelled. On failure the
    /// partial `output` is removed and a non-zero exit status becomes `KlickError.failed` with the tool's last error line.
    private static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil, output: URL, progress: JobProgress) throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("klick-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: log)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        while exited.wait(timeout: .now() + 0.2) == .timedOut {
            if progress.isCancelled { process.terminate() }
        }
        if progress.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw KlickError.cancelled
        }
        guard process.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: output)
            // The last line carries the actual error (hdiutil prints a deprecation warning first on macOS 27).
            let errors = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let message = errors.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let name = URL(fileURLWithPath: tool).lastPathComponent
            throw KlickError.failed(message.isEmpty ? "\(name) failed (exit code \(process.terminationStatus))" : message)
        }
        progress.report(1)
    }

    /// Deepest folder containing all of `directories`.
    private static func commonAncestor(of directories: [URL]) -> URL {
        let paths = directories.map { $0.standardizedFileURL.pathComponents }
        guard var common = paths.first else { return URL(fileURLWithPath: "/") }
        for components in paths.dropFirst() {
            common = Array(Swift.zip(common, components).prefix { $0 == $1 }.map(\.0))
        }
        return URL(fileURLWithPath: NSString.path(withComponents: common.isEmpty ? ["/"] : common), isDirectory: true)
    }
}
