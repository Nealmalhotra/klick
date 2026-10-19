import Foundation
import ImageIO

/// A readable digest of an image's ImageIO properties, grouped like System Settings.
struct ImageMetadata {
    struct Row: Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Section: Identifiable {
        enum Kind: String {
            case general, camera, dates, location, info

            var title: String { rawValue.capitalized }

            var symbol: String {
                switch self {
                case .general: return "photo"
                case .camera: return "camera"
                case .dates: return "calendar"
                case .location: return "location"
                case .info: return "info.circle"
                }
            }
        }

        let kind: Kind
        let rows: [Row]
        var id: Kind { kind }
    }

    /// Signed decimal degrees (south / west negative).
    struct Coordinate {
        let latitude: Double
        let longitude: Double

        var mapsURL: URL? { URL(string: "maps://?ll=\(latitude),\(longitude)") }
    }

    /// "2550 × 3300 · 1.2 MB · JPEG"
    let summary: String
    let general: Section
    /// Camera, Dates, Location and Info: only the ones that have something to show.
    let details: [Section]
    let coordinate: Coordinate?

    init(item: FileItem) {
        let props = ImageIOKit.properties(item.url)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let exifAux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let png = props[kCGImagePropertyPNGDictionary] as? [CFString: Any] ?? [:]

        let size = ImageIOKit.orientedPixelSize(item.url) ?? .zero
        let dimensions = "\(Int(size.width)) × \(Int(size.height))"
        summary = [dimensions, ByteCountFormatter.klickString(item.size), Self.formatName(item.ext)].joined(separator: " · ")

        general = Section(kind: .general, rows: Self.rows([
            ("Dimensions", "\(dimensions) px"),
            ("Resolution", Self.resolution(props)),
            ("Color Model", props[kCGImagePropertyColorModel] as? String),
            ("Color Profile", props[kCGImagePropertyProfileName] as? String),
            ("Bit Depth", (props[kCGImagePropertyDepth] as? Int).map { "\($0)-bit" }),
            ("Alpha", (props[kCGImagePropertyHasAlpha] as? Bool ?? false) ? "Yes" : "No"),
        ]))

        let camera = Self.rows([
            ("Make", Self.text(tiff[kCGImagePropertyTIFFMake])),
            ("Model", Self.text(tiff[kCGImagePropertyTIFFModel])),
            ("Lens", Self.text(exif[kCGImagePropertyExifLensModel] ?? exifAux[kCGImagePropertyExifAuxLensModel])),
            ("Focal Length", Self.focalLength(exif)),
            ("Aperture", (exif[kCGImagePropertyExifFNumber] as? Double).map { "ƒ/" + Self.decimal($0, digits: 1) }),
            ("Shutter Speed", (exif[kCGImagePropertyExifExposureTime] as? Double).map(Self.shutterSpeed)),
            ("ISO", (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first.map(String.init)),
            ("Flash", (exif[kCGImagePropertyExifFlash] as? Int).map(Self.flash)),
        ])

        let dates = Self.rows([
            ("Original", Self.date(exif[kCGImagePropertyExifDateTimeOriginal])),
            ("Digitized", Self.date(exif[kCGImagePropertyExifDateTimeDigitized])),
        ])

        coordinate = Self.coordinate(gps)
        var location: [Row] = []
        if let coordinate {
            location.append(Row(label: "Latitude", value: Self.degrees(coordinate.latitude, positive: "N", negative: "S")))
            location.append(Row(label: "Longitude", value: Self.degrees(coordinate.longitude, positive: "E", negative: "W")))
        }
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            let belowSeaLevel = gps[kCGImagePropertyGPSAltitudeRef] as? Int == 1
            location.append(Row(label: "Altitude", value: "\(Int(altitude.rounded())) m" + (belowSeaLevel ? " below sea level" : "")))
        }

        let info = Self.rows([
            ("Software", Self.text(tiff[kCGImagePropertyTIFFSoftware] ?? png[kCGImagePropertyPNGSoftware])),
            ("Author", Self.text(tiff[kCGImagePropertyTIFFArtist] ?? iptc[kCGImagePropertyIPTCByline] ?? png[kCGImagePropertyPNGAuthor])),
            ("Copyright", Self.text(tiff[kCGImagePropertyTIFFCopyright] ?? iptc[kCGImagePropertyIPTCCopyrightNotice] ?? png[kCGImagePropertyPNGCopyright])),
        ])

        details = [
            Section(kind: .camera, rows: camera),
            Section(kind: .dates, rows: dates),
            Section(kind: .location, rows: location),
            Section(kind: .info, rows: info),
        ].filter { !$0.rows.isEmpty }
    }

    /// Plain-text dump used by "Copy All".
    func text(fileName: String) -> String {
        let sections = ([general] + details).map { section in
            ([section.kind.title] + section.rows.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }
        return ([fileName + "\n" + summary] + sections).joined(separator: "\n\n")
    }

    // MARK: Formatting

    private static func rows(_ pairs: [(String, String?)]) -> [Row] {
        pairs.compactMap { label, value in value.map { Row(label: label, value: $0) } }
    }

    /// Non-empty trimmed string; arrays (IPTC by-lines) are joined.
    private static func text(_ value: Any?) -> String? {
        let string: String?
        switch value {
        case let list as [String]: string = list.joined(separator: ", ")
        case let single as String: string = single
        default: string = nil
        }
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatName(_ ext: String) -> String {
        switch ImageFormat(fileExtension: ext) {
        case .jpg: return "JPEG"
        case .webp: return "WebP"
        case .some(let format): return format.title
        case .none: return ext.uppercased()
        }
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func resolution(_ props: [CFString: Any]) -> String? {
        guard let x = props[kCGImagePropertyDPIWidth] as? Double else { return nil }
        let y = props[kCGImagePropertyDPIHeight] as? Double ?? x
        return x == y ? "\(decimal(x, digits: 0)) dpi" : "\(decimal(x, digits: 0)) × \(decimal(y, digits: 0)) dpi"
    }

    private static func focalLength(_ exif: [CFString: Any]) -> String? {
        guard let focal = exif[kCGImagePropertyExifFocalLength] as? Double else { return nil }
        let value = "\(decimal(focal, digits: 1)) mm"
        guard let equivalent = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int, equivalent > 0,
              Int(focal.rounded()) != equivalent else { return value }
        return "\(value) (\(equivalent) mm equiv.)"
    }

    private static func shutterSpeed(_ seconds: Double) -> String {
        guard seconds > 0, seconds < 1 else { return "\(decimal(seconds, digits: 1)) s" }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    /// EXIF flash bit field: bit 0 = fired, bit 5 = no flash function.
    private static func flash(_ value: Int) -> String {
        if value & 0x20 != 0 { return "No flash" }
        return value & 0x1 != 0 ? "Fired" : "Off"
    }

    /// EXIF dates have no time zone: parse and print them as wall-clock time.
    private static func date(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: string) else { return string }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }

    private static func coordinate(_ gps: [CFString: Any]) -> Coordinate? {
        guard let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
              let longitude = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        let south = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() == "S"
        let west = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() == "W"
        return Coordinate(latitude: south ? -latitude : latitude, longitude: west ? -longitude : longitude)
    }

    private static func degrees(_ value: Double, positive: String, negative: String) -> String {
        "\(decimal(abs(value), digits: 5))° \(value < 0 ? negative : positive)"
    }
}
