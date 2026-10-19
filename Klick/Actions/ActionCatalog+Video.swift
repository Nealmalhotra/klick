import AppKit
import Foundation

extension ActionCatalog {
    // MARK: - Video

    static func videoConvertPage(_ items: [FileItem]) -> WheelPage {
        let exts = Set(items.map(\.ext))
        var actions: [KlickAction] = []
        if exts != ["mp4"] {
            actions.append(perFile("convert.mp4", "MP4", verb: "Converting to MP4") { item, p in
                [try await MediaConverter.convertVideo(item, to: .mp4, progress: p)]
            })
        }
        if exts != ["mov"] {
            actions.append(perFile("convert.mov", "MOV", verb: "Converting to MOV") { item, p in
                [try await MediaConverter.convertVideo(item, to: .mov, progress: p)]
            })
        }
        actions.append(perFile("convert.gif", "GIF", verb: "Converting to GIF") { item, p in
            [try await MediaConverter.toGIF(item, progress: p)]
        })
        actions.append(perFile("convert.m4a", "M4A", verb: "Extracting audio") { item, p in
            [try await MediaConverter.extractAudio(item, progress: p)]
        })
        actions.append(perFile("convert.mp3", "MP3", verb: "Exporting MP3") { item, p in
            [try await MP3Encoder.encode(item, progress: p)]
        })
        return WheelPage(id: "convert", title: "Convert", actions: actions)
    }

    /// Same tools, in the same order, as Tangerine: one video gets the editors (trim, crop,
    /// speed, split, redact), several get JOIN instead.
    static func videoToolsPage(_ items: [FileItem]) -> WheelPage {
        var actions = [
            perFile("tool.compress", "COMPRESS", symbol: "arrow.down.right.and.arrow.up.left", verb: "Compressing video") { item, p in
                [try await MediaConverter.compressVideo(item, progress: p)]
            },
            perFile("tool.metadata", "METADATA", symbol: "tag", verb: "Removing metadata") { item, p in
                [try await VideoTools.removeMetadata(item, progress: p)]
            },
            perFile("tool.mute", "MUTE", symbol: "speaker.slash.fill", verb: "Removing audio") { item, p in
                [try await MediaConverter.mute(item, progress: p)]
            },
        ]
        if items.count > 1 {
            actions.append(batch("tool.join", "JOIN", symbol: "film.stack", verb: "Joining videos") { items, p in
                [try await VideoTools.join(items, progress: p)]
            })
            return WheelPage(id: "tools", title: "Tools", actions: actions)
        }
        actions += [
            editor("tool.trim", "TRIM", symbol: "scissors") { VideoTrimEditor.present(for: $0[0]) },
            editor("tool.crop", "CROP", symbol: "crop") { VideoCropEditor.present(for: $0[0]) },
            editor("tool.speed", "SPEED", symbol: "speedometer") { VideoSpeedEditor.present(for: $0[0]) },
            perFile("tool.snapshot", "SNAPSHOT", symbol: "camera", verb: "Saving frame") { item, p in
                [try await MediaConverter.snapshot(item, progress: p)]
            },
            editor("tool.split", "SPLIT", symbol: "film") { VideoSplitEditor.present(for: $0[0]) },
            editor("tool.redact", "REDACT", symbol: "eye.slash") { VideoRedactEditor.present(for: $0[0]) },
        ]
        return WheelPage(id: "tools", title: "Tools", actions: actions)
    }

    // MARK: - Animated GIF

    /// Animated GIFs convert to video, like Tangerine; still GIFs stay on the image wheel.
    static func animatedGIFConvertPage(_ items: [FileItem]) -> WheelPage {
        WheelPage(id: PageID.convert, title: "Convert", actions: [VideoContainer.mp4, .mov].map { container in
            perFile("convert.\(container.ext)", container.title, verb: "Converting to \(container.title)") { item, p in
                [try await GIFConverter.toVideo(item, container: container, progress: p)]
            }
        })
    }

    static func animatedGIFToolsPage(_ items: [FileItem]) -> WheelPage {
        WheelPage(id: PageID.tools, title: "Tools", actions: [
            perFile("tool.metadata", "METADATA", symbol: "tag", verb: "Removing metadata") { item, p in
                [try GIFConverter.removeMetadata(item, progress: p)]
            },
        ])
    }
}
