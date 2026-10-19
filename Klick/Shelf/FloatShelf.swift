import AppKit
import Combine
import SwiftUI

/// Borderless, non-activating panel for the shelf: floats above every app on every Space
/// and never steals focus from the app you're dragging files into.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The FLOAT file action: keeps files in a small floating glass shelf. Drag them out into
/// any app (moved files leave the shelf, copied ones stay), drop more files in, fling it
/// to a screen edge where it pins itself and can tuck away into a slim tab.
@MainActor
final class FloatShelf {
    static let shared = FloatShelf()

    private let model = ShelfModel()
    private var panel: ShelfPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var monitor: Timer?
    private var shrinkWork: DispatchWorkItem?
    private let spring = WindowSpring()
    /// Bumped on every show, so a late close animation can't hide a shelf that came back.
    private var generation = 0

    private typealias M = ShelfModel.Metrics

    private init() {}

    var isVisible: Bool { panel?.isVisible == true && model.visible }

    // MARK: API

    func add(_ items: [FileItem]) {
        let urls = items.map(\.url)
        if isVisible {
            let added = model.add(urls)
            if model.collapsed { setCollapsed(false) }
            if added > 0 { Feedback.shared.tick() }
            return
        }
        // A shelf that is still fading out starts over empty.
        model.removeAll()
        guard model.add(urls) > 0 else { return }
        show(at: EditorWindowController.anchorOverride ?? NSEvent.mouseLocation)
    }

    /// Clears the shelf and shrinks it away.
    func close() {
        guard let panel, model.visible else { return }
        spring.stop()
        stopMonitoring()
        withAnimation(.easeIn(duration: 0.16)) { model.visible = false }
        Feedback.shared.close()
        let closing = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == closing else { return }
                panel.orderOut(nil)
                self.model.removeAll()
            }
        })
    }

    // MARK: Presentation

    private func show(at anchor: NSPoint) {
        let panel = self.panel ?? makePanel()
        generation += 1
        spring.stop()
        model.edge = nil
        model.collapsed = false
        model.visible = false

        // Centered on the cursor (or the wheel), kept on screen.
        let size = model.cardSize
        let visible = (NSScreen.containing(anchor) ?? NSScreen.main!).visibleFrame
        var card = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2, width: size.width, height: size.height)
        card.origin.x = min(max(card.minX, visible.minX + M.edgeInset), visible.maxX - size.width - M.edgeInset)
        card.origin.y = min(max(card.minY, visible.minY + M.edgeInset), visible.maxY - size.height - M.edgeInset)
        panel.setFrame(card.insetBy(dx: -M.margin, dy: -M.margin), display: false)

        panel.alphaValue = 1
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [model] in
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { model.visible = true }
        }
        Feedback.shared.open()
        startMonitoring()
    }

    private func makePanel() -> ShelfPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let actions = ShelfActions(
            close: { [weak self] in self?.close() },
            toggleCollapsed: { [weak self] in self?.toggleCollapsed() },
            dragBegan: { [weak self] in self?.dragBegan() },
            dragMoved: { [weak self] in self?.dragMoved(to: $0) },
            dragEnded: { [weak self] in self?.dragEnded(velocity: $0) },
            filesDropped: { [weak self] in self?.filesDropped($0) },
            dragOutEnded: { [weak self] in self?.dragOutEnded($0, operation: $1) }
        )
        let hosting = NSHostingView(rootView: ShelfView(model: model, actions: actions))
        // The controller sizes the window (anchored to the pinned edge); SwiftUI must not.
        hosting.sizingOptions = []
        panel.contentView = hosting

        // Resize the window whenever the card changes size.
        Publishers.Merge3(
            model.$items.map { _ in () },
            model.$collapsed.map { _ in () },
            model.$edge.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in MainActor.assumeIsolated { self?.fitWindow() } }
        .store(in: &subscriptions)

        model.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                MainActor.assumeIsolated {
                    if items.isEmpty, self?.model.visible == true { self?.close() }
                }
            }
            .store(in: &subscriptions)

        self.panel = panel
        return panel
    }

    // MARK: Geometry

    /// Where the card currently is on screen (it hugs the window's top, and its pinned side).
    private var cardFrame: NSRect {
        guard let panel else { return .zero }
        let size = model.cardSize
        let frame = panel.frame
        let x = model.edge == .right ? frame.maxX - M.margin - size.width : frame.minX + M.margin
        return NSRect(x: x, y: frame.maxY - M.margin - size.height, width: size.width, height: size.height)
    }

    /// The point that stays put while the card resizes: its top corner on the pinned side.
    private var cardAnchor: CGPoint {
        let card = cardFrame
        return CGPoint(x: model.edge == .right ? card.maxX : card.minX, y: card.maxY)
    }

    /// Moves the window so the card's anchor lands on `anchor`, whatever the window's size.
    private func place(anchor: CGPoint) {
        guard let panel else { return }
        let size = panel.frame.size
        let x = model.edge == .right ? anchor.x + M.margin - size.width : anchor.x - M.margin
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: (anchor.y + M.margin - size.height).rounded()))
    }

    /// Window frame of `cardSize` (plus margins) that keeps the current anchor.
    private func frame(fitting cardSize: CGSize) -> NSRect {
        let anchor = cardAnchor
        let width = cardSize.width + M.margin * 2, height = cardSize.height + M.margin * 2
        let x = model.edge == .right ? anchor.x + M.margin - width : anchor.x - M.margin
        return NSRect(x: x, y: anchor.y + M.margin - height, width: width, height: height)
    }

    /// Grows the window right away (the card animates inside it) and trims it once the
    /// card has finished shrinking, so the transparent area around the card stays small.
    private func fitWindow() {
        guard let panel, !model.items.isEmpty else { return }
        let card = model.cardSize
        let inner = CGSize(width: panel.frame.width - M.margin * 2, height: panel.frame.height - M.margin * 2)
        if card.width > inner.width || card.height > inner.height {
            panel.setFrame(frame(fitting: CGSize(width: max(card.width, inner.width), height: max(card.height, inner.height))), display: true)
        }
        shrinkWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.trimWindow() }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        keepOnScreen()
    }

    private func trimWindow() {
        shrinkWork?.cancel()
        shrinkWork = nil
        guard let panel else { return }
        panel.setFrame(frame(fitting: model.cardSize), display: true)
        keepOnScreen()
    }

    /// Springs the shelf back inside the screen when it grew past the bottom (or top).
    private func keepOnScreen() {
        guard !spring.isRunning else { return }
        let card = NSRect(origin: NSPoint(x: cardFrame.minX, y: cardAnchor.y - model.cardSize.height), size: model.cardSize)
        let visible = screen(for: card).visibleFrame
        var dy: CGFloat = 0
        if card.minY < visible.minY + M.edgeInset { dy = visible.minY + M.edgeInset - card.minY }
        if card.maxY + dy > visible.maxY - M.edgeInset { dy = visible.maxY - M.edgeInset - card.maxY }
        guard abs(dy) > 0.5 else { return }
        let anchor = cardAnchor
        springAnchor(to: CGPoint(x: anchor.x, y: anchor.y + dy))
    }

    private func screen(for rect: NSRect) -> NSScreen {
        NSScreen.containing(NSPoint(x: rect.midX, y: rect.midY)) ?? NSScreen.main!
    }

    /// Card anchor flush against `edge`, with the card's top at `top` (kept on screen).
    private func pinnedAnchor(edge: ShelfEdge, top: CGFloat, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let height = model.cardSize.height
        let y = min(max(top, visible.minY + M.edgeInset + height), visible.maxY - M.edgeInset)
        return CGPoint(x: edge == .left ? visible.minX + M.edgeInset : visible.maxX - M.edgeInset, y: y)
    }

    private func springAnchor(to target: CGPoint, velocity: CGVector = .zero) {
        spring.animate(from: cardAnchor, to: target, velocity: velocity) { [weak self] point in
            self?.place(anchor: point)
        }
    }

    /// Re-anchors the window on another side without moving the card on screen.
    private func setEdge(_ edge: ShelfEdge?) {
        guard let panel, model.edge != edge else { return }
        let card = cardFrame
        model.edge = edge
        panel.setFrame(card.insetBy(dx: -M.margin, dy: -M.margin), display: true)
    }

    // MARK: Moving & pinning

    private func dragBegan() {
        spring.stop()
        trimWindow()
        grabOffsetPending = true
    }

    /// Window offset from the cursor, measured on the first move event of a drag.
    private var grabOffset: CGVector = .zero
    private var grabOffsetPending = false

    private func dragMoved(to point: NSPoint) {
        guard let panel else { return }
        if grabOffsetPending {
            grabOffsetPending = false
            grabOffset = CGVector(dx: panel.frame.minX - point.x, dy: panel.frame.minY - point.y)
        }
        panel.setFrameOrigin(NSPoint(x: point.x + grabOffset.dx, y: point.y + grabOffset.dy))
    }

    /// Pins to the nearer left/right edge — or the one it was flung toward — with a spring
    /// that carries the release velocity.
    private func dragEnded(velocity: CGVector) {
        let card = cardFrame
        let screen = screen(for: card)
        let edge: ShelfEdge
        if abs(velocity.dx) > 700 {
            edge = velocity.dx < 0 ? .left : .right
        } else {
            edge = card.midX < screen.visibleFrame.midX ? .left : .right
        }
        setEdge(edge)
        // A vertical fling carries the shelf a little further.
        let top = card.maxY + max(min(velocity.dy * 0.12, 260), -260)
        springAnchor(to: pinnedAnchor(edge: edge, top: top, on: screen), velocity: velocity)
        Feedback.shared.tick()
    }

    private func toggleCollapsed() {
        setCollapsed(!model.collapsed)
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard model.collapsed != collapsed else { return }
        let wasFloating = model.edge == nil
        if collapsed && wasFloating {
            // Tucking away pins the shelf to the nearer edge first.
            spring.stop()
            let card = cardFrame
            setEdge(card.midX < screen(for: card).visibleFrame.midX ? .left : .right)
        }
        withAnimation(Theme.springSoft) { model.collapsed = collapsed }
        Feedback.shared.tick()
        if collapsed && wasFloating, let edge = model.edge {
            springAnchor(to: pinnedAnchor(edge: edge, top: cardAnchor.y, on: screen(for: cardFrame)))
        }
    }

    // MARK: Files

    private func filesDropped(_ urls: [URL]) {
        if model.add(urls) > 0 { Feedback.shared.success() }
    }

    private func dragOutEnded(_ ids: Set<UUID>, operation: NSDragOperation) {
        model.isDraggingOut = false
        model.dropTargeted = false
        // Moved (or trashed) files leave the shelf; copies and links stay.
        if operation.contains(.move) || operation.contains(.delete) {
            model.remove(ids)
            return
        }
        // Some apps report a generic operation for a move: check whether the files are still there.
        if operation.contains(.generic) {
            let gone = model.items.filter { ids.contains($0.id) && !FileManager.default.fileExists(atPath: $0.url.path) }
            model.remove(Set(gone.map(\.id)))
        }
    }

    private func startMonitoring() {
        monitor?.invalidate()
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshFromDisk() }
        }
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
    }

    private func stopMonitoring() {
        monitor?.invalidate()
        monitor = nil
    }
}

// MARK: - Spring

/// Drives a point to a target with a damped spring (a hint of overshoot), starting from an
/// initial velocity in points per second; `apply` receives every frame's position.
@MainActor
final class WindowSpring {
    private var timer: Timer?
    private var position: CGPoint = .zero
    private var velocity: CGVector = .zero
    private var target: CGPoint = .zero
    private var apply: ((CGPoint) -> Void)?

    private let stiffness: CGFloat = 320
    private let damping: CGFloat = 26

    var isRunning: Bool { timer != nil }

    func animate(from start: CGPoint, to target: CGPoint, velocity: CGVector = .zero, apply: @escaping (CGPoint) -> Void) {
        stop()
        self.apply = apply
        self.target = target
        position = start
        // Keep the fling, within reason.
        self.velocity = CGVector(dx: max(min(velocity.dx, 4000), -4000), dy: max(min(velocity.dy, 4000), -4000))
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        apply = nil
    }

    private func step() {
        guard let apply else { stop(); return }
        // Semi-implicit Euler, two sub-steps per frame for stability.
        let h: CGFloat = 1.0 / 240.0
        for _ in 0..<2 {
            velocity.dx += (-stiffness * (position.x - target.x) - damping * velocity.dx) * h
            velocity.dy += (-stiffness * (position.y - target.y) - damping * velocity.dy) * h
            position.x += velocity.dx * h
            position.y += velocity.dy * h
        }
        if hypot(position.x - target.x, position.y - target.y) < 0.4 && hypot(velocity.dx, velocity.dy) < 8 {
            apply(target)
            stop()
        } else {
            apply(position)
        }
    }
}
