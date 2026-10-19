import Foundation
import UniformTypeIdentifiers

/// Raster image formats Klick can write.
enum ImageFormat: String, CaseIterable {
    case jpg, png, webp, heic, tiff, avif, bmp, gif

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": self = .jpg
        case "png": self = .png
        case "webp": self = .webp
        case "heic", "heif": self = .heic
        case "tif", "tiff": self = .tiff
        case "avif": self = .avif
        case "bmp": self = .bmp
        case "gif": self = .gif
        default: return nil
        }
    }

    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }

    var utType: UTType {
        switch self {
        case .jpg: return .jpeg
        case .png: return .png
        case .webp: return .webP
        case .heic: return .heic
        case .tiff: return .tiff
        case .avif: return UTType("public.avif") ?? .heic
        case .bmp: return .bmp
        case .gif: return .gif
        }
    }

    /// Whether the container can store an alpha channel.
    var supportsAlpha: Bool {
        switch self {
        case .jpg, .bmp: return false
        default: return true
        }
    }

    /// Whether ImageIO keeps EXIF/GPS metadata for this container.
    var supportsMetadata: Bool {
        switch self {
        case .jpg, .heic, .tiff, .avif, .png: return true
        default: return false
        }
    }

    var defaultQuality: Double {
        switch self {
        case .jpg: return 0.9
        case .heic, .avif: return 0.85
        case .webp: return 0.85
        default: return 1
        }
    }
}

/// Audio targets offered on the audio wheel, in wheel order.
enum AudioFormat: String, CaseIterable {
    case mp3, m4a, wav, flac, ogg, opus, aiff

    /// The format Klick would write for a file with this extension (`aif` → AIFF, `oga` → OGG).
    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "mp3": self = .mp3
        case "m4a", "m4b", "aac": self = .m4a
        case "wav", "wave": self = .wav
        case "flac": self = .flac
        case "ogg", "oga": self = .ogg
        case "opus": self = .opus
        case "aif", "aiff", "aifc": self = .aiff
        default: return nil
        }
    }

    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }

    /// WAV, AIFF and FLAC keep every sample; the others are perceptual codecs.
    var isLossless: Bool {
        switch self {
        case .wav, .aiff, .flac: return true
        case .mp3, .m4a, .ogg, .opus: return false
        }
    }
}

/// Video containers offered on the video wheel.
enum VideoContainer: String {
    case mp4, mov

    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }
}

/// Text document targets offered on the document wheel, in wheel order: Tangerine's set first,
/// RTF and ODT fill the remaining segments.
enum DocumentFormat: String, CaseIterable {
    case pdf, docx, txt, md, html, epub, png, jpg, rtf, odt

    var title: String { rawValue.uppercased() }
    var ext: String { rawValue }

    /// PNG/JPG write one image per page.
    var imageFormat: ImageFormat? {
        switch self {
        case .png: return .png
        case .jpg: return .jpg
        default: return nil
        }
    }

    func matches(extension ext: String) -> Bool {
        switch self {
        case .txt: return ["txt", "text"].contains(ext)
        case .html: return ["html", "htm"].contains(ext)
        case .md: return ["md", "markdown"].contains(ext)
        case .jpg: return ["jpg", "jpeg"].contains(ext)
        default: return ext == rawValue
        }
    }
}
