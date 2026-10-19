import AVFoundation
import CoreGraphics
import ImageIO

/// Animated GIFs, treated like the short videos they are.
enum GIFConverter {
    /// `Loop.gif` → `Loop.mp4` / `Loop.mov`: H.264 playing every frame once, each for its own delay.
    /// Transparent pixels land on white, the page most GIFs were made for.
    static func toVideo(_ item: FileItem, container: VideoContainer, progress: JobProgress) async throws -> URL {
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let first = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw KlickError.unreadable(item.name) }
        let count = CGImageSourceGetCount(source)

        // Encoders need even sides; tiny stickers are enlarged with crisp pixels so players don't blur them.
        let factor = max(1, Int((160 / Double(max(min(first.width, first.height), 1))).rounded(.up)))
        let width = (first.width * factor + 1) / 2 * 2
        let height = (first.height * factor + 1) / 2 * 2

        let output = OutputNaming.url(for: item.url, ext: container.ext)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: container == .mp4 ? .mp4 : .mov) } catch {
            throw KlickError.failed("Couldn't create \(output.lastPathComponent)")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_500_000, width * height * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        do {
            guard writer.startWriting() else { throw writer.error ?? KlickError.failed("Couldn't start encoding") }
            writer.startSession(atSourceTime: .zero)
            var time = CMTime.zero
            var previous: CGImage?
            for index in 0..<count {
                try progress.checkCancelled()
                // A frame that fails to decode repeats the one before it.
                let duration = CMTime(seconds: delay(of: source, at: index), preferredTimescale: 6000)
                guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) ?? previous,
                      let sample = sampleBuffer(frame, width: width, height: height, at: time, duration: duration)
                else { continue }
                previous = frame
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard input.append(sample) else {
                    throw writer.error ?? KlickError.failed("Couldn't encode frame \(index + 1)")
                }
                time = time + duration
                progress.report(0.95 * Double(index + 1) / Double(count))
            }
            // Encoders time a frame by the next one: a copy of the last frame at the very end gives it
            // its full delay, and ending the session there trims the copy itself away.
            if let previous, let closing = sampleBuffer(previous, width: width, height: height, at: time, duration: CMTime(value: 1, timescale: 6000)) {
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(2))
                }
                input.append(closing)
            }
            input.markAsFinished()
            writer.endSession(atSourceTime: time)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? KlickError.failed("Couldn't finish \(output.lastPathComponent)") }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            if error is KlickError || error is CancellationError { throw error is CancellationError ? KlickError.cancelled : error }
            throw KlickError.failed("Couldn't convert \(item.name): \(error.localizedDescription)")
        }
        progress.report(1)
        return output
    }

    /// How long frame `index` stays on screen. Like browsers, delays under 20 ms (often 0,
    /// meaning "as fast as possible") play at 100 ms.
    static func delay(of source: CGImageSource, at index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
        return delay < 0.02 ? 0.1 : delay
    }

    /// `frame` flattened on white and scaled with hard edges, as a sample carrying its own
    /// duration (so the last frame is held for its full delay too).
    private static func sampleBuffer(_ frame: CGImage, width: Int, height: Int, at time: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var pixels: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes, &pixels) == kCVReturnSuccess,
              let pixels
        else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: ImageIOKit.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(pixels, [])
            return nil
        }
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(pixels, [])

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format) == noErr,
              let format
        else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    // MARK: Metadata

    /// `Loop.gif` → `Loop No Metadata.gif`: a byte-for-byte copy without comments, XMP, ICC
    /// profiles or other application blocks. Frames, delays and the loop count are untouched.
    static func removeMetadata(_ item: FileItem, progress: JobProgress) throws -> URL {
        guard let data = try? Data(contentsOf: item.url) else { throw KlickError.unreadable(item.name) }
        let cleaned = try strippedGIF([UInt8](data), name: item.name)
        let output = OutputNaming.url(for: item.url, suffix: "No Metadata", ext: "gif")
        do { try Data(cleaned).write(to: output) } catch {
            throw KlickError.failed("Couldn't write \(output.lastPathComponent)")
        }
        progress.report(1)
        return output
    }

    /// Walks the GIF block structure, keeping the image data, graphic controls (delays, transparency),
    /// plain-text blocks and the looping extension, and dropping everything else.
    static func strippedGIF(_ bytes: [UInt8], name: String) throws -> [UInt8] {
        let corrupt = KlickError.failed("\(name) is damaged")
        guard bytes.count >= 13, bytes.starts(with: Array("GIF8".utf8)) else { throw KlickError.unreadable(name) }

        /// Index just past a chain of data sub-blocks starting at `start`.
        func subBlocksEnd(from start: Int) throws -> Int {
            var index = start
            while index < bytes.count {
                let length = Int(bytes[index])
                index += 1 + length
                if length == 0 { return index }
            }
            throw corrupt
        }
        /// Size of a color table announced by a packed-fields byte.
        func colorTable(_ flags: UInt8) -> Int { flags & 0x80 != 0 ? 3 << Int((flags & 0x07) + 1) : 0 }

        var index = 13 + colorTable(bytes[10]) // header, logical screen, global color table
        guard index <= bytes.count else { throw corrupt }
        var output = Array(bytes[0..<index])
        output.reserveCapacity(bytes.count)
        let loopingIDs = [Array("NETSCAPE2.0".utf8), Array("ANIMEXTS1.0".utf8)]

        scan: while index < bytes.count {
            switch bytes[index] {
            case 0x21: // extension
                guard index + 2 < bytes.count else { throw corrupt }
                let label = bytes[index + 1]
                let end = try subBlocksEnd(from: index + 2)
                let keep: Bool
                switch label {
                case 0xFE: keep = false // comment
                case 0xFF: // application: only the looping one matters for playback
                    let id = bytes[index + 2] == 11 && index + 14 <= bytes.count ? Array(bytes[(index + 3)..<(index + 14)]) : []
                    keep = loopingIDs.contains(id)
                default: keep = true // graphic control, plain text
                }
                if keep { output += bytes[index..<end] }
                index = end
            case 0x2C: // image: descriptor, local color table, LZW code size, data
                guard index + 10 <= bytes.count else { throw corrupt }
                let end = try subBlocksEnd(from: index + 10 + colorTable(bytes[index + 9]) + 1)
                output += bytes[index..<end]
                index = end
            case 0x3B: // trailer
                break scan
            default:
                throw corrupt
            }
        }
        output.append(0x3B)
        return output
    }
}
