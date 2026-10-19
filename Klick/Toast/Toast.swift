import AppKit
import SwiftUI

/// State of one toast ("× Converting to JPG / 1 of 1 saved / ▬▬▬").
final class ToastModel: ObservableObject {
    enum Style { case progress, success, failure, message }

    @Published var title: String
    @Published var subtitle: String
    @Published var progress: Double = 0
    @Published var style: Style
    @Published var symbol: String?
    @Published var visible = false

    var onCancel: (() -> Void)?

    init(title: String, subtitle: String, style: Style, symbol: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.symbol = symbol
    }
}

/// Handle returned to background work so it can drive its toast.
@MainActor
final class ToastHandle {
    fileprivate let model: ToastModel
    fileprivate weak var toast: Toast?
    fileprivate let panel: NSPanel

    fileprivate init(model: ToastModel, toast: Toast, panel: NSPanel) {
        self.model = model
        self.toast = toast
        self.panel = panel
    }

    func update(progress: Double, subtitle: String? = nil) {
        withAnimation(.easeOut(duration: 0.2)) { model.progress = progress }
        if let subtitle { model.subtitle = subtitle }
    }

    func succeed(subtitle: String) {
        model.subtitle = subtitle
        withAnimation(.easeOut(duration: 0.18)) {
            model.progress = 1
            model.style = .success
        }
        toast?.dismiss(self, after: 0.65)
    }

    func fail(_ message: String) {
        model.subtitle = message
        withAnimation(.easeOut(duration: 0.18)) { model.style = .failure }
        toast?.dismiss(self, after: 2.6)
    }

    func dismiss() { toast?.dismiss(self, after: 0) }
}

/// Small floating glass toasts that pop up at the cursor, like the original.
@MainActor
final class Toast {
    static let shared = Toast()
    private var live: [ToastHandle] = []
    /// Debug hook: forces where toasts appear instead of the cursor.
    static var anchorOverride: NSPoint?

    static let size = CGSize(width: 286, height: 80)
    private static let margin: CGFloat = 30

    /// A job toast with a progress bar and a cancel button.
    func begin(title: String, subtitle: String, at point: NSPoint? = nil, onCancel: @escaping () -> Void) -> ToastHandle {
        let model = ToastModel(title: title, subtitle: subtitle, style: .progress)
        model.onCancel = onCancel
        return present(model, at: point ?? Self.anchorOverride ?? NSEvent.mouseLocation)
    }

    /// A transient one-liner ("Path copied").
    func showMessage(_ text: String, symbol: String = "checkmark.circle.fill", at point: NSPoint? = nil) {
        let model = ToastModel(title: text, subtitle: "", style: .message, symbol: symbol)
        let handle = present(model, at: point ?? Self.anchorOverride ?? NSEvent.mouseLocation)
        dismiss(handle, after: 1.3)
    }

    private func present(_ model: ToastModel, at point: NSPoint) -> ToastHandle {
        let size = CGSize(width: Self.size.width + Self.margin * 2, height: Self.size.height + Self.margin * 2)
        let screen = NSScreen.containing(point) ?? NSScreen.main!
        let visible = screen.visibleFrame
        var origin = NSPoint(x: point.x - size.width / 2 - 24, y: point.y - size.height / 2)
        origin.x = min(max(origin.x, visible.minX - Self.margin + 8), visible.maxX - size.width + Self.margin - 8)
        origin.y = min(max(origin.y, visible.minY - Self.margin + 8), visible.maxY - size.height + Self.margin - 8)

        // Stack below toasts that are still on screen.
        for other in live where other.panel.frame.intersects(NSRect(origin: origin, size: size).insetBy(dx: Self.margin, dy: Self.margin)) {
            origin.y = other.panel.frame.minY - size.height + Self.margin * 2 - 10
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: ToastView(model: model).padding(Self.margin))

        let handle = ToastHandle(model: model, toast: self, panel: panel)
        live.append(handle)
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.76)) { model.visible = true }
        }
        return handle
    }

    fileprivate func dismiss(_ handle: ToastHandle, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.live.contains(where: { $0 === handle }) else { return }
            withAnimation(.easeIn(duration: 0.16)) { handle.model.visible = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                handle.panel.orderOut(nil)
                self.live.removeAll { $0 === handle }
            }
        }
    }
}

// MARK: - View

struct ToastView: View {
    @ObservedObject var model: ToastModel

    var body: some View {
        Group {
            if model.style == .message {
                messageBody
            } else {
                jobBody
            }
        }
        .frame(width: Toast.size.width, height: model.style == .message ? 46 : Toast.size.height)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .scaleEffect(model.visible ? 1 : 0.35)
        .opacity(model.visible ? 1 : 0)
        .blur(radius: model.visible ? 0 : 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var jobBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                leadingIcon
                Text(model.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(model.subtitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(model.style == .failure ? Color.red : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 28)
                .padding(.top, 3)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
            ProgressBar(value: model.progress, failed: model.style == .failure)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 13)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch model.style {
        case .progress:
            Button {
                model.onCancel?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .help("Cancel")
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.accent)
                .frame(width: 20, height: 20)
                .transition(.scale.combined(with: .opacity))
        case .failure:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.red)
                .frame(width: 20, height: 20)
        case .message:
            EmptyView()
        }
    }

    private var messageBody: some View {
        HStack(spacing: 8) {
            if let symbol = model.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
    }
}

private struct ProgressBar: View {
    let value: Double
    let failed: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accentGradient))
                    .frame(width: max(6, geo.size.width * value))
            }
        }
        .frame(height: 5)
    }
}
