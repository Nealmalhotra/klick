import AppKit
import SwiftUI

/// Borderless panel that floats the wheel above every app without activating Klick.
final class WheelPanel: NSPanel {
    weak var controller: WheelController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) != true { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        controller?.cancel()
    }
}

/// Hosting view that turns raw mouse input — and files dropped on it — into wheel commands.
final class WheelHostingView: NSHostingView<WheelView> {
    weak var controller: WheelController?
    private var scrollAccumulator: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drop target (wheel opened during a drag)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let window else { return false }
        return controller?.drop(at: window.convertPoint(toScreen: sender.draggingLocation)) ?? false
    }

    /// Accepts the drop only over a segment; `.generic` avoids Finder's "+" copy badge.
    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let window, let controller,
              controller.dragHover(at: window.convertPoint(toScreen: sender.draggingLocation)) else { return [] }
        let allowed = sender.draggingSourceOperationMask
        return allowed.contains(.generic) ? .generic : allowed.contains(.copy) ? .copy : allowed.contains(.link) ? .link : []
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        controller?.click(at: window.convertPoint(toScreen: event.locationInWindow))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.flipPage(by: 1)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : -event.scrollingDeltaX
        if event.phase == .began || event.phase == .mayBegin { scrollAccumulator = 0 }
        scrollAccumulator += event.hasPreciseScrollingDeltas ? delta : delta * 12
        let threshold: CGFloat = 28
        if abs(scrollAccumulator) >= threshold {
            controller?.flipPage(by: scrollAccumulator > 0 ? -1 : 1)
            scrollAccumulator = 0
        }
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = 0 }
    }
}

/// Owns the wheel panel: presentation, hover tracking, paging and commit.
@MainActor
final class WheelController {
    static let shared = WheelController()

    private var panel: WheelPanel?
    private var hosting: WheelHostingView?
    private(set) var model: WheelModel?
    private var center: NSPoint = .zero
    private var trackTimer: Timer?
    private var outsideClickMonitor: Any?
    /// Last cursor position seen by the tracker; hover is only recomputed when it moves,
    /// so keyboard / programmatic highlights stick until the mouse moves again.
    private var lastMouse: NSPoint?

    /// Called when the wheel goes away (committed or not).
    var onDismiss: (() -> Void)?

    /// True from `present` until the wheel starts dismissing.
    var isOpen: Bool { model != nil }

    // MARK: Presentation

    /// - Parameters:
    ///   - wheel: wheel to open on (its page, or the first page when the selection has none).
    ///   - dragging: opened during a drag: the wheel stays up until the files are dropped on it.
    func present(
        items: [FileItem], at point: NSPoint = NSEvent.mouseLocation,
        wheel: WheelKind? = nil, initialPage: Int = 0, dragging: Bool = false
    ) {
        let pages = ActionCatalog.pages(for: items)
        guard !pages.isEmpty else {
            Toast.shared.showMessage("Nothing to do with this selection", symbol: "questionmark.circle")
            return
        }
        dismissImmediately()

        let model = WheelModel(items: items, pages: pages)
        model.pageIndex = wheel.flatMap { wheel in pages.firstIndex { $0.id == wheel.pageID } }
            ?? min(initialPage, pages.count - 1)
        self.model = model

        let size = WheelMetrics.panelSize
        let screen = NSScreen.containing(point) ?? NSScreen.main!
        let visible = screen.frame
        let r = WheelMetrics.radius + 8
        center = NSPoint(
            x: min(max(point.x, visible.minX + r), visible.maxX - r),
            y: min(max(point.y, visible.minY + r), visible.maxY - r)
        )

        let panel = WheelPanel(
            contentRect: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.controller = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let hosting = WheelHostingView(rootView: WheelView(model: model))
        hosting.controller = self
        if dragging { hosting.registerForDraggedTypes([.fileURL]) }
        hosting.frame = NSRect(x: 0, y: 0, width: size, height: size)
        panel.contentView = hosting

        self.panel = panel
        self.hosting = hosting

        // Render the hidden state first so SwiftUI has something to animate from.
        hosting.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) {
            model.phase = .shown
        }
        Feedback.shared.open()
        startTracking()
    }

    // MARK: Tracking

    private func startTracking() {
        trackTimer?.invalidate()
        lastMouse = nil
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    private func stopTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    private func trackMouse() {
        let mouse = NSEvent.mouseLocation
        if let lastMouse, hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) < 0.5 { return }
        lastMouse = mouse
        updateHover(at: mouse)
    }

    /// Highlights the segment under `point` (screen coordinates); returns whether there is one.
    @discardableResult
    private func updateHover(at point: NSPoint) -> Bool {
        guard let model else { return false }
        let vector = CGVector(dx: point.x - center.x, dy: point.y - center.y)
        let index = WheelMetrics.segmentIndex(for: vector, count: model.actions.count)
        if index != model.hovered {
            model.hovered = index
            if index != nil { Feedback.shared.tick() }
        }
        return index != nil
    }

    /// Debug/automation hook: highlight a segment programmatically.
    func setHovered(_ index: Int?) {
        guard let model else { return }
        model.hovered = index.flatMap { model.actions.indices.contains($0) ? $0 : nil }
        if model.hovered != nil { Feedback.shared.tick() }
    }

    // MARK: Commands

    /// Switches to `wheel`'s page (its trigger key was pressed while the wheel is open).
    func show(_ wheel: WheelKind) {
        guard let model, let index = model.pages.firstIndex(where: { $0.id == wheel.pageID }), index != model.pageIndex else { return }
        flipPage(by: index - model.pageIndex)
    }

    /// Drag hovering at `point` (screen coordinates); returns whether a segment would take the drop.
    func dragHover(at point: NSPoint) -> Bool {
        lastMouse = point
        return updateHover(at: point)
    }

    /// Files dropped at `point`: runs the segment there. Returns false (drop refused) over the hub.
    func drop(at point: NSPoint) -> Bool {
        guard updateHover(at: point) else { return false }
        commit()
        return true
    }

    func flipPage(by delta: Int) {
        guard let model, model.pages.count > 1 else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.8)) {
            model.flip(by: delta)
        }
        Feedback.shared.page()
        lastMouse = nil
        trackMouse()
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        switch Int(event.keyCode) {
        case 53: // esc
            cancel()
        case 48: // tab
            flipPage(by: event.modifierFlags.contains(.control) ? -1 : 1)
        case 123, 126: // ← ↑
            flipPage(by: -1)
        case 124, 125: // → ↓
            flipPage(by: 1)
        case 36, 76, 49: // return, enter, space
            commit()
        default:
            if let chars = event.charactersIgnoringModifiers, let digit = Int(chars), digit >= 1, digit <= model.actions.count {
                model.hovered = digit - 1
                commit()
            } else if !event.modifierFlags.intersection([.command, .control]).isEmpty {
                // A shortcut (⌘C…) means the trigger was held for something else.
                cancel()
            } else {
                return false
            }
        }
        return true
    }

    /// Mouse click inside the panel: run the segment under the click, or cancel over the hub/outside.
    func click(at point: NSPoint) {
        guard let model else { return }
        let vector = CGVector(dx: point.x - center.x, dy: point.y - center.y)
        model.hovered = WheelMetrics.segmentIndex(for: vector, count: model.actions.count)
        if model.hovered != nil { commit() } else { cancel() }
    }

    /// Trigger key released (GTA-style): run the hovered action, otherwise close.
    func triggerReleased() {
        guard isOpen else { return }
        if model?.hovered != nil { commit() } else { cancel() }
    }

    func commit() {
        guard let model, let action = model.hoveredAction else {
            cancel()
            return
        }
        let items = model.items
        Feedback.shared.select()
        var opensEditor = false
        if case .editor = action.kind { opensEditor = true }
        dismiss(committed: true, restoreFocus: !opensEditor)
        ActionRunner.run(action, on: items)
    }

    func cancel() {
        guard isOpen else { return }
        Feedback.shared.close()
        dismiss(committed: false, restoreFocus: true)
    }

    /// - Parameter restoreFocus: hand keyboard focus back to the frontmost app (Finder)
    ///   unless an editor card is about to take it.
    private func dismiss(committed: Bool, restoreFocus: Bool) {
        guard let model, let panel else { return }
        stopTracking()
        model.phase = .dismissing(committed: committed)
        let closingPanel = panel
        self.panel = nil
        self.hosting = nil
        self.model = nil
        closingPanel.resignKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + (committed ? 0.12 : 0.16)) {
            closingPanel.orderOut(nil)
            if restoreFocus, let app = NSWorkspace.shared.frontmostApplication, app != .current {
                app.activate()
            }
        }
        onDismiss?()
    }

    private func dismissImmediately() {
        stopTracking()
        panel?.orderOut(nil)
        panel = nil
        hosting = nil
        model = nil
    }
}
