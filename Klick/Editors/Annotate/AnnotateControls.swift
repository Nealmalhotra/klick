import SwiftUI

// Toolbar pieces of the Annotate card.
extension AnnotateView {
    /// Capsule segmented control with a sliding accent thumb, for icon-only options
    /// (tools, stroke sizes).
    struct IconSegmentedPicker<Value: Hashable & Identifiable, Label: View>: View {
        let options: [Value]
        @Binding var selection: Value
        var segmentWidth: CGFloat = 38
        let help: (Value) -> String
        @ViewBuilder let label: (Value) -> Label

        @Namespace private var ns

        var body: some View {
            HStack(spacing: 0) {
                ForEach(options) { option in
                    let selected = option == selection
                    Button {
                        guard option != selection else { return }
                        withAnimation(Theme.springSnappy) { selection = option }
                        Feedback.shared.tick()
                    } label: {
                        label(option)
                            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.72))
                            .frame(width: segmentWidth, height: 28)
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
                    .help(help(option))
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
        }
    }

    /// Round color chips; the selected one gets a ring.
    struct InkColorPicker: View {
        @Binding var selection: InkColor

        var body: some View {
            HStack(spacing: 2) {
                ForEach(InkColor.allCases) { ink in
                    let selected = ink == selection
                    Button {
                        guard ink != selection else { return }
                        withAnimation(Theme.springSnappy) { selection = ink }
                        Feedback.shared.tick()
                    } label: {
                        Circle()
                            .fill(ink.color)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
                            .frame(width: 18, height: 18)
                            .scaleEffect(selected ? 0.86 : 1)
                            .padding(4)
                            .overlay {
                                Circle()
                                    .strokeBorder(ink == .black || ink == .white ? Color.primary.opacity(0.55) : ink.color, lineWidth: 2)
                                    .opacity(selected ? 1 : 0)
                                    .scaleEffect(selected ? 1 : 0.7)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(ink.title)
                }
            }
        }
    }

    /// Small round glass button with a symbol (undo / redo).
    struct GlassSymbolButton: View {
        let symbol: String
        let help: String
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(help)
        }
    }
}
