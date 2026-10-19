import SwiftUI

/// A cut point placed in the Split editor.
struct VideoSplitMarker: Identifiable, Equatable {
    let id = UUID()
    var time: Double
}

/// Filmstrip under the video. Click or drag anywhere to scrub; depending on the editor it
/// also carries trim handles (Trim) or split markers (Split).
struct VideoTimeline: View {
    @ObservedObject var clip: VideoClip
    /// Kept range, in seconds; shows the trim frame and its handles.
    var trim: Binding<ClosedRange<Double>>?
    /// Split points; dragged sideways, selected with a click.
    var markers: Binding<[VideoSplitMarker]>?
    var selectedMarker: Binding<VideoSplitMarker.ID?>?
    /// Markers the editor places itself (equal parts): drawn, but not draggable.
    var markersLocked = false

    static let stripHeight: CGFloat = 44
    /// Room above and below the strip for the playhead and the marker knobs.
    private static let margin: CGFloat = 7
    private static let handleWidth: CGFloat = 14
    private static let cornerRadius: CGFloat = 8
    static let height = stripHeight + margin * 2

    private enum Drag: Equatable {
        case none, scrub
        case trimStart(grab: CGFloat)
        case trimEnd(grab: CGFloat)
        case marker(VideoSplitMarker.ID)
    }

    @State private var drag = Drag.none

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                filmstrip(width: width)
                    .offset(x: inset, y: Self.margin)
                if let range = trim?.wrappedValue {
                    trimFrame(range, width: width)
                        .offset(y: Self.margin)
                }
                if let markers = markers?.wrappedValue {
                    ForEach(markers) { marker in
                        markerView(marker, selected: selectedMarker?.wrappedValue == marker.id)
                            .position(x: x(marker.time, width), y: Self.height / 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                playhead
                    .position(x: x(clip.time, width), y: Self.height / 2)
                EditorCanvas.MouseInput(
                    onDown: { pointerDown(at: $0, width: width) },
                    onDrag: { pointerDragged(to: $0, width: width) },
                    onUp: { _ in pointerUp() },
                    cursor: { cursor(at: $0, width: width) }
                )
            }
            .onAppear { clip.loadThumbnails(count: thumbnailCount(width: width), height: Self.stripHeight) }
        }
        .frame(height: Self.height)
    }

    // MARK: Pieces

    private func filmstrip(width: CGFloat) -> some View {
        let stripWidth = width - inset * 2
        let count = max(clip.thumbnails.count, 1)
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return HStack(spacing: 0) {
            ForEach(clip.thumbnails.indices, id: \.self) { index in
                ZStack {
                    if let image = clip.thumbnails[index] {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                }
                .frame(width: stripWidth / CGFloat(count), height: Self.stripHeight)
                .clipped()
            }
        }
        .frame(width: stripWidth, height: Self.stripHeight, alignment: .leading)
        .background(Color.primary.opacity(0.08))
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
    }

    /// Dims what gets cut and frames what stays, with grip handles hanging outside the range.
    private func trimFrame(_ range: ClosedRange<Double>, width: CGFloat) -> some View {
        let x0 = x(range.lowerBound, width), x1 = x(range.upperBound, width)
        let h = Self.stripHeight
        let hw = Self.handleWidth
        let r = Self.cornerRadius
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(x: inset, y: 0, width: max(0, x0 - inset), height: h))
                path.addRect(CGRect(x: x1, y: 0, width: max(0, width - inset - x1), height: h))
            }
            .fill(Color.black.opacity(0.55))

            ZStack {
                RoundedRectangle(cornerRadius: r, style: .continuous)
                    .strokeBorder(Theme.accentGradient, lineWidth: 3)
                HStack(spacing: 0) {
                    grip(UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r, style: .continuous), chevron: "chevron.compact.left")
                    Spacer(minLength: 0)
                    grip(UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous), chevron: "chevron.compact.right")
                }
            }
            .frame(width: x1 - x0 + hw * 2, height: h)
            .shadow(color: Theme.accent.opacity(0.35), radius: 4, y: 1)
            .offset(x: x0 - hw)
        }
        .frame(width: width, height: h, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func grip(_ shape: UnevenRoundedRectangle, chevron: String) -> some View {
        shape
            .fill(Theme.accentGradient)
            .frame(width: Self.handleWidth)
            .overlay {
                Image(systemName: chevron)
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white)
            }
    }

    private var playhead: some View {
        Capsule()
            .fill(Color.white)
            .frame(width: 3, height: Self.height - 2)
            .shadow(color: .black.opacity(0.45), radius: 1.5)
            .allowsHitTesting(false)
    }

    private func markerView(_ marker: VideoSplitMarker, selected: Bool) -> some View {
        let color = selected ? Theme.accent : Color.white
        return VStack(spacing: 0) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 1.5))
                .frame(width: 12, height: 12)
                .overlay {
                    Image(systemName: "scissors")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(selected ? Color.white : Color.black.opacity(0.7))
                }
            Rectangle()
                .fill(color)
                .frame(width: 2)
        }
        .frame(width: 12, height: Self.height - 2)
        .shadow(color: .black.opacity(0.4), radius: 1.5)
        .allowsHitTesting(false)
    }

    // MARK: Geometry

    /// Horizontal room kept free for the trim handles at both ends.
    private var inset: CGFloat { trim == nil ? 0 : Self.handleWidth }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        inset + CGFloat(time / max(clip.duration, 0.001)) * (width - inset * 2)
    }

    private func time(at x: CGFloat, _ width: CGFloat) -> Double {
        let fraction = Double((x - inset) / max(width - inset * 2, 1))
        return min(max(fraction, 0), 1) * clip.duration
    }

    private func thumbnailCount(width: CGFloat) -> Int {
        let aspect = clip.pixelSize.width / max(clip.pixelSize.height, 1)
        return max(1, Int(((width - inset * 2) / (Self.stripHeight * aspect)).rounded(.up)))
    }

    /// Shortest selection: one frame, at least a tenth of a second.
    private var minimumLength: Double { max(0.1, clip.info.frameDuration.seconds) }

    // MARK: Pointer

    private func hit(at point: CGPoint, width: CGFloat) -> Drag {
        if let range = trim?.wrappedValue {
            let x0 = x(range.lowerBound, width), x1 = x(range.upperBound, width)
            let nearStart = point.x >= x0 - Self.handleWidth - 4 && point.x <= x0 + 4
            let nearEnd = point.x >= x1 - 4 && point.x <= x1 + Self.handleWidth + 4
            if nearStart && (!nearEnd || point.x < (x0 + x1) / 2) { return .trimStart(grab: point.x - x0) }
            if nearEnd { return .trimEnd(grab: point.x - x1) }
        }
        if !markersLocked, let markers = markers?.wrappedValue,
           let nearest = markers.min(by: { abs(x($0.time, width) - point.x) < abs(x($1.time, width) - point.x) }),
           abs(x(nearest.time, width) - point.x) <= 7 {
            return .marker(nearest.id)
        }
        return .scrub
    }

    private func pointerDown(at point: CGPoint, width: CGFloat) {
        clip.pause()
        drag = hit(at: point, width: width)
        switch drag {
        case .marker(let id):
            if selectedMarker?.wrappedValue != id {
                withAnimation(Theme.springSnappy) { selectedMarker?.wrappedValue = id }
                Feedback.shared.tick()
            }
        case .scrub:
            if selectedMarker?.wrappedValue != nil {
                withAnimation(Theme.springSnappy) { selectedMarker?.wrappedValue = nil }
            }
            clip.seek(to: time(at: point.x, width))
        default:
            break
        }
    }

    private func pointerDragged(to point: CGPoint, width: CGFloat) {
        switch drag {
        case .none:
            break
        case .scrub:
            clip.seek(to: time(at: point.x, width))
        case .trimStart(let grab):
            guard let range = trim?.wrappedValue else { return }
            let start = min(time(at: point.x - grab, width), range.upperBound - minimumLength)
            trim?.wrappedValue = max(0, start)...range.upperBound
            clip.seek(to: max(0, start))
        case .trimEnd(let grab):
            guard let range = trim?.wrappedValue else { return }
            let end = max(time(at: point.x - grab, width), range.lowerBound + minimumLength)
            trim?.wrappedValue = range.lowerBound...min(end, clip.duration)
            clip.seek(to: min(end, clip.duration))
        case .marker(let id):
            guard let index = markers?.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
            let t = min(max(time(at: point.x, width), minimumLength), clip.duration - minimumLength)
            markers?.wrappedValue[index].time = t
            clip.seek(to: t)
        }
    }

    private func pointerUp() {
        switch drag {
        case .trimStart, .trimEnd, .marker: Feedback.shared.tick()
        default: break
        }
        drag = .none
    }

    private func cursor(at point: CGPoint, width: CGFloat) -> NSCursor {
        switch drag == .none ? hit(at: point, width: width) : drag {
        case .trimStart, .trimEnd, .marker: return .resizeLeftRight
        default: return .arrow
        }
    }
}
