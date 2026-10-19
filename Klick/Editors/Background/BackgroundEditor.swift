import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Add BG" card: places the image on a gradient / color / photo backdrop with
/// padding, rounded corners and a soft shadow, then saves `<name> With Background.png`.
enum BackgroundEditor {
    @MainActor static func present(for item: FileItem) {
        guard let model = BackgroundModel(item: item) else {
            Feedback.shared.failure()
            Toast.shared.showMessage("Couldn't open \(item.name)", symbol: "exclamationmark.triangle.fill")
            return
        }
        EditorWindowController.present(width: 380) { close in
            BackgroundEditorView(model: model, close: close)
        }
    }
}

// MARK: - Backgrounds

enum BackdropFill: Hashable {
    case gradient(Int)
    case solid(Int)
    case custom(CGColor)
    case image(URL)

    static func == (lhs: BackdropFill, rhs: BackdropFill) -> Bool {
        switch (lhs, rhs) {
        case let (.gradient(a), .gradient(b)), let (.solid(a), .solid(b)): return a == b
        case let (.custom(a), .custom(b)): return a == b
        case let (.image(a), .image(b)): return a == b
        default: return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .gradient(let i): hasher.combine(0); hasher.combine(i)
        case .solid(let i): hasher.combine(1); hasher.combine(i)
        case .custom: hasher.combine(2)
        case .image(let url): hasher.combine(3); hasher.combine(url)
        }
    }
}

/// Swatches matching the original's two rows.
enum BackdropPalette {
    struct Gradient {
        let colors: [CGColor]
        /// Angle in degrees (0 = left→right, 90 = top→bottom).
        let angle: Double
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    static let gradients: [Gradient] = [
        Gradient(colors: [rgb(0xFF5F6D), rgb(0xFFA34E), rgb(0xFFC371), rgb(0x8E6CF0)], angle: 55),   // sunset (macOS)
        Gradient(colors: [rgb(0xFDFBFB), rgb(0xEBEDEE), rgb(0xC9D6FF)], angle: 120),                // cloud
        Gradient(colors: [rgb(0xFFDDE1), rgb(0xC2E9FB), rgb(0xD4FC79), rgb(0xFBC2EB)], angle: 45),   // holo
        Gradient(colors: [rgb(0xE0C3FC), rgb(0xF5F7FA)], angle: 90),                                // lilac
        Gradient(colors: [rgb(0xFBC2EB), rgb(0xFAD0C4)], angle: 60),                                // blush
        Gradient(colors: [rgb(0x0F0C29), rgb(0x8E2DE2), rgb(0xF0576C)], angle: 45),                 // night
        Gradient(colors: [rgb(0x4776E6), rgb(0x8E54E9)], angle: 45),                                // indigo
        Gradient(colors: [rgb(0x00C6FB), rgb(0x005BEA)], angle: 90),                                // ocean
        Gradient(colors: [rgb(0xE6DEE9), rgb(0xBDC2E8), rgb(0xE6DEE9)], angle: 90),                 // mist
    ]

    static let solids: [CGColor] = [
        rgb(0xFFFFFF), rgb(0xF6C445), rgb(0x7BC74D), rgb(0x2F9E5A), rgb(0x2AA88A),
        rgb(0x3CC3DC), rgb(0x2F6FE4), rgb(0x2B3440), rgb(0x7B3FE4),
    ]
}

// MARK: - Model

enum BackdropRatio: String, CaseIterable, Hashable {
    case auto = "Auto", square = "1:1", wide = "16:9", portrait = "4:5"

    var value: CGFloat? {
        switch self {
        case .auto: return nil
        case .square: return 1
        case .wide: return 16 / 9
        case .portrait: return 4 / 5
        }
    }
}

@MainActor
final class BackgroundModel: ObservableObject {
    let item: FileItem
    let preview: CGImage
    let pixelSize: CGSize

    @Published var fill: BackdropFill = .gradient(0) {
        didSet { if fill != oldValue { Feedback.shared.tick(); loadBackdropImageIfNeeded() } }
    }
    @Published var padding: Double
    @Published var corners: Double
    @Published var shadow: Double = 24
    @Published var ratio: BackdropRatio = .auto
    @Published var customColor: Color = .blue {
        didSet { fill = .custom(NSColor(customColor).cgColor) }
    }
    @Published private(set) var backdropImage: CGImage?
    @Published var isSaving = false
    @Published var error: String?

    private let defaults: (padding: Double, corners: Double)

    init?(item: FileItem) {
        guard let preview = try? ImageIOKit.loadImage(item.url, maxPixelSize: 1200),
              let size = ImageIOKit.orientedPixelSize(item.url), size.width > 0
        else { return nil }
        self.item = item
        self.preview = preview
        self.pixelSize = size
        // Defaults scale with the image so small screenshots don't drown in padding.
        let longSide = max(size.width, size.height)
        defaults = ((longSide * 0.06).rounded(), (longSide * 0.01).rounded())
        padding = defaults.padding
        corners = defaults.corners
    }

    var paddingRange: ClosedRange<Double> { 0...Double(max(pixelSize.width, pixelSize.height) * 0.5).rounded() }
    var cornerRange: ClosedRange<Double> { 0...Double(min(pixelSize.width, pixelSize.height) * 0.25).rounded() }

    func reset() {
        withAnimation(Theme.springSoft) {
            fill = .gradient(0)
            padding = defaults.padding
            corners = defaults.corners
            shadow = 24
            ratio = .auto
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.fill = .image(url) }
        }
    }

    private func loadBackdropImageIfNeeded() {
        guard case .image(let url) = fill else { backdropImage = nil; return }
        backdropImage = try? ImageIOKit.loadImage(url, maxPixelSize: 2400)
    }

    var layout: BackdropLayout {
        BackdropLayout(imageSize: pixelSize, padding: padding, ratio: ratio.value)
    }

    func save(close: @escaping () -> Void) {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        let style = BackdropStyle(fill: fill, backdropImage: backdropImage, corners: corners, shadow: shadow)
        let layout = layout
        let item = item
        Task.detached(priority: .userInitiated) {
            do {
                let image = try ImageIOKit.loadImage(item.url)
                let rendered = try BackdropRenderer.render(image: image, layout: layout, style: style)
                let output = OutputNaming.url(for: item.url, suffix: "With Background", ext: "png")
                try ImageIOKit.write(rendered, to: output, format: .png)
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

/// Canvas size and image placement, in output pixels.
struct BackdropLayout {
    let canvas: CGSize
    let imageRect: CGRect

    init(imageSize: CGSize, padding: Double, ratio: CGFloat?) {
        var w = imageSize.width + CGFloat(padding) * 2
        var h = imageSize.height + CGFloat(padding) * 2
        if let ratio {
            if w / h > ratio { h = w / ratio } else { w = h * ratio }
        }
        canvas = CGSize(width: w.rounded(), height: h.rounded())
        imageRect = CGRect(
            x: ((w - imageSize.width) / 2).rounded(), y: ((h - imageSize.height) / 2).rounded(),
            width: imageSize.width, height: imageSize.height
        )
    }
}

struct BackdropStyle {
    let fill: BackdropFill
    let backdropImage: CGImage?
    let corners: Double
    let shadow: Double
}

// MARK: - Rendering

enum BackdropRenderer {
    /// Full-resolution composition (top-left layout coordinates, CG drawing).
    static func render(image: CGImage, layout: BackdropLayout, style: BackdropStyle) throws -> CGImage {
        let width = Int(layout.canvas.width), height = Int(layout.canvas.height)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: ImageIOKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw KlickError.failed("Image too large") }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.interpolationQuality = .high

        drawFill(style, in: canvas, context: ctx)

        // Flip layout's top-left rect into CG's bottom-left space.
        let r = layout.imageRect
        let rect = CGRect(x: r.minX, y: CGFloat(height) - r.maxY, width: r.width, height: r.height)
        let path = CGPath(roundedRect: rect, cornerWidth: min(style.corners, r.width / 2), cornerHeight: min(style.corners, r.height / 2), transform: nil)

        if style.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -style.shadow * 0.45), blur: style.shadow * 1.6,
                          color: CGColor(gray: 0, alpha: 0.38))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()

        guard let output = ctx.makeImage() else { throw KlickError.failed("Rendering failed") }
        return output
    }

    static func drawFill(_ style: BackdropStyle, in rect: CGRect, context ctx: CGContext) {
        switch style.fill {
        case .gradient(let index):
            let g = BackdropPalette.gradients[index]
            let locations = (0..<g.colors.count).map { CGFloat($0) / CGFloat(max(g.colors.count - 1, 1)) }
            guard let gradient = CGGradient(colorsSpace: ImageIOKit.sRGB, colors: g.colors as CFArray, locations: locations) else { return }
            // Angle measured in top-left space; convert to CG's bottom-left.
            let radians = g.angle * .pi / 180
            let dx = cos(radians), dy = -sin(radians)
            let half = (abs(rect.width * dx) + abs(rect.height * dy)) / 2
            let c = CGPoint(x: rect.midX, y: rect.midY)
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: c.x - dx * half, y: c.y - dy * half),
                                   end: CGPoint(x: c.x + dx * half, y: c.y + dy * half),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .solid(let index):
            ctx.setFillColor(BackdropPalette.solids[index])
            ctx.fill(rect)
        case .custom(let color):
            ctx.setFillColor(color)
            ctx.fill(rect)
        case .image:
            guard let image = style.backdropImage else {
                ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                ctx.fill(rect)
                return
            }
            // Aspect-fill.
            let scale = max(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ctx.draw(image, in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
}

// MARK: - View

struct BackgroundEditorView: View {
    @ObservedObject var model: BackgroundModel
    let close: () -> Void

    var body: some View {
        EditorShell(title: "Add BG", onClose: close) {
            VStack(spacing: 14) {
                BackdropPreview(model: model)
                    .frame(height: 236)

                // Label above the swatches: two rows of ten chips need the card's full width.
                VStack(alignment: .leading, spacing: 8) {
                    EditorSectionLabel(title: "Background")
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ForEach(BackdropPalette.gradients.indices, id: \.self) { i in
                                Swatch(selected: model.fill == .gradient(i)) {
                                    GradientSwatchFill(gradient: BackdropPalette.gradients[i])
                                } action: { model.fill = .gradient(i) }
                            }
                            Swatch(selected: { if case .image = model.fill { return true } else { return false } }()) {
                                ZStack {
                                    Color.primary.opacity(0.06)
                                    Image(systemName: "photo")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                            } action: { model.chooseImage() }
                        }
                        HStack(spacing: 6) {
                            ForEach(BackdropPalette.solids.indices, id: \.self) { i in
                                Swatch(selected: model.fill == .solid(i)) {
                                    Color(cgColor: BackdropPalette.solids[i])
                                } action: { model.fill = .solid(i) }
                            }
                            ColorWellSwatch(color: $model.customColor, selected: { if case .custom = model.fill { return true } else { return false } }())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 6) {
                    ValueSliderRow(title: "Padding", value: $model.padding, range: model.paddingRange)
                    ValueSliderRow(title: "Corners", value: $model.corners, range: model.cornerRange)
                    ValueSliderRow(title: "Shadow", value: $model.shadow, range: 0...120)
                }

                HStack {
                    EditorSectionLabel(title: "Ratio")
                    Spacer()
                    AccentSegmentedPicker(options: BackdropRatio.allCases, selection: $model.ratio, label: \.rawValue, compact: true)
                        .fixedSize()
                }

                if let error = model.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }
            }
        } footer: {
            KlickSecondaryButton(title: "Reset") { model.reset() }
            Spacer()
            KlickPrimaryButton(title: "Save with Background", isBusy: model.isSaving) {
                model.save(close: close)
            }
        }
    }
}

/// Live SwiftUI mirror of `BackdropRenderer`, scaled to fit the card.
private struct BackdropPreview: View {
    @ObservedObject var model: BackgroundModel

    var body: some View {
        GeometryReader { geo in
            let layout = model.layout
            let scale = min(geo.size.width / layout.canvas.width, geo.size.height / layout.canvas.height)
            let canvas = CGSize(width: layout.canvas.width * scale, height: layout.canvas.height * scale)
            let imageRect = layout.imageRect.applying(CGAffineTransform(scaleX: scale, y: scale))
            let radius = min(model.corners * scale, imageRect.width / 2, imageRect.height / 2)

            ZStack(alignment: .topLeading) {
                fillView
                    .frame(width: canvas.width, height: canvas.height)

                Image(decorative: model.preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
                    .shadow(color: .black.opacity(model.shadow > 0 ? 0.38 : 0), radius: model.shadow * scale * 0.8, y: model.shadow * scale * 0.45)
                    .offset(x: imageRect.minX, y: imageRect.minY)
            }
            .frame(width: canvas.width, height: canvas.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(Theme.springSoft, value: model.ratio)
        }
    }

    @ViewBuilder
    private var fillView: some View {
        switch model.fill {
        case .gradient(let i):
            GradientSwatchFill(gradient: BackdropPalette.gradients[i])
        case .solid(let i):
            Color(cgColor: BackdropPalette.solids[i])
        case .custom(let color):
            Color(cgColor: color)
        case .image:
            if let image = model.backdropImage {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
    }
}

private struct GradientSwatchFill: View {
    let gradient: BackdropPalette.Gradient

    var body: some View {
        let radians = gradient.angle * .pi / 180
        let dx = cos(radians) / 2, dy = sin(radians) / 2
        LinearGradient(
            colors: gradient.colors.map { Color(cgColor: $0) },
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }
}

/// Rounded square chip with an accent selection ring and a springy press.
private struct Swatch<Fill: View>: View {
    let selected: Bool
    @ViewBuilder var fill: Fill
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            fill
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
    }
}
