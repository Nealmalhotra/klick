import AppKit
import SwiftUI

/// "Custom color" chip, the same size as the preset swatches next to it (SwiftUI's
/// `ColorPicker` draws a wide well that ignores its frame). A rainbow ring around the
/// chosen color; clicking selects it and opens the system color panel.
struct ColorWellSwatch: View {
    @Binding var color: Color
    let selected: Bool

    @StateObject private var panel = ColorPanelLink()
    @State private var hovering = false

    var body: some View {
        Button {
            // Re-assigning the same color selects the custom fill in the editor model.
            color = color
            panel.open(color: color) { color = $0 }
            Feedback.shared.tick()
        } label: {
            ZStack {
                AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
                Circle()
                    .fill(color)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                    .padding(5)
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .padding(2)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0)
            )
            .scaleEffect(hovering ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.springSnappy, value: hovering)
        .animation(Theme.springSnappy, value: selected)
        .onDisappear { panel.detach() }
        .help("Custom color")
    }
}

/// Routes the shared `NSColorPanel` to one swatch at a time.
@MainActor
final class ColorPanelLink: NSObject, ObservableObject {
    /// The swatch the shared panel currently reports to.
    private static weak var current: ColorPanelLink?
    private var onChange: ((Color) -> Void)?

    func open(color: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.color = NSColor(color)
        panel.setTarget(self)
        Self.current = self
        panel.setAction(#selector(colorChanged(_:)))
        // Editors float above normal windows (and Klick usually isn't the active app):
        // the panel has to float and stay visible too.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.orderFrontRegardless()
    }

    func detach() {
        let panel = NSColorPanel.shared
        guard Self.current === self else { return }
        Self.current = nil
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.orderOut(nil)
        panel.hidesOnDeactivate = true
        panel.level = .normal
        onChange = nil
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }
}
