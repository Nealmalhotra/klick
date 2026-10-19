import AppKit
import SwiftUI

// MARK: - Drag out

/// Transparent AppKit layer over a shelf tile: drags its files into other apps
/// (a real `NSDraggingSource`, so the shelf learns whether they were moved or copied),
/// reports hover even while Klick is in the background, and opens on double click.
struct ShelfDragSource: NSViewRepresentable {
    let urls: [URL]
    let image: NSImage?
    var onHover: (Bool) -> Void = { _ in }
    var onBegan: () -> Void = {}
    /// Receives the operation the destination performed (`[]` when the drag was cancelled).
    var onEnded: (NSDragOperation) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> SourceView { SourceView() }

    func updateNSView(_ view: SourceView, context: Context) { view.config = self }

    final class SourceView: NSView, NSDraggingSource {
        var config: ShelfDragSource?
        private var mouseDownEvent: NSEvent?
        private var hovering = false

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited], owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { setHovering(true) }
        override func mouseExited(with event: NSEvent) { setHovering(false) }

        private func setHovering(_ value: Bool) {
            guard value != hovering else { return }
            hovering = value
            config?.onHover(value)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            if event.clickCount == 2 { config?.onDoubleClick() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = mouseDownEvent, let config, !config.urls.isEmpty else { return }
            let start = down.locationInWindow, now = event.locationInWindow
            guard hypot(now.x - start.x, now.y - start.y) > 3 else { return }
            mouseDownEvent = nil

            let origin = convert(start, from: nil)
            let side = ShelfModel.Metrics.thumbnailSide
            let items = config.urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                // A small fanned stack when several files travel together.
                let offset = CGFloat(min(index, 4)) * 6
                let frame = NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 + offset, width: side, height: side)
                item.setDraggingFrame(frame, contents: index == 0 ? (config.image ?? NSWorkspace.shared.icon(forFile: url.path)) : NSWorkspace.shared.icon(forFile: url.path))
                return item
            }
            config.onBegan()
            let session = beginDraggingSession(with: items, event: down, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownEvent = nil
        }

        // MARK: NSDraggingSource

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .generic, .link, .delete] : [.copy]
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            config?.onEnded(operation)
            // The cursor usually ends outside the tile; make sure the hover state follows.
            if let window, !window.frame.contains(screenPoint) { setHovering(false) }
        }
    }
}

// MARK: - Move

/// Transparent AppKit layer that moves the shelf window by hand (so it can be flung and
/// snapped with a spring when released) and reports plain clicks.
struct ShelfMoveHandle: NSViewRepresentable {
    var onBegan: () -> Void = {}
    /// Global cursor position while dragging.
    var onMoved: (NSPoint) -> Void
    /// Release velocity in points per second.
    var onEnded: (CGVector) -> Void
    var onClick: () -> Void = {}

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) { view.config = self }

    final class HandleView: NSView {
        var config: ShelfMoveHandle?
        private var start: NSPoint?
        private var windowStart: NSPoint = .zero
        private var moved = false
        private var samples: [(time: TimeInterval, point: NSPoint)] = []

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            windowStart = window?.frame.origin ?? .zero
            start = globalPoint(event)
            moved = false
            samples = []
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = globalPoint(event)
            if !moved {
                guard hypot(point.x - start.x, point.y - start.y) > 2 else { return }
                moved = true
                NSCursor.closedHand.set()
                config?.onBegan()
            }
            samples.append((event.timestamp, point))
            samples.removeAll { event.timestamp - $0.time > 0.1 }
            config?.onMoved(point)
        }

        override func mouseUp(with event: NSEvent) {
            defer { start = nil }
            guard start != nil else { return }
            guard moved else {
                config?.onClick()
                return
            }
            NSCursor.openHand.set()
            var velocity = CGVector.zero
            if let first = samples.first, let last = samples.last, last.time - first.time > 0.008,
               event.timestamp - last.time < 0.08 {
                let dt = last.time - first.time
                velocity = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
            }
            config?.onEnded(velocity)
        }

        /// Global cursor position. Real events read the live cursor (the window moves under
        /// it); synthetic events from the debug driver carry their position relative to
        /// where the window was when the gesture started.
        private func globalPoint(_ event: NSEvent) -> NSPoint {
            #if DEBUG
            if event.eventNumber == 0 {
                return NSPoint(x: windowStart.x + event.locationInWindow.x, y: windowStart.y + event.locationInWindow.y)
            }
            #endif
            return NSEvent.mouseLocation
        }
    }
}
