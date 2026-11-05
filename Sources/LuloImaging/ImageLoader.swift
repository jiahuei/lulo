import Foundation
import ImageIO
import LuloCore
import UniformTypeIdentifiers

public struct MetadataGroup: Sendable {
    public let name: String
    public let fields: [MetadataField]
}

public struct MetadataField: Sendable {
    public let name: String
    public let value: String
}

public struct ImageDetails: Sendable {
    public let entry: ImageEntry
    public let width: Int
    public let height: Int
    public let groups: [MetadataGroup]
}

public enum ImageLoadError: LocalizedError {
    case raw, unsupported, unreadable, tooLarge

    public var errorDescription: String? {
        switch self {
        case .raw: return "RAW images are not supported."
        case .unsupported: return "This image format is not supported."
        case .unreadable: return "This image could not be read. It may be missing, damaged, or inaccessible."
        case .tooLarge: return "This image exceeds the 64 megapixel decoding limit."
        }
    }
}

public enum ImageLoader {
    // One serial decoder, no prefetch/cache, and this pixel limit bound retained decoded data
    // to roughly 256 MiB for an 8-bit RGBA image. Image I/O can use additional working memory.
    public static let maximumPixelCount = 64_000_000

    public static func validateFormat(_ url: URL) throws -> ImageFormat {
        if let format = ImageFormat(url: url) { return format }
        let rawExtensions = [
            "raw", "dng", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "rwl", "3fr",
            "fff", "iiq", "kdc", "dcr", "mos", "mrw", "x3f", "srw",
        ]
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .rawImage) == true
            || rawExtensions.contains(url.pathExtension.lowercased())
        {
            throw ImageLoadError.raw
        }
        throw ImageLoadError.unsupported
    }

    public static func discover(in folder: URL) throws -> [ImageEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey],
            options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let format = ImageFormat(url: url),
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .creationDateKey]
                ),
                values.isRegularFile == true, values.isSymbolicLink != true
            else { return nil }
            // Keep unreadable supported files navigable so a single bad file does not block the folder.
            return (try? details(at: url).entry)
                ?? ImageEntry(url: url, format: format, createdAt: values.creationDate)
        }
    }

    public static func details(at url: URL) throws -> ImageDetails {
        let format = try validateFormat(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else {
            throw ImageLoadError.unreadable
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let orientedWidth = (5...8).contains(orientation) ? height : width
        let orientedHeight = (5...8).contains(orientation) ? width : height
        var rating: Int?
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
            let value = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString),
            let number = Int(value as String), (0...5).contains(number)
        {
            rating = number
        }
        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let capturedAt = captureDate(exif["DateTimeOriginal"] as? String, offset: exif["OffsetTimeOriginal"] as? String)
        let entry = ImageEntry(url: url, format: format, capturedAt: capturedAt, createdAt: createdAt, rating: rating)
        let dimensions = "\(orientedWidth) × \(orientedHeight)"
        func text(_ value: Any?) -> String? {
            guard let value else { return nil }
            return String(describing: value)
        }
        func group(_ name: String, _ fields: [(String, String?)]) -> MetadataGroup {
            MetadataGroup(
                name: name,
                fields: fields.compactMap { name, value in
                    value.map { MetadataField(name: name, value: $0) }
                })
        }
        let shutter = (exif["ExposureTime"] as? NSNumber).map { value in
            value.doubleValue > 0 && value.doubleValue < 1
                ? "1/\(Int((1 / value.doubleValue).rounded())) s" : "\(value) s"
        }
        let aperture = text(exif["FNumber"]).map { "f/\($0)" }
        let exposure = [shutter, aperture].compactMap { $0 }.joined(separator: ", ")
        let coordinates: String?
        if let latitude = text(gps["Latitude"]), let longitude = text(gps["Longitude"]) {
            coordinates = "\(latitude)\(text(gps["LatitudeRef"]) ?? ""), \(longitude)\(text(gps["LongitudeRef"]) ?? "")"
        } else {
            coordinates = nil
        }
        let altitude = text(gps["Altitude"]).map {
            "\((gps["AltitudeRef"] as? NSNumber)?.intValue == 1 ? "-" : "")\($0) m"
        }
        let groups = [
            group(
                "File",
                [
                    ("File Name", url.lastPathComponent), ("File Path", url.path),
                    ("File Dimensions", dimensions), ("Current Dimensions", dimensions),
                ]),
            group(
                "Timestamps",
                [
                    ("Date Time Original", text(exif["DateTimeOriginal"])),
                    ("Date Time Digitized", text(exif["DateTimeDigitized"])), ("Date Time", text(tiff["DateTime"])),
                ]),
            group(
                "Exposure",
                [
                    ("Exposure", exposure.isEmpty ? nil : exposure),
                    ("Focal Length", text(exif["FocalLength"]).map { "\($0) mm" }),
                    ("Focal Length 35mm", text(exif["FocalLenIn35mmFilm"]).map { "\($0) mm" }),
                    ("Brightness Value", text(exif["BrightnessValue"])),
                    ("Exposure Bias", text(exif["ExposureBiasValue"])),
                    (
                        "ISO Speed Rating",
                        (exif["ISOSpeedRatings"] as? [NSNumber])?.map(\.stringValue).joined(separator: ", ")
                    ),
                    ("Flash", text(exif["Flash"])), ("Exposure Program", text(exif["ExposureProgram"])),
                    ("Metering Mode", text(exif["MeteringMode"])),
                ]),
            group(
                "Camera and lens",
                [
                    ("Make", text(tiff["Make"])), ("Model", text(tiff["Model"])),
                    ("Serial Number", text(exif["BodySerialNumber"])), ("Lens", text(exif["LensModel"])),
                ]),
            group(
                "Attribution and comments",
                [
                    ("Artist", text(tiff["Artist"])), ("Software", text(tiff["Software"])),
                    ("User Comment", text(exif["UserComment"])),
                ]),
            group(
                "Location",
                [
                    ("GPS", coordinates), ("Altitude", altitude),
                    ("Direction", text(gps["ImgDirection"]).map { "\($0)° \(text(gps["ImgDirectionRef"]) ?? "")" }),
                ]),
        ]
        return ImageDetails(entry: entry, width: orientedWidth, height: orientedHeight, groups: groups)
    }

    public static func decode(at url: URL) throws -> CGImage {
        _ = try validateFormat(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
            width > 0, height > 0
        else { throw ImageLoadError.unreadable }
        guard width <= maximumPixelCount / height else { throw ImageLoadError.tooLarge }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldAllowFloat: false,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.unreadable
        }
        return image
    }

    public static func captureDate(_ text: String?, offset: String?) -> Date? {
        guard let text else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssXXXXX"
        return formatter.date(from: text + (offset ?? ""))
    }
}

// Each queued operation retains its grant until completion, even after another session opens.
// URL scope methods are thread-safe; the immutable lease is shared with the serial worker.
public final class FileAccess: @unchecked Sendable {
    public let url: URL
    private let scoped: Bool

    public init(url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}
