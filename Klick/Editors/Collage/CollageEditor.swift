import AppKit
import SwiftUI

/// "Collage" card: lays two or more pictures out as a mosaic, grid, row or column with
/// spacing, rounded corners and a background, then saves `Collage.png` (or JPG) next
/// to the first picture.
enum CollageEditor {
    @MainActor static func present(for items: [FileItem]) {
        guard let model = CollageModel(items: items) else {
            Feedback.shared.failure()
            Toast.shared.showMessage("Pick at least two images", symbol: "exclamationmark.triangle.fill")
            return
        }
        EditorWindowController.present(width: 440) { close in
            CollageEditorView(model: model, close: close)
        }
    }
}

// MARK: - Options

enum CollageBackground: Hashable {
    case transparent, white, black, accent
    case custom(CGColor)

    static let presets: [CollageBackground] = [.transparent, .white, .black, .accent]

    static func == (lhs: CollageBackground, rhs: CollageBackground) -> Bool {
        switch (lhs, rhs) {
        case (.transparent, .transparent), (.white, .white), (.black, .black), (.accent, .accent): return true
        case let (.custom(a), .custom(b)): return a == b
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
    }

    var cgColor: CGColor? {
        switch self {
        case .transparent: return nil
        case .white: return CGColor(gray: 1, alpha: 1)
        case .black: return CGColor(gray: 0, alpha: 1)
        case .accent: return Theme.accentNS.cgColor
        case .custom(let color): return color
        }
    }

    var title: String {
        switch self {
        case .transparent: return "Transparent"
        case .white: return "White"
        case .black: return "Black"
        case .accent: return "Accent"
        case .custom: return "Custom"
        }
    }
}

enum CollageFormat: String, CaseIterable, Hashable {
    case png = "PNG", jpg = "JPG"

    var imageFormat: ImageFormat { self == .png ? .png : .jpg }
}

// MARK: - Model

@MainActor
final class CollageModel: ObservableObject {
    /// Pictures sorted by name, like Finder.
    let items: [FileItem]
    /// Oriented pixel size of each picture.
    let sizes: [CGSize]

    @Published var style: CollageStyle = .auto
    @Published var spacing: Double = 30
    @Published var corners: Double = 24
    @Published var background: CollageBackground = .white {
        didSet { if background != oldValue { Feedback.shared.tick() } }
    }
    @Published var customColor: Color = .blue {
        didSet { background = .custom(NSColor(customColor).cgColor) }
    }
    @Published var format: CollageFormat = .png
    /// Display order: indices into `items`.
    @Published var order: [Int]
    @Published private(set) var previews: [Int: CGImage] = [:]
    @Published var isSaving = false
    @Published var error: String?

    init?(items: [FileItem]) {
        let sorted = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var readable: [FileItem] = []
        var sizes: [CGSize] = []
        for item in sorted {
            guard let size = ImageIOKit.orientedPixelSize(item.url), size.width > 0, size.height > 0 else { continue }
            readable.append(item)
            sizes.append(size)
        }
        guard readable.count >= 2 else { return nil }
        self.items = readable
        self.sizes = sizes
        order = Array(readable.indices)
    }

    var layout: CollageLayout {
        CollageLayout(sizes: order.map { sizes[$0] }, style: style, spacing: spacing)
    }

    /// What the preview shows behind the pictures (JPEG can't be transparent: it gets white).
    var effectiveBackground: CollageBackground {
        format == .jpg && background == .transparent ? .white : background
    }

    func loadPreviews() async {
        for (index, item) in items.enumerated() where previews[index] == nil {
            let url = item.url
            let image = await Task.detached(priority: .userInitiated) {
                try? ImageIOKit.loadImage(url, maxPixelSize: 640)
            }.value
            if let image {
                withAnimation(.easeOut(duration: 0.2)) { previews[index] = image }
            }
        }
    }

    func shuffle() {
        guard order.count > 1 else { return }
        var next = order
        while next == order { next.shuffle() }
        withAnimation(Theme.springSoft) { order = next }
        Feedback.shared.tick()
    }

    func reset() {
        withAnimation(Theme.springSoft) {
            style = .auto
            spacing = 30
            corners = 24
            background = .white
            format = .png
            order = Array(items.indices)
        }
    }

    func save(close: @escaping () -> Void) {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        let urls = order.map { items[$0].url }
        let sizes = order.map { self.sizes[$0] }
        let layout = layout
        let corners = CGFloat(corners)
        let background = effectiveBackground.cgColor
        let format = format.imageFormat
        let directory = items[0].directory
        Task.detached(priority: .userInitiated) {
            do {
                let image = try CollageRenderer.render(urls: urls, sizes: sizes, layout: layout, corners: corners, background: background)
                let output = OutputNaming.url(named: "Collage", ext: format.ext, in: directory)
                try ImageIOKit.write(image, to: output, format: format)
                await MainActor.run {
                    Feedback.shared.success()
                    close()
                }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.error = error.localizedDescription
                    Feedback.shared.failure()
                }
            }
        }
    }
}

// MARK: - Rendering

enum CollageRenderer {
    /// Full-resolution collage. Each picture is decoded just large enough to cover its tile.
    static func render(urls: [URL], sizes: [CGSize], layout: CollageLayout, corners: CGFloat, background: CGColor?) throws -> CGImage {
        let width = Int(layout.canvas.width), height = Int(layout.canvas.height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ImageIOKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw KlickError.failed("Collage too large") }
        ctx.interpolationQuality = .high
        if let background {
            ctx.setFillColor(background)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }

        for (index, tile) in layout.tiles.enumerated() where index < urls.count {
            let size = sizes[index]
            // Aspect-fill: scale so the picture covers the tile, centered.
            let scale = max(tile.width / size.width, tile.height / size.height)
            let longSide = Int((max(size.width, size.height) * scale).rounded(.up))
            let image = try ImageIOKit.loadImage(urls[index], maxPixelSize: min(longSide, Int(max(size.width, size.height))))
            let drawn = CGSize(width: size.width * scale, height: size.height * scale)

            // Layout is top-left; CG is bottom-left.
            let rect = CGRect(x: tile.minX, y: CGFloat(height) - tile.maxY, width: tile.width, height: tile.height)
            let radius = min(corners, tile.width / 2, tile.height / 2)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.clip()
            ctx.draw(image, in: CGRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            ctx.restoreGState()
        }
        guard let output = ctx.makeImage() else { throw KlickError.failed("Rendering failed") }
        return output
    }
}

// MARK: - View

struct CollageEditorView: View {
    @ObservedObject var model: CollageModel
    let close: () -> Void

    var body: some View {
        EditorShell(title: "Collage", onClose: close) {
            VStack(spacing: 14) {
                VStack(spacing: 8) {
                    CollagePreview(model: model)
                        .frame(height: 260)
                    Text(caption)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                HStack {
                    EditorSectionLabel(title: "Layout")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: CollageStyle.allCases, selection: $model.style, label: \.rawValue, compact: true)
                        .fixedSize()
                }

                VStack(spacing: 6) {
                    ValueSliderRow(title: "Spacing", value: $model.spacing, range: 0...120)
                    ValueSliderRow(title: "Corners", value: $model.corners, range: 0...160)
                }

                HStack(spacing: 6) {
                    EditorSectionLabel(title: "Background")
                    Spacer(minLength: 12)
                    ForEach(CollageBackground.presets, id: \.self) { option in
                        BackgroundChip(selected: model.background == option) {
                            chipFill(option)
                        } action: { model.background = option }
                        .help(option.title)
                    }
                    ColorWellSwatch(color: $model.customColor, selected: isCustom)
                }

                HStack {
                    EditorSectionLabel(title: "Format")
                    Spacer(minLength: 12)
                    AccentSegmentedPicker(options: CollageFormat.allCases, selection: $model.format, label: \.rawValue, compact: true)
                        .frame(width: 120)
                }

                if let error = model.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        } footer: {
            KlickSecondaryButton(title: "Reset") { model.reset() }
            KlickSecondaryButton(title: "Shuffle") { model.shuffle() }
            Spacer()
            KlickPrimaryButton(title: "Save Collage", isBusy: model.isSaving) {
                model.save(close: close)
            }
        }
        .task { await model.loadPreviews() }
    }

    private var caption: String {
        let canvas = model.layout.canvas
        return "\(model.items.count) images · \(Int(canvas.width)) × \(Int(canvas.height)) px"
    }

    private var isCustom: Bool {
        if case .custom = model.background { return true }
        return false
    }

    @ViewBuilder
    private func chipFill(_ option: CollageBackground) -> some View {
        switch option {
        case .transparent:
            TransparencyChip()
        case .accent:
            Theme.accentGradient
        default:
            Color(cgColor: option.cgColor ?? .clear)
        }
    }
}

/// Live SwiftUI mirror of `CollageRenderer`, scaled to fit the card.
private struct CollagePreview: View {
    @ObservedObject var model: CollageModel

    var body: some View {
        GeometryReader { geo in
            let layout = model.layout
            let scale = min(geo.size.width / layout.canvas.width, geo.size.height / layout.canvas.height)
            let canvas = CGSize(width: layout.canvas.width * scale, height: layout.canvas.height * scale)

            ZStack(alignment: .topLeading) {
                backgroundView
                    .frame(width: canvas.width, height: canvas.height)

                ForEach(Array(model.order.enumerated()), id: \.element) { position, index in
                    let tile = layout.tiles[position]
                    let frame = CGRect(x: tile.minX * scale, y: tile.minY * scale, width: tile.width * scale, height: tile.height * scale)
                    TileView(image: model.previews[index], size: frame.size,
                             radius: min(model.corners * scale, frame.width / 2, frame.height / 2))
                        .offset(x: frame.minX, y: frame.minY)
                }
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(Theme.springSoft, value: model.style)
            .animation(Theme.springSoft, value: model.order)
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch model.effectiveBackground {
        case .transparent:
            ZStack {
                Color(nsColor: .textBackgroundColor)
                CheckerboardView()
            }
        case .accent:
            Color(nsColor: Theme.accentNS)
        case let other:
            Color(cgColor: other.cgColor ?? .clear)
        }
    }
}

/// One picture of the preview, aspect-filled into its tile.
private struct TileView: View {
    let image: CGImage?
    let size: CGSize
    let radius: CGFloat

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
    }
}

/// Fixed light-gray checkerboard (the shared one is too faint on a 22-pt chip).
private struct TransparencyChip: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            let cell = size.width / 4
            for row in 0..<4 {
                for column in 0..<4 where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.78)))
                }
            }
        }
    }
}

/// Rounded square chip with an accent selection ring (same feel as Add BG's swatches).
private struct BackgroundChip<Fill: View>: View {
    let selected: Bool
    @ViewBuilder var fill: Fill
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            fill
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
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
    }
}
