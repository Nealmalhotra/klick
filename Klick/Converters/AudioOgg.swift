import AVFoundation

// Core Audio lists Ogg as writable but its writer fails on every packet ('fmt?'), so
// Klick encodes Opus with the system encoder and wraps the packets in Ogg pages itself
// (RFC 3533 framing, RFC 7845 Opus mapping).

// MARK: - Pages

/// One Ogg page (RFC 3533 §6).
struct OggPage {
    static let continued: UInt8 = 0x01
    static let beginOfStream: UInt8 = 0x02
    static let endOfStream: UInt8 = 0x04

    var flags: UInt8
    /// Codec-defined position; -1 when no packet ends on this page.
    var granule: Int64
    var serial: UInt32
    var sequence: UInt32
    /// Lacing values: packets are split into 255-byte segments, a shorter one ends a packet.
    var segments: [UInt8]
    var body: Data

    /// Serialized page with its checksum.
    var data: Data {
        var page = Data(capacity: 27 + segments.count + body.count)
        page.append(contentsOf: Array("OggS".utf8))
        page.append(0) // version
        page.append(flags)
        page.appendAudioLE(UInt64(bitPattern: granule))
        page.appendAudioLE(serial)
        page.appendAudioLE(sequence)
        page.appendAudioLE(UInt32(0)) // checksum placeholder
        page.append(UInt8(segments.count))
        page.append(contentsOf: segments)
        page.append(body)
        let crc = OggPage.crc(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        return page
    }

    /// Parses every page of an Ogg file.
    static func pages(in data: Data) throws -> [OggPage] {
        var pages: [OggPage] = []
        var offset = data.startIndex
        while offset + 27 <= data.endIndex {
            guard data[offset..<offset + 4].elementsEqual("OggS".utf8) else { throw KlickError.failed("Damaged Ogg page") }
            let count = Int(data[offset + 26])
            let bodyStart = offset + 27 + count
            guard bodyStart <= data.endIndex else { break }
            let segments = [UInt8](data[offset + 27..<bodyStart])
            let bodyEnd = bodyStart + segments.reduce(0) { $0 + Int($1) }
            guard bodyEnd <= data.endIndex else { break }
            pages.append(OggPage(
                flags: data[offset + 5],
                granule: Int64(bitPattern: data.audioLE(UInt64.self, at: offset + 6)),
                serial: data.audioLE(UInt32.self, at: offset + 14),
                sequence: data.audioLE(UInt32.self, at: offset + 18),
                segments: segments,
                body: data.subdata(in: bodyStart..<bodyEnd)
            ))
            offset = bodyEnd
        }
        return pages
    }

    // CRC-32 with polynomial 0x04C11DB7, no reflection, zero init (RFC 3533 §6).
    private static let table: [UInt32] = (0..<256).map { index in
        var r = UInt32(index) << 24
        for _ in 0..<8 { r = r & 0x8000_0000 != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func crc(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { crc, byte in (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(byte))] }
    }
}

/// Lays packets out into pages of one logical stream and writes them to a file.
final class OggStreamWriter {
    private let handle: FileHandle
    private let serial: UInt32
    private var sequence: UInt32 = 0
    private var pending: [(packet: Data, granule: Int64)] = []
    private var pendingSize = 0

    init(handle: FileHandle, serial: UInt32 = .random(in: 1...UInt32.max)) {
        self.handle = handle
        self.serial = serial
    }

    /// Queues an audio packet; pages are cut at about 4 KB so seeking stays fine-grained.
    func append(_ packet: Data, granule: Int64) throws {
        if pendingSize + packet.count > 4096, !pending.isEmpty { try flush() }
        pending.append((packet, granule))
        pendingSize += packet.count
    }

    /// Writes the queued packets; `last` marks the end of the stream and overrides the final granule.
    func flush(last: Bool = false, finalGranule: Int64? = nil) throws {
        guard !pending.isEmpty else { return }
        var packets = pending
        if let finalGranule { packets[packets.count - 1].granule = finalGranule }
        pending.removeAll()
        pendingSize = 0
        try write(packets, flags: last ? OggPage.endOfStream : 0)
    }

    /// Writes `packets` on fresh pages, splitting any that don't fit in one page.
    func write(_ packets: [(packet: Data, granule: Int64)], flags: UInt8) throws {
        var page = OggPage(flags: sequence == 0 ? OggPage.beginOfStream : 0, granule: -1, serial: serial, sequence: sequence, segments: [], body: Data())
        var pages: [OggPage] = []
        for (packet, granule) in packets {
            var remaining = packet[...]
            while true {
                if page.segments.count == 255 {
                    pages.append(page)
                    sequence += 1
                    page = OggPage(flags: OggPage.continued, granule: -1, serial: serial, sequence: sequence, segments: [], body: Data())
                }
                let size = min(remaining.count, 255)
                page.segments.append(UInt8(size))
                page.body.append(remaining.prefix(size))
                remaining = remaining.dropFirst(size)
                if size < 255 { break } // a segment shorter than 255 ends the packet
            }
            page.granule = granule
            if page.segments.count == 255 {
                // The packet ended exactly on a full page; the next one starts fresh.
                pages.append(page)
                sequence += 1
                page = OggPage(flags: 0, granule: -1, serial: serial, sequence: sequence, segments: [], body: Data())
            }
        }
        if !page.segments.isEmpty { pages.append(page); sequence += 1 }
        if flags & OggPage.endOfStream != 0, !pages.isEmpty { pages[pages.count - 1].flags |= OggPage.endOfStream }
        for page in pages { try handle.write(contentsOf: page.data) }
    }

    /// Copies a page of another stream, renumbered to follow this writer's pages.
    func copy(_ page: OggPage) throws {
        var page = page
        page.serial = serial
        page.sequence = sequence
        sequence += 1
        try handle.write(contentsOf: page.data)
    }
}

// MARK: - Opus encoder

/// Ogg Opus writer (`.opus`, and `.ogg` too: Core Audio has no Vorbis encoder).
final class OggOpusEncoder: AudioSink {
    /// Opus always runs at 48 kHz.
    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let opusFormat: AVAudioFormat
    private let handle: FileHandle
    private let writer: OggStreamWriter
    private let preSkip: Int64
    private var granule: Int64 = 0
    private var inputFrames: Int64 = 0
    private var finished = false

    /// - Parameter inputSampleRate: rate of the original audio, stored in the header for decoders.
    init(url: URL, inputSampleRate: Double, channels: Int, bitRate: Int) throws {
        guard (1...2).contains(channels),
              let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: AVAudioChannelCount(channels)),
              let opus = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 48000, AVNumberOfChannelsKey: channels]),
              let converter = AVAudioConverter(from: pcm, to: opus)
        else { throw KlickError.unsupported("Opus with \(channels) channels") }
        // Pick the closest bit rate the encoder offers.
        let rates = converter.applicableEncodeBitRates?.map(\.intValue) ?? []
        if let closest = rates.min(by: { abs($0 - bitRate) < abs($1 - bitRate) }) { converter.bitRate = closest }
        inputFormat = pcm
        opusFormat = opus
        self.converter = converter
        preSkip = Int64(converter.primeInfo.leadingFrames)

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url)
        else { throw KlickError.failed("Couldn't create \(url.lastPathComponent)") }
        self.handle = handle
        writer = OggStreamWriter(handle: handle)

        // Identification header (RFC 7845 §5.1), then an empty comment header (§5.2), each on its own page.
        var head = Data("OpusHead".utf8)
        head.append(1) // version
        head.append(UInt8(channels))
        head.appendAudioLE(UInt16(preSkip))
        head.appendAudioLE(UInt32(inputSampleRate.rounded()))
        head.appendAudioLE(UInt16(0)) // output gain
        head.append(0) // channel mapping family 0: mono / stereo
        try writer.write([(head, 0)], flags: 0)
        try writer.write([(OggOpusEncoder.commentHeader(vendor: "Klick"), 0)], flags: 0)
    }

    deinit {
        if !finished { try? handle.close() }
    }

    /// `OpusTags` packet with a vendor string and no user comments.
    static func commentHeader(vendor: String) -> Data {
        var tags = Data("OpusTags".utf8)
        tags.appendAudioLE(UInt32(vendor.utf8.count))
        tags.append(contentsOf: Array(vendor.utf8))
        tags.appendAudioLE(UInt32(0))
        return tags
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        inputFrames += Int64(buffer.frameLength)
        var supplied = false
        try encode { status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    func finish() throws {
        guard !finished else { return }
        finished = true
        defer { try? handle.close() }
        try encode { status in
            status.pointee = .endOfStream
            return nil
        }
        // The last granule trims the encoder's padding (RFC 7845 §4.4).
        try writer.flush(last: true, finalGranule: min(granule, preSkip + inputFrames))
    }

    private func encode(_ input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) throws {
        let framesPerPacket = Int64(max(opusFormat.streamDescription.pointee.mFramesPerPacket, 960))
        while true {
            let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 32, maximumPacketSize: max(converter.maximumOutputPacketSize, 1276))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in input(inputStatus) }
            if status == .error { throw KlickError.failed("Opus encoding failed\(error.map { ": \($0.localizedDescription)" } ?? "")") }
            if let descriptions = out.packetDescriptions {
                for index in 0..<Int(out.packetCount) {
                    let description = descriptions[index]
                    let packet = Data(bytes: out.data + Int(description.mStartOffset), count: Int(description.mDataByteSize))
                    granule += description.mVariableFramesInPacket > 0 ? Int64(description.mVariableFramesInPacket) : framesPerPacket
                    try writer.append(packet, granule: granule)
                }
            }
            if status != .haveData { break }
        }
    }
}

// MARK: - Comment stripping

enum OggMetadata {
    /// Rewrites an Ogg Opus / Vorbis file with an empty comment header (and no cover art),
    /// copying the audio pages untouched.
    static func strip(_ source: URL, to output: URL) throws {
        let pages = try OggPage.pages(in: Data(contentsOf: source, options: .mappedIfSafe))
        guard let serial = pages.first?.serial else { throw KlickError.unreadable(source.lastPathComponent) }

        // Reassemble the header packets of the first logical stream.
        var packets: [Data] = []
        var current = Data()
        var headerPageCount = 0
        var expected = 0
        for page in pages where page.serial == serial {
            headerPageCount += 1
            var offset = page.body.startIndex
            for lacing in page.segments {
                current.append(page.body[offset..<offset + Int(lacing)])
                offset += Int(lacing)
                if lacing < 255 { packets.append(current); current = Data() }
            }
            if expected == 0, let first = packets.first {
                if first.starts(with: Array("OpusHead".utf8)) { expected = 2 }
                else if first.starts(with: [0x01] + Array("vorbis".utf8)) { expected = 3 }
                else { throw KlickError.unsupported("Removing metadata from this Ogg codec") }
            }
            if expected > 0, packets.count >= expected { break }
        }
        guard expected > 0, packets.count >= expected else { throw KlickError.unreadable(source.lastPathComponent) }

        let isOpus = expected == 2
        let comment = isOpus
            ? OggOpusEncoder.commentHeader(vendor: vendor(of: packets[1], skipping: 8) ?? "Klick")
            : vorbisComment(vendor: vendor(of: packets[1], skipping: 7) ?? "Klick")

        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output)
        else { throw KlickError.failed("Couldn't create \(output.lastPathComponent)") }
        defer { try? handle.close() }
        let writer = OggStreamWriter(handle: handle, serial: serial)
        try writer.write([(packets[0], 0)], flags: 0)
        try writer.write([(comment, 0)] + packets[2..<expected].map { ($0, Int64(0)) }, flags: 0)
        var seen = 0
        for page in pages {
            if page.serial == serial {
                seen += 1
                if seen <= headerPageCount { continue }
                try writer.copy(page)
            } else {
                try handle.write(contentsOf: page.data) // other multiplexed streams stay as they are
            }
        }
    }

    /// Vendor string of an Opus/Vorbis comment packet, after its `skipping`-byte signature.
    private static func vendor(of packet: Data, skipping signature: Int) -> String? {
        guard packet.count >= signature + 4 else { return nil }
        let length = Int(packet.audioLE(UInt32.self, at: packet.startIndex + signature))
        let start = packet.startIndex + signature + 4
        guard length <= packet.count - signature - 4 else { return nil }
        return String(data: packet[start..<start + length], encoding: .utf8)
    }

    private static func vorbisComment(vendor: String) -> Data {
        var packet = Data([0x03] + Array("vorbis".utf8))
        packet.appendAudioLE(UInt32(vendor.utf8.count))
        packet.append(contentsOf: Array(vendor.utf8))
        packet.appendAudioLE(UInt32(0))
        packet.append(1) // framing bit
        return packet
    }
}

// MARK: - Byte helpers

extension Data {
    mutating func appendAudioLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func audioLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size { value |= T(self[offset + index]) << (8 * index) }
        return value
    }

    func audioBE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for index in 0..<MemoryLayout<T>.size { value = value << 8 | T(self[offset + index]) }
        return value
    }
}
