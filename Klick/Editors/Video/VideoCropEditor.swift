import SwiftUI

/// "Crop Video": drag the frame over the (playable) video, pick an aspect ratio or type
/// exact pixel sizes, then Save `<name> Cropped.<ext>` (re-encoded).
enum VideoCropEditor {
    private static let reservedHeight: CGFloat = 340

    @MainActor static func present(for item: FileItem) {
        VideoClip.open(item) { clip in
            let stage = VideoEditorLayout.stageSize(for: clip.pixelSize, reservedHeight: reservedHeight)
            EditorWindowController.present(width: VideoEditorLayout.cardWidth) { close in
                VideoCropView(clip: clip, stageSize: stage, close: close)
            }
        }
    }
}

/// Aspect presets, as offered for social formats.
enum VideoCropAspect: String, CaseIterable, Hashable {
    case free = "Free", square = "1:1", wide = "16:9", tall = "9:16", portrait = "4:5"

    /// Width / height in pixels, nil when unconstrained.
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .wide: return 16 / 9
        case .tall: return 9 / 16
        case .portrait: return 4 / 5
        }
    }
}

@MainActor
final class VideoCropModel: ObservableObject {
    /// Displayed video size in pixels.
    let pixelSize: CGSize

    /// Crop rectangle in normalized video coordinates (origin top-left, 0...1).
    @Published var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var aspect: VideoCropAspect = .free {
        didSet { if aspect != oldValue { applyAspect() } }
    }

    init(pixelSize: CGSize) {
        self.pixelSize = pixelSize
    }

    var isWholeFrame: Bool { rect.width > 0.999 && rect.height > 0.999 }

    /// Smallest crop side, in normalized units.
    var minSide: CGSize {
        CGSize(width: min(1, 32 / pixelSize.width), height: min(1, 32 / pixelSize.height))
    }

    /// Output size: encoders want even pixel counts.
    var pixelWidth: Int {
        get { Int(VideoExport.even(rect.width * pixelSize.width)) }
        set { setPixelSize(width: CGFloat(newValue), height: nil) }
    }

    var pixelHeight: Int {
        get { Int(VideoExport.even(rect.height * pixelSize.height)) }
        set { setPixelSize(width: nil, height: CGFloat(newValue)) }
    }

    func reset() {
        withAnimation(Theme.springSoft) {
            aspect = .free
            rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    /// Re-fits the crop to the chosen ratio, keeping its center.
    private func applyAspect() {
        guard let ratio = aspect.ratio else { return }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var w = rect.width * pixelSize.width
        var h = w / ratio
        if h > rect.height * pixelSize.height {
            h = rect.height * pixelSize.height
            w = h * ratio
        }
        if w < pixelSize.width * 0.25 && h < pixelSize.height * 0.25 {
            // Tiny selection: start from the whole frame instead.
            w = pixelSize.width
            h = w / ratio
            if h > pixelSize.height { h = pixelSize.height; w = h * ratio }
        }
        let size = CGSize(width: w / pixelSize.width, height: h / pixelSize.height)
        withAnimation(Theme.springSoft) {
            rect = clamped(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    private func setPixelSize(width: CGFloat?, height: CGFloat?) {
        var w = width ?? rect.width * pixelSize.width
        var h = height ?? rect.height * pixelSize.height
        if let ratio = aspect.ratio {
            if width != nil { h = w / ratio } else { w = h * ratio }
        }
        w = min(max(w, 32), pixelSize.width)
        h = min(max(h, 32), pixelSize.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let size = CGSize(width: w / pixelSize.width, height: h / pixelSize.height)
        withAnimation(Theme.springSoft) {
            rect = clamped(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    /// Keeps the rect inside the frame by shifting it (size preserved when possible).
    func clamped(_ r: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.width, 1)
        r.size.height = min(r.height, 1)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        return r
    }
}

// MARK: - View

struct VideoCropView: View {
    @ObservedObject var clip: VideoClip
    let stageSize: CGSize
    let close: () -> Void

    @StateObject private var model: VideoCropModel

    init(clip: VideoClip, stageSize: CGSize, close: @escaping () -> Void) {
        self.clip = clip
        self.stageSize = stageSize
        self.close = close
        _model = StateObject(wrappedValue: VideoCropModel(pixelSize: clip.pixelSize))
    }

    var body: some View {
        EditorShell(title: "Crop Video", onClose: dismiss) {
            VStack(spacing: 14) {
                VideoStage(clip: clip, size: stageSize) {
                    VideoCropOverlay(model: model, size: stageSize)
                }

                HStack(spacing: 10) {
                    VideoPlayButton(clip: clip)
                    VideoTimeline(clip: clip)
                }

                HStack {
                    EditorSectionLabel(title: "Aspect ratio")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: VideoCropAspect.allCases, selection: $model.aspect, label: \.rawValue, compact: true)
                        .frame(width: 260)
                }

                HStack(spacing: 10) {
                    PixelField(prefix: "W", value: Binding(get: { model.pixelWidth }, set: { model.pixelWidth = $0 }))
                    PixelField(prefix: "H", value: Binding(get: { model.pixelHeight }, set: { model.pixelHeight = $0 }))
                    Text("px")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(verbatim: "of \(Int(clip.pixelSize.width)) × \(Int(clip.pixelSize.height))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        } footer: {
            KlickSecondaryButton(title: "Reset") { model.reset() }
                .disabled(model.isWholeFrame && model.aspect == .free)
            Spacer()
            KlickPrimaryButton(title: "Save", isEnabled: !model.isWholeFrame, action: save)
        }
        .background(EditorCanvas.KeyInterceptor(handler: clip.handleKey))
    }

    private func dismiss() {
        clip.shutdown()
        close()
    }

    private func save() {
        guard !model.isWholeFrame else { return }
        let item = clip.item
        let crop = model.rect
        dismiss()
        VideoJob.start("Cropping video", item: item) { progress in
            [try await VideoTools.crop(item, to: crop, progress: progress)]
        }
    }
}

/// Dimmed outside + draggable frame with accent corner / edge handles, over the video.
private struct VideoCropOverlay: View {
    @ObservedObject var model: VideoCropModel
    let size: CGSize

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    @State private var dragStart: CGRect?

    var body: some View {
        let frame = CGRect(origin: .zero, size: size)
        let crop = viewRect(model.rect)

        ZStack(alignment: .topLeading) {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(frame)
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .clipShape(RoundedRectangle(cornerRadius: EditorCanvas.cornerRadius, style: .continuous))
            .allowsHitTesting(false)

            // Rule-of-thirds guides while dragging.
            if dragStart != nil {
                VideoThirdsGrid()
                    .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
                    .frame(width: crop.width, height: crop.height)
                    .offset(x: crop.minX, y: crop.minY)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            Rectangle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: crop.width, height: crop.height)
                .contentShape(Rectangle())
                .offset(x: crop.minX, y: crop.minY)
                .gesture(moveGesture)

            ForEach(Handle.allCases, id: \.self) { handle in
                handleView(handle)
                    .position(position(of: handle, in: crop))
                    .gesture(resizeGesture(handle))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeOut(duration: 0.15), value: dragStart != nil)
    }

    // MARK: Geometry

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }

    private func position(of handle: Handle, in r: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: r.minX, y: r.minY)
        case .top: return CGPoint(x: r.midX, y: r.minY)
        case .topRight: return CGPoint(x: r.maxX, y: r.minY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: return CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func handleView(_ handle: Handle) -> some View {
        let isCorner = [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(handle)
        let size: CGSize = switch handle {
        case .top, .bottom: CGSize(width: 24, height: 5)
        case .left, .right: CGSize(width: 5, height: 24)
        default: CGSize(width: 12, height: 12)
        }
        let shape = RoundedRectangle(cornerRadius: isCorner ? 3 : 2.5, style: .continuous)
        return shape
            .fill(Theme.accentGradient)
            .overlay(shape.stroke(Color.white.opacity(0.9), lineWidth: 1))
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }

    // MARK: Gestures

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = model.rect }
                guard let start = dragStart else { return }
                var r = start
                r.origin.x += value.translation.width / size.width
                r.origin.y += value.translation.height / size.height
                model.rect = model.clamped(r)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = model.rect }
                guard let start = dragStart else { return }
                model.rect = resized(start, handle: handle,
                                     dx: value.translation.width / size.width,
                                     dy: value.translation.height / size.height)
            }
            .onEnded { _ in
                dragStart = nil
                Feedback.shared.tick()
            }
    }

    /// New rect after dragging `handle`, honouring bounds, minimum size and aspect lock.
    private func resized(_ start: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        let minW = model.minSide.width, minH = model.minSide.height
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY

        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(max(start.minX + dx, 0), maxX - minW)
        case .topRight, .right, .bottomRight: maxX = max(min(start.maxX + dx, 1), minX + minW)
        default: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(max(start.minY + dy, 0), maxY - minH)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(min(start.maxY + dy, 1), minY + minH)
        default: break
        }

        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio = model.aspect.ratio else { return r }

        // Convert the pixel ratio to normalized units.
        let k = ratio * model.pixelSize.height / model.pixelSize.width
        switch handle {
        case .top, .bottom:
            var w = r.height * k
            if w > 1 { w = 1; r.size.height = w / k }
            r.origin.x = min(max(start.midX - w / 2, 0), 1 - w)
            r.size.width = w
            if handle == .top { r.origin.y = start.maxY - r.height }
        case .left, .right:
            var h = r.width / k
            if h > 1 { h = 1; r.size.width = h * k }
            r.origin.y = min(max(start.midY - h / 2, 0), 1 - h)
            r.size.height = h
            if handle == .left { r.origin.x = start.maxX - r.width }
        default:
            // Corners: the dominant axis wins, the opposite corner stays anchored.
            let anchor = CGPoint(
                x: [.topLeft, .bottomLeft].contains(handle) ? start.maxX : start.minX,
                y: [.topLeft, .topRight].contains(handle) ? start.maxY : start.minY
            )
            var w = r.width, h = r.height
            if w / k > h { h = w / k } else { w = h * k }
            let maxW = [.topLeft, .bottomLeft].contains(handle) ? anchor.x : 1 - anchor.x
            let maxH = [.topLeft, .topRight].contains(handle) ? anchor.y : 1 - anchor.y
            if w > maxW { w = maxW; h = w / k }
            if h > maxH { h = maxH; w = h * k }
            r = CGRect(
                x: [.topLeft, .bottomLeft].contains(handle) ? anchor.x - w : anchor.x,
                y: [.topLeft, .topRight].contains(handle) ? anchor.y - h : anchor.y,
                width: w, height: h
            )
        }
        return model.clamped(r)
    }
}

private struct VideoThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
            p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
    }
}
