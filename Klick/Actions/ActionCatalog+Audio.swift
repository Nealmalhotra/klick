import AppKit
import Foundation

extension ActionCatalog {
    // MARK: - Audio

    /// MP3 · M4A · WAV · FLAC · OGG · OPUS · AIFF, minus the source format.
    /// WMA can't be decoded on macOS, so it only gets the File page.
    static func audioConvertPage(_ items: [FileItem]) -> WheelPage {
        guard items.allSatisfy(AudioTools.canDecode) else { return WheelPage(id: PageID.convert, title: "Convert", actions: []) }
        // `.aif` is AIFF and `.oga` is OGG, but `.aac` / `.m4b` still get M4A.
        let sources = Set(items.map { ["aif", "aifc"].contains($0.ext) ? "aiff" : ($0.ext == "oga" ? "ogg" : $0.ext) })
        let targets = AudioFormat.allCases.filter { sources.count > 1 || !sources.contains($0.ext) }
        return WheelPage(id: PageID.convert, title: "Convert", actions: targets.map { format in
            perFile("convert.\(format.ext)", format.title, verb: "Converting to \(format.title)") { item, p in
                [try await MediaConverter.convertAudio(item, to: format, progress: p)]
            }
        })
    }

    /// Single file: COMPRESS · METADATA · NORMALIZE · VISUALIZE · TRIM · CHANNELS · BLEEP.
    /// Several files: only the tools that run without an editor.
    static func audioToolsPage(_ items: [FileItem]) -> WheelPage {
        guard items.allSatisfy(AudioTools.canDecode) else { return WheelPage(id: PageID.tools, title: "Tools", actions: []) }
        let compress = perFile("tool.compress", "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing audio") { item, p in
            [try await AudioTools.compress(item, progress: p)]
        }
        let metadata = perFile("tool.metadata", "METADATA", symbol: "tag", verb: "Removing metadata") { item, p in
            [try await AudioMetadata.strip(item, progress: p)]
        }
        let normalize = perFile("tool.normalize", "NORMALIZE", symbol: "waveform", verb: "Normalizing") { item, p in
            [try await AudioTools.normalize(item, progress: p)]
        }
        let channels = perFile("tool.channels", "CHANNELS", symbol: "hifispeaker.2", verb: "Converting channels") { item, p in
            [try await AudioTools.toggleChannels(item, progress: p)]
        }
        guard items.count == 1 else {
            return WheelPage(id: PageID.tools, title: "Tools", actions: [compress, metadata, normalize, channels])
        }
        return WheelPage(id: PageID.tools, title: "Tools", actions: [
            compress,
            metadata,
            normalize,
            perFile("tool.visualize", "VISUALIZE", symbol: "waveform.circle", verb: "Rendering visualizer") { item, p in
                [try await AudioVisualizer.render(item, progress: p)]
            },
            editor("tool.trim", "TRIM", symbol: "scissors") { AudioTrimEditor.present(for: $0[0]) },
            channels,
            editor("tool.bleep", "BLEEP", symbol: "waveform.badge.minus") { BleepEditor.present(for: $0[0]) },
        ])
    }
}
