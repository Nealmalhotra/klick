// Records a screen region at 60 fps into numbered PNGs (development only).
// Usage: rec <seconds> <prefix> x y w h     (points, top-left origin of the main display)
import AppKit
import ScreenCaptureKit
import CoreMedia

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 6, let seconds = Double(args[0]) else { print("usage: rec seconds prefix x y w h"); exit(1) }
let prefix = args[1]
let n = args[2...5].compactMap(Double.init)
let rect = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])

final class Output: NSObject, SCStreamOutput {
    var frames: [(CMTime, CGImage)] = []
    let ctx = CIContext()
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sampleBuffer.imageBuffer else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        if let status = attachments?.first?[.status] as? Int, status != SCFrameStatus.complete.rawValue { return }
        let image = CIImage(cvPixelBuffer: buffer)
        if let cg = ctx.createCGImage(image, from: image.extent) { frames.append((sampleBuffer.presentationTimeStamp, cg)) }
    }
}

let output = Output()
let sem = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let display = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays[0]
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.sourceRect = rect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 8
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec"))
        try await stream.startCapture()
        print("recording"); fflush(stdout)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
        try? await stream.stopCapture()
        let start = output.frames.first?.0 ?? .zero
        for (i, frame) in output.frames.enumerated() {
            let ms = Int((CMTimeGetSeconds(frame.0) - CMTimeGetSeconds(start)) * 1000)
            let rep = NSBitmapImageRep(cgImage: frame.1)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: String(format: "%@_%03d_%04dms.png", prefix, i, ms)))
        }
        print("saved \(output.frames.count) frames")
    } catch { print("error: \(error)") }
    sem.signal()
}
sem.wait()
