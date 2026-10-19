// Screen capture helper for development.
// Usage: shot <out.png> [x y w h]            (points, top-left origin of the main display)
//        shot --burst <count> <intervalMs> <prefix> [x y w h]
import AppKit
import ScreenCaptureKit

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { print("usage: shot out.png [x y w h] | shot --burst N ms prefix [x y w h]"); exit(1) }

func capture(rect: CGRect?) async throws -> CGImage {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        throw NSError(domain: "shot", code: 1)
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    let r = rect ?? CGRect(x: 0, y: 0, width: display.width, height: display.height)
    config.sourceRect = r
    config.width = Int(r.width * scale)
    config.height = Int(r.height * scale)
    config.showsCursor = true
    return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

func save(_ image: CGImage, to path: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

func rect(from values: ArraySlice<String>) -> CGRect? {
    let n = values.compactMap(Double.init)
    return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
}

let sem = DispatchSemaphore(value: 0)
Task {
    do {
        if args[0] == "--burst" {
            let count = Int(args[1]) ?? 10
            let interval = (Double(args[2]) ?? 16) / 1000
            let prefix = args[3]
            let r = rect(from: args.dropFirst(4))
            var images: [CGImage] = []
            let start = Date()
            for i in 0..<count {
                let target = start.addingTimeInterval(Double(i) * interval)
                let wait = target.timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                images.append(try await capture(rect: r))
            }
            for (i, image) in images.enumerated() { try save(image, to: String(format: "%@_%02d.png", prefix, i)) }
            print("saved \(images.count) frames in \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        } else {
            try save(try await capture(rect: rect(from: args.dropFirst())), to: args[0])
            print("saved \(args[0])")
        }
    } catch {
        print("error: \(error)")
    }
    sem.signal()
}
sem.wait()
