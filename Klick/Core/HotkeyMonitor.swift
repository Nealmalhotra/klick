import AppKit
import CoreGraphics

/// Watches the trigger modifiers GTA-style. Each wheel has its own key (by default
/// Shift → Convert, Command → Tools, Control → File actions):
///
/// * hold a key with files selected in Finder → its wheel appears; release → commit;
/// * while dragging files, tap a key → the wheel appears under the drag and stays
///   until the files are dropped on an action (or the drag ends elsewhere).
///
/// While the wheel is open, pressing another wheel's key switches to that wheel.
///
/// It needs no Accessibility / Input Monitoring permission: modifier state and
/// "time since last key/mouse event" are read from the HID session state.
/// Using a trigger for typing (Shift+A) or clicking cancels the gesture.
@MainActor
final class HotkeyMonitor {
    static let shared = HotkeyMonitor()

    private enum Phase {
        case idle
        /// A trigger is down, waiting for the hold delay.
        case armed(WheelKind)
        /// Wheel is on screen: while a trigger is held, or for the rest of a drag.
        case open(dragging: Bool)
        /// Gesture was used for something else; wait for full release.
        case consumed
    }

    private var phase: Phase = .idle
    private var timer: Timer?
    private var currentInterval: TimeInterval = 0
    private var monitors: [Any] = []
    /// Keeps App Nap from throttling the polling timer (which would make the wheel feel laggy).
    private var activity: NSObjectProtocol?

    private var previousFlags: CGEventFlags = []
    private var armedAt: CFAbsoluteTime = 0
    private var armedMouse: NSPoint = .zero
    private var selectionRequest = 0
    private var selection: Result<[URL], Error>?
    private var permissionHintShown = false
    /// Drag pasteboard generation when the mouse last went down: a newer one means a drag started since.
    private var dragChangeCountAtMouseDown: Int?

    private let settings = AppSettings.shared

    // Debug hooks: simulate the trigger, the Finder selection and drags (used by `klickctl`).
    var debugFlags: CGEventFlags?
    var debugSelection: [URL]?
    var debugAnchor: NSPoint?
    /// Files of a simulated drag in progress; nil ends it.
    var debugDrag: [URL]?

    private static let idleInterval: TimeInterval = 1.0 / 20.0
    private static let activeInterval: TimeInterval = 1.0 / 120.0
    /// Cursor travel during the hold that means "I'm shift-clicking", not "open the wheel".
    private static let maxArmTravel: CGFloat = 70
    /// Command and Control start shortcuts; holding them a little longer avoids surprise wheels.
    private static let shortcutModifierDelay: TimeInterval = 0.35

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Watching the Klick trigger key"
        )
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.poll() }
                return event
            },
            // Mouse monitors need no permission; they only time-stamp the start of a possible drag.
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseWentDown() }
            },
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.mouseWentDown() }
                return event
            },
        ].compactMap { $0 }
        WheelController.shared.onDismiss = { [weak self] in
            MainActor.assumeIsolated { self?.wheelDidDismiss() }
        }
        schedule(interval: Self.idleInterval)
    }

    // MARK: Polling

    private func schedule(interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let flags = debugFlags ?? CGEventSource.flagsState(.combinedSessionState)
        defer { previousFlags = flags }

        switch phase {
        case .idle:
            guard settings.isEnabled else { return }
            if settings.dragToOpen, let wheel = newlyPressedWheel(in: flags), let urls = draggedFiles() {
                openForDrag(urls, wheel: wheel)
                return
            }
            if let wheel = heldWheel(in: flags) {
                arm(wheel)
            } else if !isMouseDown, debugDrag == nil {
                // A press that ended without a drag: back to the slow pace.
                schedule(interval: Self.idleInterval)
            }

        case .armed(let wheel):
            guard settings.key(for: wheel)?.isHeld(in: flags) == true else {
                // Released early (a tap) or combined with another modifier.
                phase = TriggerKey.anyModifier(in: flags) ? .consumed : .idle
                if case .idle = phase { schedule(interval: Self.idleInterval) }
                return
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - armedAt
            if debugFlags == nil, otherInputHappened(within: elapsed) || movedTooFar() {
                phase = .consumed
                return
            }
            guard elapsed >= holdDelay(for: wheel) else { return }
            tryOpen(wheel, elapsed: elapsed)

        case .open(let dragging):
            guard WheelController.shared.isOpen else {
                phase = .consumed
                return
            }
            if let wheel = newlyPressedWheel(in: flags) {
                WheelController.shared.show(wheel)
            }
            if dragging {
                // The drag ended without a drop on the wheel.
                if !isMouseDown, debugDrag == nil {
                    phase = .consumed
                    WheelController.shared.cancel()
                }
            } else if !settings.wheelTriggers.contains(where: { $0.key.isInvolved(in: flags) }) {
                phase = TriggerKey.anyModifier(in: flags) ? .consumed : .idle
                if case .idle = phase { schedule(interval: Self.idleInterval) }
                WheelController.shared.triggerReleased()
            }

        case .consumed:
            if !TriggerKey.anyModifier(in: flags) {
                phase = .idle
                schedule(interval: Self.idleInterval)
            }
        }
    }

    /// The wheel whose key is held on its own, if any.
    private func heldWheel(in flags: CGEventFlags) -> WheelKind? {
        settings.wheelTriggers.first { $0.key.isHeld(in: flags) }?.wheel
    }

    /// The wheel whose key went down since the last poll, if any.
    private func newlyPressedWheel(in flags: CGEventFlags) -> WheelKind? {
        settings.wheelTriggers.first { $0.key.isInvolved(in: flags) && !$0.key.isInvolved(in: previousFlags) }?.wheel
    }

    private func holdDelay(for wheel: WheelKind) -> TimeInterval {
        switch settings.key(for: wheel) {
        case .command?, .control?: return max(settings.holdDelay, Self.shortcutModifierDelay)
        default: return settings.holdDelay
        }
    }

    private func arm(_ wheel: WheelKind) {
        if debugSelection == nil, settings.finderOnly, !FinderBridge.isFinderFrontmost {
            phase = .consumed
            return
        }
        phase = .armed(wheel)
        armedAt = CFAbsoluteTimeGetCurrent()
        armedMouse = NSEvent.mouseLocation
        selection = nil
        schedule(interval: Self.activeInterval)
        Feedback.shared.warmUp()

        selectionRequest += 1
        if let debugSelection {
            selection = .success(debugSelection)
            return
        }
        let request = selectionRequest
        FinderBridge.fetchSelection { [weak self] result in
            guard let self, request == self.selectionRequest else { return }
            self.selection = result
        }
    }

    private func tryOpen(_ wheel: WheelKind, elapsed: TimeInterval) {
        guard let selection else {
            // Finder hasn't answered yet; give it a moment.
            if elapsed > 2 { phase = .consumed }
            return
        }
        switch selection {
        case .success(let urls):
            guard !urls.isEmpty else {
                phase = .consumed
                return
            }
            phase = .open(dragging: false)
            WheelController.shared.present(
                items: urls.map(FileItem.init(url:)), at: debugAnchor ?? NSEvent.mouseLocation, wheel: wheel
            )
        case .failure(let error as NSError):
            phase = .consumed
            NSLog("%@", "Klick: couldn't read Finder selection: \(error)")
            if FinderBridge.isPermissionError(error), !permissionHintShown {
                permissionHintShown = true
                Toast.shared.showMessage("Allow Klick to control Finder in Settings", symbol: "lock.circle")
                SettingsWindowController.shared.show(pane: .shortcut)
            }
        }
    }

    // MARK: Drags

    private var isMouseDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    private func mouseWentDown() {
        dragChangeCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        // Poll quickly while the button is down so a quick tap during a drag isn't missed.
        if case .idle = phase, settings.isEnabled, settings.dragToOpen { schedule(interval: Self.activeInterval) }
    }

    /// Files being dragged right now (a drag that started after the last mouse down), or nil.
    private func draggedFiles() -> [URL]? {
        if let debugDrag { return debugDrag.isEmpty ? nil : debugDrag }
        guard isMouseDown, let start = dragChangeCountAtMouseDown else { return nil }
        let pasteboard = NSPasteboard(name: .drag)
        guard pasteboard.changeCount != start else { return nil }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    private func openForDrag(_ urls: [URL], wheel: WheelKind) {
        phase = .open(dragging: true)
        schedule(interval: Self.activeInterval)
        Feedback.shared.warmUp()
        WheelController.shared.present(
            items: urls.map(FileItem.init(url:)), at: debugAnchor ?? NSEvent.mouseLocation, wheel: wheel, dragging: true
        )
    }

    // MARK: Guards

    /// Typing (Shift+A) or Shift-clicking since the trigger went down.
    private func otherInputHappened(within elapsed: TimeInterval) -> Bool {
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        return types.contains { type in
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type) < elapsed - 0.01
        }
    }

    private func movedTooFar() -> Bool {
        let mouse = NSEvent.mouseLocation
        return hypot(mouse.x - armedMouse.x, mouse.y - armedMouse.y) > Self.maxArmTravel
    }

    private func wheelDidDismiss() {
        if case .open = phase { phase = .consumed }
    }
}
