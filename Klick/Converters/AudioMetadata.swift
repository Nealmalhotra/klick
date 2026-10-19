import AVFoundation

/// Removes tags, cover art and other embedded metadata without re-encoding:
/// the audio data is copied byte for byte (or sample for sample for MPEG-4).
enum AudioMetadata {
    /// `Song.mp3` → `Song No Metadata.mp3`.
    static func strip(_ item: FileItem, progress: JobProgress) async throws -> URL {
        let output = OutputNaming.url(for: item.url, suffix: "No Metadata", ext: item.ext)
        do {
            switch item.ext {
            case "mp3", "aac", "mp2":
                try write(try stripID3(Data(contentsOf: item.url, options: .mappedIfSafe)), to: output)
            case "wav", "wave":
                try write(try stripRIFF(Data(contentsOf: item.url, options: .mappedIfSafe)), to: output)
            case "aif", "aiff", "aifc":
                try write(try stripAIFF(Data(contentsOf: item.url, options: .mappedIfSafe)), to: output)
            case "flac":
                try write(try stripFLAC(Data(contentsOf: item.url, options: .mappedIfSafe)), to: output)
            case "ogg", "oga", "opus":
                try OggMetadata.strip(item.url, to: output)
            case "m4a", "m4b", "mp4", "caf":
                try await remux(item, to: output, progress: progress)
            default:
                throw KlickError.unsupported("Removing metadata from .\(item.ext) files")
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is KlickError { throw error }
            throw KlickError.failed("Couldn't remove the metadata of \(item.name)")
        }
        progress.report(1)
        return output
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
    }

    // MARK: MP3 / ADTS

    /// Drops leading ID3v2 tags and trailing APEv2 / ID3v1 tags.
    static func stripID3(_ data: Data) throws -> Data {
        var start = data.startIndex
        var end = data.endIndex
        // ID3v2: "ID3", version (2), flags, syncsafe size (4); a footer adds 10 bytes.
        while end - start >= 10, data[start..<start + 3].elementsEqual("ID3".utf8) {
            let size = (0..<4).reduce(0) { $0 << 7 | Int(data[start + 6 + $1] & 0x7F) }
            let footer = data[start + 5] & 0x10 != 0 ? 10 : 0
            start += 10 + size + footer
        }
        // Some taggers pad between the tag and the first frame.
        while start < end, data[start] == 0 { start += 1 }
        // ID3v1: the last 128 bytes start with "TAG".
        if end - start >= 128, data[end - 128..<end - 125].elementsEqual("TAG".utf8) { end -= 128 }
        // APEv2 footer: "APETAGEX", version, tag size (excluding the 32-byte header).
        if end - start >= 32, data[end - 32..<end - 24].elementsEqual("APETAGEX".utf8) {
            let size = Int(data.audioLE(UInt32.self, at: end - 20))
            let flags = data.audioLE(UInt32.self, at: end - 12)
            let header = flags & 0x8000_0000 != 0 ? 32 : 0
            end = max(start, end - size - header)
        }
        guard start < end else { throw KlickError.failed("No audio left after removing the tags") }
        return data.subdata(in: start..<end)
    }

    // MARK: WAV

    /// Keeps only the chunks that describe and hold the audio (`fmt `, `fact`, `data`).
    static func stripRIFF(_ data: Data) throws -> Data {
        guard data.count >= 12, data.prefix(4).elementsEqual("RIFF".utf8), data[8..<12].elementsEqual("WAVE".utf8) else {
            throw KlickError.unsupported("This WAV variant")
        }
        var chunks = Data()
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data.audioLE(UInt32.self, at: offset + 4))
            let end = min(offset + 8 + size + (size & 1), data.count)
            if ["fmt ", "fact", "data"].contains(id) { chunks.append(data[offset..<end]) }
            offset = end
        }
        var output = Data("RIFF".utf8)
        output.appendAudioLE(UInt32(4 + chunks.count))
        output.append(contentsOf: Array("WAVE".utf8))
        output.append(chunks)
        return output
    }

    // MARK: AIFF

    /// Keeps `COMM`, `SSND` and the AIFF-C version chunk; drops names, authors, comments, ID3 ...
    static func stripAIFF(_ data: Data) throws -> Data {
        guard data.count >= 12, data.prefix(4).elementsEqual("FORM".utf8) else { throw KlickError.unsupported("This AIFF variant") }
        var chunks = Data()
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = Int(data.audioBE(UInt32.self, at: offset + 4))
            let end = min(offset + 8 + size + (size & 1), data.count)
            if ["COMM", "SSND", "FVER"].contains(id) { chunks.append(data[offset..<end]) }
            offset = end
        }
        var output = Data("FORM".utf8)
        output.append(contentsOf: withUnsafeBytes(of: UInt32(4 + chunks.count).bigEndian) { Array($0) })
        output.append(data[8..<12]) // AIFF or AIFC
        output.append(chunks)
        return output
    }

    // MARK: FLAC

    /// Keeps STREAMINFO and SEEKTABLE; drops Vorbis comments, pictures, padding, application data.
    static func stripFLAC(_ data: Data) throws -> Data {
        var offset = data.startIndex
        // Some taggers put an ID3v2 tag in front of the stream marker.
        if data.count >= 10, data.prefix(3).elementsEqual("ID3".utf8) {
            offset += 10 + (0..<4).reduce(0) { $0 << 7 | Int(data[6 + $1] & 0x7F) }
        }
        guard offset + 4 <= data.count, data[offset..<offset + 4].elementsEqual("fLaC".utf8) else {
            throw KlickError.unsupported("This FLAC variant")
        }
        offset += 4
        var blocks: [Data] = []
        var last = false
        while !last, offset + 4 <= data.count {
            let header = data[offset]
            last = header & 0x80 != 0
            let type = header & 0x7F
            let size = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let end = offset + 4 + size
            guard end <= data.count else { throw KlickError.failed("Damaged FLAC header") }
            if type == 0 || type == 3 { blocks.append(data.subdata(in: offset..<end)) }
            offset = end
        }
        guard !blocks.isEmpty else { throw KlickError.failed("Damaged FLAC header") }
        var output = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            var block = block
            block[block.startIndex] = (block[block.startIndex] & 0x7F) | (index == blocks.count - 1 ? 0x80 : 0)
            output.append(block)
        }
        output.append(data[offset...])
        return output
    }

    // MARK: MPEG-4 / CAF

    /// Copies the audio samples into a fresh container without any metadata or artwork.
    private static func remux(_ item: FileItem, to output: URL, progress: JobProgress) async throws {
        let asset = AVURLAsset(url: item.url)
        guard (try? await asset.load(.isReadable)) == true,
              let track = try await asset.loadTracks(withMediaType: .audio).first
        else { throw KlickError.unreadable(item.name) }
        let (descriptions, range) = try await track.load(.formatDescriptions, .timeRange)

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(readerOutput)
        let fileType: AVFileType = item.ext == "caf" ? .caf : .m4a
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.metadata = []
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw KlickError.unsupported("Remuxing \(item.name)") }
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else { throw KlickError.failed("Couldn't copy the audio of \(item.name)") }
        writer.startSession(atSourceTime: range.start)

        let duration = max(range.duration.seconds, 0.001)
        while let sample = readerOutput.copyNextSampleBuffer() {
            try progress.checkCancelled()
            while !input.isReadyForMoreMediaData {
                try progress.checkCancelled()
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            guard input.append(sample) else { break }
            progress.report(0.95 * min(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration, 1))
        }
        input.markAsFinished()
        if reader.status == .failed {
            writer.cancelWriting()
            throw KlickError.failed("Couldn't read the audio of \(item.name)")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw KlickError.failed("Couldn't write \(output.lastPathComponent): \(writer.error?.localizedDescription ?? "unknown error")")
        }
    }
}
