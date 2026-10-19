import AppKit

/// Developer hooks used for automated testing:
///
/// * `Klick --list-actions <files…>` prints the wheel pages for a selection.
/// * `Klick --run-action <id> <files…>` runs an action headlessly and prints outputs.
/// * While running, a distributed notification `io.exastudio.klick.debug`
///   (userInfo: cmd, paths, x, y, index, pane) drives the UI — see `scripts/klickctl`.
@MainActor
enum DebugCommands {
    /// `--debug-channel <name>` isolates several running copies during development.
    static var notificationName: Notification.Name {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--debug-channel"), args.count > i + 1 {
            return Notification.Name("io.exastudio.klick.debug.\(args[i + 1])")
        }
        return Notification.Name("io.exastudio.klick.debug")
    }

    /// Returns true when the process was launched in a CLI mode (normal startup is skipped).
    static func handleLaunchArguments() -> Bool {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--list-actions") {
            let items = args[(i + 1)...].map { FileItem(url: URL(fileURLWithPath: $0)) }
            for page in ActionCatalog.pages(for: items) {
                print("[\(page.title)] " + page.actions.map { "\($0.id)=\($0.title)" }.joined(separator: "  "))
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--run-action"), args.count > i + 2 {
            let id = args[i + 1]
            let items = args[(i + 2)...].map { FileItem(url: URL(fileURLWithPath: $0)) }
            runHeadless(actionID: id, items: items)
            return true
        }
        return false
    }

    private static func runHeadless(actionID: String, items: [FileItem]) {
        guard let action = ActionCatalog.action(id: actionID, for: items) else {
            FileHandle.standardError.write("Unknown action \(actionID) for selection\n".data(using: .utf8)!)
            exit(2)
        }
        Task {
            do {
                var outputs: [URL] = []
                switch action.kind {
                case .perFile(_, let work):
                    for item in items { outputs += try await work(item, JobProgress()) }
                case .batch(_, let work):
                    outputs = try await work(items, JobProgress())
                case .editor, .instant:
                    FileHandle.standardError.write("\(actionID) is interactive\n".data(using: .utf8)!)
                    exit(3)
                }
                for url in outputs { print(url.path) }
                exit(0)
            } catch {
                FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    private static func debugFlags(_ mods: String) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mods.contains("shift") { flags.insert(.maskShift) }
        if mods.contains("cmd") { flags.insert(.maskCommand) }
        if mods.contains("ctrl") { flags.insert(.maskControl) }
        if mods.contains("opt") { flags.insert(.maskAlternate) }
        return flags
    }

    // MARK: In-process input (no Accessibility needed: events only reach Klick's own windows)

    private static func postKey(code: UInt16, chars: String, modifiers: String) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) else { return }
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains("shift") { flags.insert(.shift) }
        if modifiers.contains("cmd") { flags.insert(.command) }
        if modifiers.contains("opt") { flags.insert(.option) }
        if modifiers.contains("ctrl") { flags.insert(.control) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func postDrag(from start: NSPoint, to end: NSPoint, steps: Int) {
        guard let window = NSApp.windows.reversed().first(where: { $0.isVisible && $0.frame.contains(start) }) else {
            NSLog("%@", "Klick debug: no window at \(start)")
            return
        }
        func post(_ type: NSEvent.EventType, _ global: NSPoint) {
            let local = window.convertPoint(fromScreen: global)
            if let event = NSEvent.mouseEvent(
                with: type, location: local, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        post(.leftMouseDown, start)
        for i in stride(from: 1, through: steps, by: 1) {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
        }
        post(.leftMouseUp, end)
    }

    // MARK: Backdrop

    /// A plain window showing an image (e.g. the wallpaper from the reference video)
    /// so screenshots of the wheel can be compared against the original.
    private static var backdrop: NSWindow?

    private static func showBackdrop(path: String?, center: NSPoint, width: Double) {
        guard let path, let image = NSImage(contentsOfFile: path) else { return }
        let height = width * image.size.height / max(image.size.width, 1)
        let frame = NSRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let window = backdrop ?? NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(frame, display: true)
        window.level = .floating
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
        backdrop = window
    }

    // MARK: Live commands

    private final class Observer: NSObject {
        @objc func received(_ note: Notification) {
            let info = note.userInfo as? [String: Any] ?? [:]
            MainActor.assumeIsolated { DebugCommands.handle(info) }
        }
    }

    private static let observer = Observer()

    static func startListening() {
        DistributedNotificationCenter.default().addObserver(
            observer, selector: #selector(Observer.received(_:)), name: notificationName, object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    fileprivate static func handle(_ info: [String: Any]) {
        let cmd = info["cmd"] as? String ?? ""
        let paths = (info["paths"] as? String)?.split(separator: "\n").map(String.init) ?? []
        let items = paths.map { FileItem(url: URL(fileURLWithPath: $0)) }
        let point: NSPoint = {
            if let x = (info["x"] as? String).flatMap(Double.init), let y = (info["y"] as? String).flatMap(Double.init) {
                return NSPoint(x: x, y: y)
            }
            return NSEvent.mouseLocation
        }()
        let index = (info["index"] as? String).flatMap(Int.init)

        switch cmd {
        case "open":
            WheelController.shared.present(
                items: items, at: point, wheel: (info["wheel"] as? String).flatMap(WheelKind.init(rawValue:)),
                initialPage: index ?? 0, dragging: info["dragging"] != nil
            )
        case "hover":
            WheelController.shared.setHovered(index)
        case "page":
            WheelController.shared.flipPage(by: index ?? 1)
        case "commit":
            Toast.anchorOverride = info["x"] != nil ? point : nil
            WheelController.shared.commit()
        case "cancel":
            WheelController.shared.cancel()
        case "run":
            EditorWindowController.anchorOverride = info["x"] != nil ? point : nil
            if let id = info["action"] as? String, let action = ActionCatalog.action(id: id, for: items) {
                ActionRunner.run(action, on: items)
            }
        case "settings":
            SettingsWindowController.shared.show(pane: (info["pane"] as? String).flatMap(SettingsPane.init(rawValue:)))
            if info["x"] != nil, let window = SettingsWindowController.shared.window {
                if let w = (info["w"] as? String).flatMap(Double.init), let h = (info["h"] as? String).flatMap(Double.init) {
                    window.setContentSize(NSSize(width: w, height: h))
                }
                window.setFrameTopLeftPoint(point)
            }
        case "toast":
            Toast.shared.showMessage(info["text"] as? String ?? "Hello from Klick", at: point)
        case "jobtoast":
            let handle = Toast.shared.begin(title: info["text"] as? String ?? "Converting to JPG", subtitle: "Page 001.pdf", at: point) {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { handle.update(progress: 0.6) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { handle.succeed(subtitle: "1 of 1 saved") }
        case "backdrop":
            showBackdrop(path: info["path"] as? String, center: point, width: (info["w"] as? String).flatMap(Double.init) ?? 900)
        case "nobackdrop":
            backdrop?.orderOut(nil)
            backdrop = nil
        case "appearance":
            switch info["value"] as? String {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
        case "trigger":
            let monitor = HotkeyMonitor.shared
            monitor.debugAnchor = info["x"] != nil ? point : nil
            Toast.anchorOverride = monitor.debugAnchor
            if !items.isEmpty { monitor.debugSelection = items.map(\.url) }
            switch info["value"] as? String {
            case "down": monitor.debugFlags = debugFlags(info["mods"] as? String ?? "shift")
            case "up": monitor.debugFlags = []
            default: monitor.debugFlags = nil; monitor.debugSelection = nil; monitor.debugDrag = nil
            }
        case "dragfiles":
            // Simulates a file drag in progress (value=end stops it); combine with `trigger`.
            let monitor = HotkeyMonitor.shared
            monitor.debugAnchor = info["x"] != nil ? point : nil
            Toast.anchorOverride = monitor.debugAnchor
            monitor.debugDrag = info["value"] as? String == "end" ? nil : items.map(\.url)
        case "drop":
            Toast.anchorOverride = point
            _ = WheelController.shared.drop(at: point)
        case "key":
            postKey(code: UInt16((info["code"] as? String).flatMap(Int.init) ?? 36),
                    chars: info["chars"] as? String ?? "",
                    modifiers: info["mods"] as? String ?? "")
        case "click":
            postDrag(from: point, to: point, steps: 0)
        case "drag":
            let to = NSPoint(x: (info["x2"] as? String).flatMap(Double.init) ?? point.x,
                             y: (info["y2"] as? String).flatMap(Double.init) ?? point.y)
            postDrag(from: point, to: to, steps: (info["steps"] as? String).flatMap(Int.init) ?? 12)
        case "quit":
            NSApp.terminate(nil)
        default:
            NSLog("%@", "Klick debug: unknown command \(cmd)")
        }
    }
}
