// Renders Klick's app icon into Klick/Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Klick/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func segmentPath(center: CGPoint, inner: CGFloat, outer: CGFloat, index: Int, count: Int, gap: CGFloat, corner: CGFloat) -> CGPath {
    let step = 2 * Double.pi / Double(count)
    let mid = Double.pi / 2 - Double(index) * step // y-up: 12 o'clock = +π/2, clockwise = decreasing
    let a0 = mid + step / 2
    let a1 = mid - step / 2
    let r1 = inner + corner, r2 = outer - corner
    let d = gap / 2 + corner
    let i0 = a0 - asin(Double(d / r1)), i1 = a1 + asin(Double(d / r1))
    let o0 = a0 - asin(Double(d / r2)), o1 = a1 + asin(Double(d / r2))
    func p(_ r: CGFloat, _ a: Double) -> CGPoint { CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)) }
    let core = CGMutablePath()
    core.move(to: p(r1, i0))
    core.addLine(to: p(r2, o0))
    core.addArc(center: center, radius: r2, startAngle: o0, endAngle: o1, clockwise: true)
    core.addLine(to: p(r1, i1))
    core.addArc(center: center, radius: r1, startAngle: i1, endAngle: i0, clockwise: false)
    core.closeSubpath()
    return core.union(core.copy(strokingWithWidth: corner * 2, lineCap: .round, lineJoin: .round, miterLimit: 10))
}

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k = s / 1024

    // Squircle body (macOS grid: 824pt body inside a 1024pt canvas).
    let body = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186 * k, yRadius: 186 * k).cgPath

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 28 * k, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.26, alpha: 1).cgColor,
        NSColor(srgbRed: 0.98, green: 0.36, blue: 0.16, alpha: 1).cgColor,
        NSColor(srgbRed: 0.86, green: 0.17, blue: 0.10, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [
        NSColor(white: 1, alpha: 0.35).cgColor, NSColor(white: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: body.minX + 220 * k, y: body.maxY - 160 * k), startRadius: 0,
                           endCenter: CGPoint(x: body.minX + 220 * k, y: body.maxY - 160 * k), endRadius: 560 * k, options: [])

    // Wheel.
    let center = CGPoint(x: body.midX, y: body.midY)
    let count = 6
    for i in 0..<count {
        let path = segmentPath(center: center, inner: 165 * k, outer: 330 * k, index: i, count: count, gap: 26 * k, corner: 34 * k)
        ctx.addPath(path)
        if i == 0 {
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 24 * k, color: NSColor(srgbRed: 0.5, green: 0.08, blue: 0, alpha: 0.45).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor(white: 1, alpha: 0.30).cgColor)
            ctx.fillPath()
        }
    }
    // Hub.
    let hub = CGRect(x: center.x - 128 * k, y: center.y - 128 * k, width: 256 * k, height: 256 * k)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
    ctx.fillEllipse(in: hub)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.85).cgColor)
    ctx.setLineWidth(10 * k)
    ctx.strokeEllipse(in: hub.insetBy(dx: 5 * k, dy: 5 * k))

    // Shift glyph.
    let config = NSImage.SymbolConfiguration(pointSize: 150 * k, weight: .bold)
    if let symbol = NSImage(systemSymbolName: "shift.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let r = CGRect(x: center.x - symbol.size.width / 2, y: center.y - symbol.size.height / 2 + 4 * k,
                       width: symbol.size.width, height: symbol.size.height)
        tinted.draw(in: r)
    }

    // Glass rim.
    ctx.addPath(NSBezierPath(roundedRect: body.insetBy(dx: 3 * k, dy: 3 * k), xRadius: 183 * k, yRadius: 183 * k).cgPath)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
    ctx.setLineWidth(6 * k)
    ctx.strokePath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try render(size: px).write(to: iconset.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: iconset.appendingPathComponent("Contents.json"))
let catalog = iconset.deletingLastPathComponent().appendingPathComponent("Contents.json")
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.data(using: .utf8)!.write(to: catalog)
try render(size: 1024).write(to: root.appendingPathComponent("scripts/icon-preview.png"))
print("Icon written to \(iconset.path)")
