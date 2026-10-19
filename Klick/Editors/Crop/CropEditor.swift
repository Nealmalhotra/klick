import SwiftUI

/// "Crop Image" card: drag handles over the preview, pick an aspect ratio or
/// type exact pixel sizes, then Apply to save `<name> Cropped.<ext>`.
///
/// With several images the first one is shown and the same crop (the same area, or the
/// same aspect ratio centered on the same spot) is applied to each of them.
enum CropEditor {
    @MainActor static func present(for item: FileItem) {
        present(for: [item])
    }

    @MainActor static func present(for items: [FileItem]) {
        guard let first = items.first else { return }
        guard let model = CropModel(items: items) else {
            Feedback.shared.failure()
            Toast.shared.showMessage("Couldn't open \(first.name)", symbol: "exclamationmark.triangle.fill")
            return
        }
        EditorWindowController.present(width: 360) { close in
            CropEditorView(model: model, close: close)
        }
    }
}

enum CropAspect: String, CaseIterable, Hashable {
    case free = "Free", square = "1:1", wide = "16:9", tall = "9:16", classic = "4:3", portrait = "3:4"

    /// Width / height in pixels, nil when unconstrained.
    var ratio: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .wide: return 16 / 9
        case .tall: return 9 / 16
        case .classic: return 4 / 3
        case .portrait: return 3 / 4
        }
    }
}

@MainActor
final class CropModel: ObservableObject {
    /// Every image the crop applies to; the first one is previewed.
    let items: [FileItem]
    var item: FileItem { items[0] }
    let preview: CGImage
    /// Full-resolution pixel size (orientation applied).
    let pixelSize: CGSize

    /// Crop rectangle in normalized image coordinates (origin top-left, 0...1).
    @Published var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var aspect: CropAspect = .free {
        didSet { if aspect != oldValue { applyAspect() } }
    }
    @Published var isSaving = false
    @Published var error: String?

    init?(items: [FileItem]) {
        guard let item = items.first,
              let preview = try? ImageIOKit.loadImage(item.url, maxPixelSize: 1400),
              let size = ImageIOKit.orientedPixelSize(item.url), size.width > 0, size.height > 0
        else { return nil }
        self.items = items
        self.preview = preview
        self.pixelSize = size
    }

    var isBatch: Bool { items.count > 1 }

    /// Smallest crop side, in normalized units.
    var minSide: CGSize {
        CGSize(width: min(1, 16 / pixelSize.width), height: min(1, 16 / pixelSize.height))
    }

    var pixelWidth: Int {
        get { Int((rect.width * pixelSize.width).rounded()) }
        set { setPixelSize(width: CGFloat(newValue), height: nil) }
    }

    var pixelHeight: Int {
        get { Int((rect.height * pixelSize.height).rounded()) }
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
        // Largest rect with that pixel ratio that fits in the current crop's bounding area (or the image).
        var w = rect.width * pixelSize.width
        var h = w / ratio
        if h > rect.height * pixelSize.height {
            h = rect.height * pixelSize.height
            w = h * ratio
        }
        if w < pixelSize.width * 0.25 && h < pixelSize.height * 0.25 {
            // Tiny selection: start from the whole image instead.
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
        w = min(max(w, 16), pixelSize.width)
        h = min(max(h, 16), pixelSize.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let size = CGSize(width: w / pixelSize.width, height: h / pixelSize.height)
        withAnimation(Theme.springSoft) {
            rect = clamped(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        }
    }

    /// Keeps the rect inside the image by shifting it (size preserved when possible).
    func clamped(_ r: CGRect) -> CGRect {
        var r = r
        r.size.width = min(r.width, 1)
        r.size.height = min(r.height, 1)
        r.origin.x = min(max(r.origin.x, 0), 1 - r.width)
        r.origin.y = min(max(r.origin.y, 0), 1 - r.height)
        return r
    }

    // MARK: Export

    func apply(close: @escaping () -> Void) {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        let items = items
        let crop = rect
        let ratio = aspect.ratio
        let reference = pixelSize
        Task.detached(priority: .userInitiated) {
            var saved = 0
            var failure: Error?
            for item in items {
                do {
                    try Self.crop(item, to: crop, ratio: ratio, reference: reference)
                    saved += 1
                } catch {
                    failure = error
                    NSLog("%@", "Klick: crop failed for \(item.url.path): \(error)")
                }
            }
            let savedCount = saved
            let finalError = failure
            await MainActor.run {
                if savedCount == 0, let finalError {
                    self.isSaving = false
                    self.error = finalError.localizedDescription
                    Feedback.shared.failure()
                    return
                }
                Feedback.shared.success()
                if items.count > 1 {
                    Toast.shared.showMessage(savedCount == items.count ? "\(savedCount) images cropped" : "\(savedCount) of \(items.count) cropped")
                }
                close()
            }
        }
    }

    /// Crops one image and saves `<name> Cropped.<ext>` next to it.
    /// Animated GIFs are cropped frame by frame and stay animated.
    nonisolated private static func crop(_ item: FileItem, to crop: CGRect, ratio: CGFloat?, reference: CGSize) throws {
        if AnimatedGIF.isAnimated(item.url) {
            let output = OutputNaming.url(for: item.url, suffix: "Cropped", ext: "gif")
            try AnimatedGIF.rewrite(item.url, to: output) { frame in
                let size = CGSize(width: frame.width, height: frame.height)
                guard let cropped = frame.cropping(to: Self.pixelRect(for: crop, ratio: ratio, reference: reference, in: size)) else {
                    throw KlickError.failed("Couldn't crop \(item.name)")
                }
                return cropped
            }
            return
        }
        let image = try ImageIOKit.loadImage(item.url)
        let size = CGSize(width: image.width, height: image.height)
        let pixelRect = pixelRect(for: crop, ratio: ratio, reference: reference, in: size)
        guard let cropped = image.cropping(to: pixelRect) else { throw KlickError.failed("Couldn't crop \(item.name)") }
        let format = ImageIOKit.preferredOutputFormat(for: item.url)
        let output = OutputNaming.url(for: item.url, suffix: "Cropped", ext: format.ext)
        try ImageIOKit.write(cropped, to: output, format: format, metadata: ImageIOKit.properties(item.url))
    }

    /// Maps the crop drawn on the reference image onto an image of `size` pixels.
    ///
    /// Free crops keep the same normalized area. A fixed ratio stays exact on every image:
    /// the crop keeps its center and its share of the largest rect of that ratio that fits.
    nonisolated static func pixelRect(for crop: CGRect, ratio: CGFloat?, reference: CGSize, in size: CGSize) -> CGRect {
        let sameShape = abs(reference.width / reference.height - size.width / size.height) < 0.001
        guard let ratio, !sameShape else {
            return CGRect(
                x: (crop.minX * size.width).rounded(), y: (crop.minY * size.height).rounded(),
                width: (crop.width * size.width).rounded(), height: (crop.height * size.height).rounded()
            )
        }
        let referenceMaxWidth = min(reference.width, reference.height * ratio)
        let share = min(crop.width * reference.width / referenceMaxWidth, 1)
        let width = max((share * min(size.width, size.height * ratio)).rounded(), 1)
        let height = max(min((width / ratio).rounded(), size.height), 1)
        let x = min(max(crop.midX * size.width - width / 2, 0), size.width - width)
        let y = min(max(crop.midY * size.height - height / 2, 0), size.height - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }
}

// MARK: - View

struct CropEditorView: View {
    @ObservedObject var model: CropModel
    let close: () -> Void

    var body: some View {
        EditorShell(title: model.isBatch ? "Crop \(model.items.count) Images" : "Crop Image", onClose: close) {
            VStack(spacing: 16) {
                CropCanvas(model: model)
                    .frame(height: canvasHeight)

                HStack {
                    EditorSectionLabel(title: "Aspect ratio")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: CropAspect.allCases, selection: $model.aspect, label: \.rawValue, compact: true)
                        .fixedSize()
                }

                HStack(spacing: 10) {
                    if model.isBatch {
                        BatchHint(count: model.items.count)
                    } else {
                        PixelField(prefix: "W", value: Binding(get: { model.pixelWidth }, set: { model.pixelWidth = $0 }))
                        PixelField(prefix: "H", value: Binding(get: { model.pixelHeight }, set: { model.pixelHeight = $0 }))
                        Text("px")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let error = model.error {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
                    }
                }
            }
        } footer: {
            KlickSecondaryButton(title: "Reset") { model.reset() }
            Spacer()
            KlickPrimaryButton(title: "Apply", isBusy: model.isSaving) {
                model.apply(close: close)
            }
        }
    }

    /// Preview height follows the image aspect (portrait pages get a taller canvas).
    private var canvasHeight: CGFloat {
        let width: CGFloat = 324
        let aspect = model.pixelSize.height / model.pixelSize.width
        return min(max(width * aspect, 180), 430)
    }
}

/// "Applies to N images" capsule shown instead of the pixel fields when cropping a batch.
private struct BatchHint: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo.stack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Applies to \(count) images")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(0.8))
        }
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .help("The same crop is applied to every selected image")
    }
}

/// Image + dimmed outside + draggable frame with accent corner/edge handles.
private struct CropCanvas: View {
    @ObservedObject var model: CropModel

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let frame = imageFrame(in: geo.size)
            let crop = viewRect(model.rect, in: frame)

            ZStack(alignment: .topLeading) {
                Image(decorative: model.preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)

                // Dim everything outside the crop.
                Path { path in
                    path.addRect(frame)
                    path.addRect(crop)
                }
                .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                // Rule-of-thirds guides while dragging.
                if dragStart != nil {
                    ThirdsGrid()
                        .stroke(Color.white.opacity(0.55), lineWidth: 0.5)
                        .frame(width: crop.width, height: crop.height)
                        .offset(x: crop.minX, y: crop.minY)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1)
                    .frame(width: crop.width, height: crop.height)
                    .offset(x: crop.minX, y: crop.minY)
                    .contentShape(Rectangle())
                    .gesture(moveGesture(frame: frame))

                ForEach(Handle.allCases, id: \.self) { handle in
                    handleView(handle)
                        .position(position(of: handle, in: crop))
                        .gesture(resizeGesture(handle, frame: frame))
                }
            }
            .animation(.easeOut(duration: 0.15), value: dragStart != nil)
        }
    }

    // MARK: Geometry

    private func imageFrame(in size: CGSize) -> CGRect {
        let aspect = model.pixelSize.width / model.pixelSize.height
        var w = size.width
        var h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func viewRect(_ r: CGRect, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
               width: r.width * frame.width, height: r.height * frame.height)
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

    private func moveGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStart == nil { dragStart = model.rect }
                guard let start = dragStart else { return }
                var r = start
                r.origin.x += value.translation.width / frame.width
                r.origin.y += value.translation.height / frame.height
                model.rect = model.clamped(r)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = model.rect }
                guard let start = dragStart else { return }
                model.rect = resized(start, handle: handle,
                                     dx: value.translation.width / frame.width,
                                     dy: value.translation.height / frame.height)
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
        let k = ratio * model.pixelSize.height / model.pixelSize.width // normalized width / height
        switch handle {
        case .top, .bottom:
            // Height drives width, centered horizontally.
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

private struct ThirdsGrid: Shape {
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
