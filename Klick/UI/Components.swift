import SwiftUI

// MARK: - Editor shell

/// The chrome shared by every floating editor ("Crop Image", "Add BG", ...):
/// a rounded Liquid Glass card with a centered title, a round close button,
/// the editor body and a footer with secondary/primary actions.
struct EditorShell<Content: View, Footer: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                HStack {
                    CloseButton(action: onClose)
                    Spacer()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)

            HairlineDivider()

            content
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

            HairlineDivider()

            HStack(spacing: 10) { footer }
                .padding(.horizontal, 16)
                .frame(height: 58)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.windowCornerRadius, style: .continuous))
    }
}

struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
    }
}

struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(
            Circle().fill(Color.primary.opacity(hovering ? 0.14 : 0.07))
        )
        .scaleEffect(hovering ? 1.06 : 1)
        .animation(Theme.springSnappy, value: hovering)
        .onHover { hovering = $0 }
        .keyboardShortcut(.cancelAction)
        .help("Close")
    }
}

// MARK: - Buttons

struct KlickPrimaryButton: View {
    let title: String
    var isBusy: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 34)
            .animation(Theme.springSnappy, value: isBusy)
        }
        .buttonStyle(AccentCapsuleButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
        .allowsHitTesting(!isBusy)
        .fixedSize()
    }
}

/// Saturated accent capsule with a glassy top sheen and a springy press.
struct AccentCapsuleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                Capsule()
                    .fill(Theme.accentGradient)
                    .overlay(
                        Capsule().fill(
                            LinearGradient(colors: [Color.white.opacity(hovering ? 0.34 : 0.26), .clear], startPoint: .top, endPoint: .center)
                        )
                    )
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                    .shadow(color: Theme.accent.opacity(isEnabled ? 0.38 : 0), radius: configuration.isPressed ? 3 : 8, y: configuration.isPressed ? 1 : 3)
            )
            .glassEffect(.regular.tint(Theme.accent.opacity(0.0)).interactive(), in: Capsule())
            .opacity(isEnabled ? 1 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.02 : 1))
            .animation(Theme.springSnappy, value: configuration.isPressed)
            .animation(Theme.springSnappy, value: hovering)
            .onHover { hovering = $0 }
    }
}

struct KlickSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 4)
                .frame(minHeight: 22)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .fixedSize()
    }
}

// MARK: - Segmented picker

/// Capsule segmented control with a sliding accent thumb (Free · 1:1 · 16:9 ...).
struct AccentSegmentedPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var compact: Bool = false

    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let selected = option == selection
                Button {
                    withAnimation(Theme.springSnappy) { selection = option }
                    Feedback.shared.tick()
                } label: {
                    Text(label(option))
                        .font(.system(size: compact ? 11 : 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, compact ? 6 : 10)
                        .frame(maxWidth: .infinity, minHeight: compact ? 24 : 28)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.accentGradient)
                                    .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 2)
                                    .matchedGeometryEffect(id: "thumb", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                if index < options.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(separatorVisible(after: index) ? 0.12 : 0))
                        .frame(width: 1, height: 14)
                }
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func separatorVisible(after index: Int) -> Bool {
        guard let selectedIndex = options.firstIndex(of: selection) else { return true }
        return index != selectedIndex && index + 1 != selectedIndex
    }
}

// MARK: - Slider row

/// "Padding ——●———— 160 px"
struct ValueSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = "px"
    var labelWidth: CGFloat = 64
    var format: (Double) -> String = { String(Int($0.rounded())) }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(Theme.accent)
                .controlSize(.small)
            Text("\(format(value)) \(unit)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

// MARK: - Pixel field

/// Small rounded numeric field used for W/H inputs.
struct PixelField: View {
    let prefix: String
    @Binding var value: Int
    var onCommit: () -> Void = {}

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(prefix)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 8)
                .frame(width: 72, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(focused ? 0.95 : 0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(focused ? Theme.accent.opacity(0.8) : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1)
                )
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { _, newValue in
            if !focused { text = String(newValue) }
        }
    }

    private func commit() {
        if let parsed = Int(text.filter(\.isNumber)), parsed > 0 {
            value = parsed
            onCommit()
        }
        text = String(value)
    }
}

// MARK: - Section label

struct EditorSectionLabel: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Checkerboard (transparency backdrop)

struct CheckerboardView: View {
    var size: CGFloat = 8
    var body: some View {
        Canvas { context, canvasSize in
            let cols = Int(ceil(canvasSize.width / size))
            let rows = Int(ceil(canvasSize.height / size))
            for row in 0..<rows {
                for col in 0..<cols where (row + col).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(col) * size, y: CGFloat(row) * size, width: size, height: size)
                    context.fill(Path(rect), with: .color(Color.primary.opacity(0.08)))
                }
            }
        }
    }
}
