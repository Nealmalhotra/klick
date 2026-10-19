import SwiftUI

// MARK: - Sliders

/// One adjustment slider: title, the value it drives and how its value reads.
struct AdjustSlider: Identifiable {
    enum Style { case signed, exposure, percent }

    let title: String
    let keyPath: WritableKeyPath<ImageAdjustments, Double>
    var range: ClosedRange<Double> = -100...100
    var style: Style = .signed

    var id: String { title }
    var isBipolar: Bool { range.lowerBound < 0 }

    func format(_ value: Double) -> String {
        let text: String
        switch style {
        case .exposure: text = value == 0 ? "0.00 EV" : String(format: "%+.2f EV", value)
        case .percent: text = "\(Int(value.rounded()))%"
        case .signed:
            let rounded = Int(value.rounded())
            text = rounded == 0 ? "0" : String(format: "%+d", rounded)
        }
        return text.replacingOccurrences(of: "-", with: "\u{2212}")
    }
}

/// Slider groups of the Edit editor (one segmented tab each).
enum AdjustTab: String, CaseIterable {
    case light, color, detail

    var title: String { rawValue.capitalized }

    var sliders: [AdjustSlider] {
        switch self {
        case .light:
            return [
                AdjustSlider(title: "Exposure", keyPath: \.exposure, range: -2...2, style: .exposure),
                AdjustSlider(title: "Contrast", keyPath: \.contrast),
                AdjustSlider(title: "Highlights", keyPath: \.highlights),
                AdjustSlider(title: "Shadows", keyPath: \.shadows),
            ]
        case .color:
            return [
                AdjustSlider(title: "Saturation", keyPath: \.saturation),
                AdjustSlider(title: "Vibrance", keyPath: \.vibrance),
                AdjustSlider(title: "Warmth", keyPath: \.warmth),
                AdjustSlider(title: "Tint", keyPath: \.tint),
            ]
        case .detail:
            return [
                AdjustSlider(title: "Sharpness", keyPath: \.sharpness, range: 0...100, style: .percent),
                AdjustSlider(title: "Vignette", keyPath: \.vignette, range: 0...100, style: .percent),
            ]
        }
    }
}

/// "Exposure ——●—— +0.50 EV". Bipolar sliders fill from the center and click into
/// a soft detent at zero; double-clicking the title or the value resets the slider.
struct AdjustSliderRow: View {
    let slider: AdjustSlider
    @Binding var value: Double

    private var isModified: Bool { value != 0 }

    var body: some View {
        HStack(spacing: 12) {
            Text(slider.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isModified ? .primary : .secondary)
                .animation(Theme.springSnappy, value: isModified)
                .frame(width: 70, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: reset)
                .help("Double-click to reset")
            sliderControl
                .labelsHidden()
                .tint(Theme.accent)
                .controlSize(.small)
            Text(slider.format(value))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(isModified ? Theme.accent : .secondary)
                .animation(Theme.springSnappy, value: isModified)
                .contentTransition(.numericText(value: value))
                .frame(width: 58, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: reset)
                .help("Double-click to reset")
        }
    }

    @ViewBuilder private var sliderControl: some View {
        if slider.isBipolar {
            Slider(value: detentValue, in: slider.range, neutralValue: 0) {
                Text(slider.title)
            } ticks: {
                SliderTick(0)
            }
        } else {
            Slider(value: $value, in: slider.range) { Text(slider.title) }
        }
    }

    /// Snaps to zero within 2% of the range, with a tick when it lands there.
    private var detentValue: Binding<Double> {
        Binding(
            get: { value },
            set: { newValue in
                let snapped = abs(newValue) < (slider.range.upperBound - slider.range.lowerBound) * 0.02 ? 0 : newValue
                if snapped == 0, value != 0 { Feedback.shared.tick() }
                value = snapped
            }
        )
    }

    private func reset() {
        guard isModified else { return }
        withAnimation(Theme.springSnappy) { value = 0 }
        Feedback.shared.tick()
    }
}

// MARK: - Tool buttons

/// Round Liquid Glass icon button (rotate, flip ...).
struct AdjustToolButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AdjustToolIcon(symbol: symbol)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Press-and-hold eye button: `isComparing` is true while the mouse is down.
struct AdjustCompareButton: View {
    @Binding var isComparing: Bool

    var body: some View {
        Button {} label: {
            AdjustToolIcon(symbol: isComparing ? "eye.fill" : "eye", highlighted: isComparing)
        }
        .buttonStyle(PressReportingButtonStyle(isPressed: $isComparing))
        .help("Hold to compare with the original")
    }
}

private struct AdjustToolIcon: View {
    let symbol: String
    var highlighted = false
    @State private var hovering = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary.opacity(0.8)))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .glassEffect(.regular.interactive(), in: Circle())
            .scaleEffect(highlighted ? 0.92 : hovering ? 1.06 : 1)
            .animation(Theme.springSnappy, value: hovering)
            .animation(Theme.springSnappy, value: highlighted)
            .onHover { hovering = $0 }
    }
}

/// Mirrors the button's pressed state into a binding (with a tick on press).
private struct PressReportingButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Feedback.shared.tick() }
                withAnimation(.easeOut(duration: 0.12)) { isPressed = pressed }
            }
    }
}
