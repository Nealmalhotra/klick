import SwiftUI

/// The radial "weapon wheel": a Liquid Glass disk with rounded segments,
/// a hub pill that mirrors the hovered action, and page dots.
struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.colorScheme) private var scheme

    private var shown: Bool { model.phase == .shown }

    var body: some View {
        ZStack {
            disk

            ZStack {
                ForEach(Array(model.actions.enumerated()), id: \.offset) { index, action in
                    WheelSegment(
                        index: index,
                        count: model.actions.count,
                        action: action,
                        isHovered: model.hovered == index,
                        labelsVisible: shown
                    )
                }
            }
            .id(model.pageToken)
            .transition(pageTransition)

            hub
        }
        .frame(width: WheelMetrics.diameter, height: WheelMetrics.diameter)
        .compositingGroup()
        .shadow(color: .black.opacity(shown ? 0.22 : 0), radius: 26, y: 12)
        .scaleEffect(scale)
        .opacity(opacity)
        .blur(radius: blur)
        .animation(entryAnimation, value: model.phase)
        .frame(width: WheelMetrics.panelSize, height: WheelMetrics.panelSize)
    }

    // MARK: Layers

    private var disk: some View {
        Circle()
            .fill(Color.white.opacity(scheme == .dark ? 0.04 : 0.10))
            .glassEffect(scheme == .dark ? .regular : .clear, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.75), Color.white.opacity(0.18), Color.white.opacity(0.45)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 1.5
                    )
            )
    }

    private var hub: some View {
        ZStack {
            // Recessed well.
            Circle()
                .fill(
                    RadialGradient(
                        colors: scheme == .dark
                            ? [Color.black.opacity(0.10), Color.black.opacity(0.28)]
                            : [Color.black.opacity(0.05), Color.black.opacity(0.16)],
                        center: .center, startRadius: 10, endRadius: WheelMetrics.hubRadius
                    )
                )
                .frame(width: WheelMetrics.hubRadius * 2, height: WheelMetrics.hubRadius * 2)
            // Bright rim.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.45 : 0.85), Color.white.opacity(scheme == .dark ? 0.15 : 0.35)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 2.5
                )
                .frame(width: WheelMetrics.hubRadius * 2, height: WheelMetrics.hubRadius * 2)

            HubPill(text: model.hubText, highlighted: model.hovered != nil)
                .opacity(shown ? 1 : 0)
                .animation(.easeOut(duration: 0.18).delay(shown ? 0.05 : 0), value: shown)

            if model.pages.count > 1 {
                PageDots(count: model.pages.count, index: model.pageIndex)
                    .offset(y: 32)
                    .opacity(shown ? 1 : 0)
            }
        }
    }

    // MARK: Animation

    private var scale: CGFloat {
        switch model.phase {
        case .hidden: return 0.3
        case .shown: return 1
        case .dismissing(let committed): return committed ? 1.05 : 0.86
        }
    }

    private var opacity: Double {
        model.phase == .shown ? 1 : 0
    }

    private var blur: CGFloat {
        switch model.phase {
        case .shown: return 0
        case .hidden: return 10
        case .dismissing: return 4
        }
    }

    private var entryAnimation: Animation {
        switch model.phase {
        case .shown: return .spring(response: 0.24, dampingFraction: 0.74)
        case .dismissing(let committed): return .easeOut(duration: committed ? 0.1 : 0.14)
        case .hidden: return .linear(duration: 0)
        }
    }

    /// Quick cross-fade with a subtle zoom (glass doesn't follow rotation transforms well).
    private var pageTransition: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: PageFlipModifier(scale: 0.92, opacity: 0),
                identity: PageFlipModifier(scale: 1, opacity: 1)
            ),
            removal: .modifier(
                active: PageFlipModifier(scale: 1.04, opacity: 0),
                identity: PageFlipModifier(scale: 1, opacity: 1)
            )
        )
    }
}

private struct PageFlipModifier: ViewModifier {
    let scale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .opacity(opacity)
    }
}

// MARK: - Segment

private struct WheelSegment: View {
    @Environment(\.colorScheme) private var scheme
    let index: Int
    let count: Int
    let action: KlickAction
    let isHovered: Bool
    let labelsVisible: Bool

    private var shape: WheelSegmentShape { WheelSegmentShape(index: index, count: count) }

    var body: some View {
        let outward = WheelSegmentShape.outwardVector(index: index, count: count)
        let pop: CGFloat = isHovered ? 5 : 0

        ZStack {
            // Frosted resting state.
            shape
                .fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color.white.opacity(0.16), Color.white.opacity(0.07)]
                            : [Color.white.opacity(0.52), Color.white.opacity(0.30)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .glassEffect(scheme == .dark ? .regular.tint(Color.white.opacity(0.04)) : .clear, in: shape)
                .overlay(shape.stroke(Color.white.opacity(scheme == .dark ? 0.22 : 0.6), lineWidth: 1))
                .opacity(isHovered ? 0 : 1)

            // Hovered state: saturated accent "jelly".
            shape
                .fill(Theme.accentGradient)
                .overlay(
                    shape.fill(
                        LinearGradient(colors: [Color.white.opacity(0.32), .clear], startPoint: .top, endPoint: .center)
                    )
                )
                .overlay(shape.stroke(Color.white.opacity(0.45), lineWidth: 1))
                .shadow(color: Theme.accent.opacity(0.55), radius: 14, y: 4)
                .opacity(isHovered ? 1 : 0)

            label
                .offset(WheelSegmentShape.labelOffset(index: index, count: count))
                .opacity(labelsVisible ? 1 : 0)
                .animation(.easeOut(duration: 0.16).delay(labelsVisible ? 0.06 : 0), value: labelsVisible)
        }
        .scaleEffect(isHovered ? 1.035 : 1)
        .offset(x: outward.width * pop, y: outward.height * pop)
        .animation(.spring(response: 0.22, dampingFraction: 0.62), value: isHovered)
    }

    private var label: some View {
        VStack(spacing: 4) {
            if let symbol = action.symbol {
                Image(systemName: symbol)
                    .font(.system(size: count > 8 ? 15 : 17, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
            }
            Text(action.title)
                .font(.system(size: titleSize, weight: .bold, design: .default))
                .tracking(action.symbol == nil ? 0.4 : 0.7)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(isHovered ? Color.white : (scheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.78)))
        .frame(width: labelWidth)
        .shadow(color: isHovered ? .black.opacity(0.18) : .clear, radius: 2, y: 1)
    }

    /// Room across the segment at the label's radius, so crowded wheels shrink labels instead of overlapping.
    private var labelWidth: CGFloat {
        let radius = (WheelMetrics.segmentInnerRadius + WheelMetrics.segmentOuterRadius) / 2
        return min(84, 2 * .pi * radius / CGFloat(max(count, 1)) - 4)
    }

    private var titleSize: CGFloat {
        if action.symbol != nil { return count > 8 ? 9.5 : 10.5 }
        switch count {
        case ...4: return 17
        case 5...6: return 15.5
        case 7...8: return 14.5
        default: return 13
        }
    }
}

// MARK: - Hub pill

private struct HubPill: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.95) : Color.black.opacity(0.78))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 10)
            .frame(width: 84, height: 40)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color.white.opacity(0.24), Color.white.opacity(0.12)]
                            : [Color.white.opacity(0.66), Color.white.opacity(0.46)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            )
            .glassEffect(scheme == .dark ? .regular.tint(Color.white.opacity(0.05)) : .clear, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(scheme == .dark ? 0.3 : 0.7), lineWidth: 1))
            .scaleEffect(highlighted ? 1.04 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: highlighted)
    }
}

private struct PageDots: View {
    let count: Int
    let index: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(i == index ? 0.95 : 0.45))
                    .frame(width: i == index ? 10 : 4, height: 4)
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: index)
    }
}
