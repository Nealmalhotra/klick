import AppKit
import SwiftUI

/// Borderless, transparent panel that hosts a Liquid Glass editor card.
/// Non-activating, so it takes keyboard focus without pulling Klick (or its
/// menu bar) in front of Finder — the card simply floats where you were working.
final class GlassCardWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc closes the editor even when no control has focus.
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Drives the appear / disappear animation of an editor card.
final class EditorPresentation: ObservableObject {
    @Published var visible = false
}

/// Presents SwiftUI editors in floating glass windows, animated like the
/// original: the card fades in while growing from ~92% around the cursor.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private static var live: [EditorWindowController] = []

    private let window: GlassCardWindow
    private let presentation = EditorPresentation()
    private var isClosing = false

    /// Debug hook: forces where the next editor opens.
    static var anchorOverride: NSPoint?

    /// Transparent margin around the card so the SwiftUI shadow is not clipped.
    static let shadowMargin: CGFloat = 40

    /// - Parameters:
    ///   - width: card width in points (height is measured from the content).
    ///   - anchor: global point the window should be centered on (defaults to the cursor).
    ///   - content: builder receiving a `close` closure that dismisses the editor.
    @discardableResult
    static func present<Content: View>(
        width: CGFloat,
        anchor: NSPoint = NSEvent.mouseLocation,
        @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> Content
    ) -> EditorWindowController {
        let controller = EditorWindowController(width: width, anchor: anchorOverride ?? anchor, content: content)
        live.append(controller)
        return controller
    }

    private init<Content: View>(
        width: CGFloat,
        anchor: NSPoint,
        content: @escaping (_ close: @escaping () -> Void) -> Content
    ) {
        window = GlassCardWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 400),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }

        let close: () -> Void = { [weak self] in self?.close() }
        let root = EditorCardContainer(presentation: presentation) {
            content(close)
                .frame(width: width)
        }
        .padding(Self.shadowMargin)

        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        window.contentView = hosting

        let size = hosting.fittingSize
        let screen = NSScreen.containing(anchor) ?? NSScreen.main!
        let visible = screen.visibleFrame
        var origin = NSPoint(x: anchor.x - size.width / 2, y: anchor.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX - Self.shadowMargin + 8), visible.maxX - size.width + Self.shadowMargin - 8)
        origin.y = min(max(origin.y, visible.minY - Self.shadowMargin + 8), visible.maxY - size.height + Self.shadowMargin - 8)
        window.setFrame(NSRect(origin: origin, size: size), display: false)

        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        // Don't start with a text field focused (SwiftUI focuses the first one by default).
        DispatchQueue.main.async { [window] in window.makeFirstResponder(nil) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.async { [presentation] in
            withAnimation(Theme.springSoft) { presentation.visible = true }
        }
        Feedback.shared.open()
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeIn(duration: 0.14)) { presentation.visible = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window.orderOut(nil)
                Self.live.removeAll { $0 === self }
            }
        })
    }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }
}

private struct EditorCardContainer<Content: View>: View {
    @ObservedObject var presentation: EditorPresentation
    @ViewBuilder var content: Content

    var body: some View {
        content
            .shadow(color: .black.opacity(0.22), radius: 28, y: 14)
            .scaleEffect(presentation.visible ? 1 : 0.92)
            .opacity(presentation.visible ? 1 : 0)
            .blur(radius: presentation.visible ? 0 : 6)
    }
}
