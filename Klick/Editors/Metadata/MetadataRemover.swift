import Foundation
import ImageIO

/// Writes privacy-cleaned copies next to the source; the original is never touched.
enum MetadataRemover {
    /// `<name> No Metadata.<ext>`: re-encoded pixels only, orientation baked in,
    /// without EXIF, GPS, IPTC, TIFF or XMP.
    static func removeAll(from url: URL) throws -> URL {
        let image = try ImageIOKit.loadImage(url)
        let format = ImageIOKit.preferredOutputFormat(for: url)
        let destination = OutputNaming.url(for: url, suffix: "No Metadata", ext: format.ext)
        try ImageIOKit.write(image, to: destination, format: format)
        return destination
    }

    /// `<name> No Location.<ext>`: a lossless copy without GPS (EXIF and XMP) or IPTC
    /// place names; everything else, orientation included, is kept.
    static func removeLocation(from url: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else {
            throw KlickError.unreadable(url.lastPathComponent)
        }
        let destinationURL = OutputNaming.url(for: url, suffix: "No Location", ext: url.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, CGImageSourceGetCount(source), nil) else {
            return try reencodeWithoutLocation(url)
        }

        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil), let cleaned = CGImageMetadataCreateMutableCopy(metadata) {
            for path in placeTags { CGImageMetadataRemoveTagWithPath(cleaned, nil, path as CFString) }
            options[kCGImageDestinationMetadata] = cleaned
            options[kCGImageDestinationMergeMetadata] = false
        }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error?.takeRetainedValue() ?? KlickError.failed("Couldn't write \(destinationURL.lastPathComponent)")
        }
        return destinationURL
    }

    /// Place names (as XMP paths and IPTC keys) reveal the location as much as coordinates do.
    private static let placeTags = [
        "photoshop:City", "photoshop:State", "photoshop:Country",
        "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode",
    ]
    private static let placeKeys = [
        kCGImagePropertyIPTCCity, kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCProvinceState,
        kCGImagePropertyIPTCCountryPrimaryLocationName, kCGImagePropertyIPTCCountryPrimaryLocationCode,
    ]

    /// For containers ImageIO can't write (WebP, camera RAW): re-encode, keeping metadata minus location.
    private static func reencodeWithoutLocation(_ url: URL) throws -> URL {
        let image = try ImageIOKit.loadImage(url)
        let format = ImageIOKit.preferredOutputFormat(for: url)
        let destination = OutputNaming.url(for: url, suffix: "No Location", ext: format.ext)
        var metadata = ImageIOKit.properties(url)
        metadata[kCGImagePropertyGPSDictionary] = nil
        if var iptc = metadata[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            for key in placeKeys { iptc[key] = nil }
            metadata[kCGImagePropertyIPTCDictionary] = iptc
        }
        try ImageIOKit.write(image, to: destination, format: format, metadata: metadata)
        return destination
    }
}
