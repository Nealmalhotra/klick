import AppKit
import SwiftUI

/// Building blocks shared by the editors that draw on top of a picture (Annotate, Redact).
enum EditorCanvas {
    static let cornerRadius: CGFloat = 14

    /// Virtual key codes the canvases react to.
    enum KeyCode {
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
    }
}

// MARK: - Layout

extension EditorCanvas {
    /// Where an image sits inside an editor card: its full size in pixels and the
    /// aspect-fit canvas, in points, it is shown in.
    struct Layout {
        /// Oriented size of the source image, in pixels.
        let pixelSize: CGSize
        /// On-screen canvas size, in points.
        let size: CGSize
        /// Canvas points per image pixel.
        let scale: CGFloat

        /// Fits the image into `maxWidth`, keeping the whole card within 85% of the screen's visible height.
        /// - Parameter reservedHeight: card height taken by everything except the canvas.
        @MainActor
        init(pixelSize: CGSize, maxWidth: CGFloat, reservedHeight: CGFloat) {
            let anchor = EditorWindowController.anchorOverride ?? NSEvent.mouseLocation
            let screenHeight = NSScreen.containing(anchor)?.visibleFrame.height ?? 800
            let maxHeight = max(160, screenHeight * 0.85 - reservedHeight)
            self.pixelSize = pixelSize
            scale = min(maxWidth / pixelSize.width, maxHeight / pixelSize.height)
            size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        }

        /// Layout for `item`, or nil (after telling the user) when it can't be read as an image.
        @MainActor
        static func make(for item: FileItem, maxWidth: CGFloat, reservedHeight: CGFloat) -> Layout? {
            guard let size = ImageIOKit.orientedPixelSize(item.url), size.width > 0, size.height > 0 else {
                Feedback.shared.failure()
                Toast.shared.showMessage("Couldn't open \(item.name)", symbol: "exclamationmark.triangle.fill")
                return nil
            }
            return Layout(pixelSize: size, maxWidth: maxWidth, reservedHeight: reservedHeight)
        }

        /// Longest side of a preview that stays sharp on Retina screens.
        var previewMaxPixelSize: Int { Int((max(size.width, size.height) * 2).rounded(.up)) }

        func imagePoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / scale, y: point.y / scale)
        }

        func viewRect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        }

        /// Downscaled, oriented preview of `url`, decoded off the main thread.
        func loadPreview(of url: URL) async -> CGImage? {
            let maxPixelSize = previewMaxPixelSize
            return await Task.detached(priority: .userInitiated) {
                try? ImageIOKit.loadImage(url, maxPixelSize: maxPixelSize)
            }.value
        }
    }
}

// MARK: - Views

extension EditorCanvas {
    /// The picture under the drawing layers; a soft placeholder until the preview is decoded.
    struct Photo: View {
        let image: CGImage?

        var body: some View {
            ZStack {
                Color.primary.opacity(0.05)
                if let image {
                    Group {
                        if ImageIOKit.hasAlpha(image) { CheckerboardView() }
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: image != nil)
        }
    }

    /// Glass capsule floating at the bottom of a canvas, for hints and results.
    struct Hint: View {
        let symbol: String
        let text: String

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: Capsule())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Mouse

extension EditorCanvas {
    /// Transparent mouse surface laid over a canvas. Reports presses and drags in
    /// canvas points (top-left origin), drives the cursor, and never lets a drag move
    /// the borderless editor window.
    struct MouseInput: NSViewRepresentable {
        var onDown: (CGPoint) -> Void
        var onDrag: (CGPoint) -> Void
        var onUp: (CGPoint) -> Void
        var cursor: (CGPoint) -> NSCursor

        func makeNSView(context: Context) -> InputView { InputView() }

        func updateNSView(_ view: InputView, context: Context) { view.input = self }

        final class InputView: NSView {
            var input: MouseInput?

            override var isFlipped: Bool { true }
            override var mouseDownCanMoveWindow: Bool { false }
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                trackingAreas.forEach(removeTrackingArea)
                addTrackingArea(NSTrackingArea(
                    rect: .zero,
                    options: [.inVisibleRect, .activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate],
                    owner: self
                ))
            }

            override func mouseDown(with event: NSEvent) {
                input?.onDown(location(of: event))
                updateCursor(event)
            }

            override func mouseDragged(with event: NSEvent) {
                input?.onDrag(location(of: event))
                updateCursor(event)
            }

            override func mouseUp(with event: NSEvent) {
                input?.onUp(location(of: event))
                updateCursor(event)
            }

            override func mouseMoved(with event: NSEvent) { updateCursor(event) }
            override func mouseEntered(with event: NSEvent) { updateCursor(event) }
            override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
            override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }

            private func location(of event: NSEvent) -> CGPoint {
                convert(event.locationInWindow, from: nil)
            }

            private func updateCursor(_ event: NSEvent) {
                (input?.cursor(location(of: event)) ?? .arrow).set()
            }
        }
    }
}

// MARK: - Keyboard

extension EditorCanvas {
    /// Sees key events aimed at the editor's window before SwiftUI keyboard shortcuts
    /// (Esc closes, Return saves) so the canvas can claim a key only while it has
    /// something to act on — a selection or a label being typed.
    struct KeyInterceptor: NSViewRepresentable {
        /// Receives key-down and modifier-change events; returns true to consume them.
        let handler: (NSEvent) -> Bool

        func makeNSView(context: Context) -> MonitorView { MonitorView() }

        func updateNSView(_ view: MonitorView, context: Context) { view.handler = handler }

        final class MonitorView: NSView {
            var handler: ((NSEvent) -> Bool)?
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                    // Local monitors run on the main thread; the event never leaves it.
                    nonisolated(unsafe) let event = event
                    let consumed = MainActor.assumeIsolated {
                        guard let self, event.window === self.window else { return false }
                        return self.handler?(event) == true
                    }
                    return consumed ? nil : event
                }
            }

            deinit {
                if let monitor { NSEvent.removeMonitor(monitor) }
            }
        }
    }
}
