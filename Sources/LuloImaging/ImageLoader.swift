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
    let captureTimestamp: String?

    /// Embedded wall time for display; capturedAt remains the independent sorting value.
    public var captureTimeDisplay: String? {
        groups.flatMap(\.fields).first { $0.name == "Date Time Captured" }?.value
    }

    public func abbreviatedCaptureTime(locale: Locale = .autoupdatingCurrent) -> String? {
        // Parse and format in the same fixed zone to preserve the embedded clock components,
        // even when an offset exists. The offset-aware entry date is only for sorting.
        guard let date = ImageLoader.captureDate(captureTimestamp, offset: nil) else { return nil }
        return date.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .shortened, locale: locale, timeZone: TimeZone(secondsFromGMT: 0)!))
    }
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
    // Each decoded image is bounded to roughly 256 MiB for 8-bit RGBA pixels.
    // ImageStore separately bounds cached images; Image I/O uses additional working memory.
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

    public static func discover(in folder: URL, isCancelled: () -> Bool = { false }) throws -> [ImageEntry] {
        try contents(of: folder, isCancelled: isCancelled).images
    }

    public typealias FolderContents = (images: [ImageEntry], folders: [URL])

    public static func contents(of folder: URL, isCancelled: () -> Bool = { false }) throws -> FolderContents {
        try contents(of: folder, isCancelled: isCancelled, readEntry: { try details(at: $0).entry })
    }

    // The metadata-read boundary allows deterministic cancellation tests without timing Image I/O.
    static func contents(
        of folder: URL, isCancelled: () -> Bool, readEntry: (URL) throws -> ImageEntry
    ) throws -> FolderContents {
        func checkCancellation() throws {
            if isCancelled() { throw CancellationError() }
        }
        try checkCancellation()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .creationDateKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var images: [ImageEntry] = []
        var folders: [URL] = []
        for discoveredURL in urls {
            try checkCancellation()
            guard let values = try? discoveredURL.resourceValues(forKeys: keys), values.isSymbolicLink != true else {
                continue
            }
            // Keep entries rooted in the granted path even when FileManager returns its resolved spelling.
            let directory = values.isDirectory == true
            let url = folder.appendingPathComponent(discoveredURL.lastPathComponent, isDirectory: directory)
            if directory && values.isPackage != true {
                folders.append(url)
            } else if values.isRegularFile == true, let format = ImageFormat(url: url) {
                // Unreadable images stay navigable so one bad file does not block the folder.
                images.append(
                    (try? readEntry(url)) ?? ImageEntry(url: url, format: format, createdAt: values.creationDate))
                try checkCancellation()
            }
        }
        try checkCancellation()
        folders.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return (images, folders)
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
        let entry = ImageEntry(
            url: url, format: format, capturedAt: capturedAt, createdAt: createdAt, rating: rating,
            pixelSize: CGSize(width: orientedWidth, height: orientedHeight))
        let dimensions = "\(orientedWidth) × \(orientedHeight)"
        func text(_ value: Any?) -> String? {
            guard let value else { return nil }
            return String(describing: value)
        }
        func timestamp(_ value: Any?) -> String? {
            // Preserve the embedded wall-clock time, independent of the viewer's locale and time zone.
            text(value)?.replacingOccurrences(
                of: #"^(\d{4}):(\d{2}):(\d{2}) "#, with: "$1/$2/$3 ", options: .regularExpression)
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
                    ("Dimensions", dimensions),
                ]),
            group(
                "Timestamps",
                [
                    ("Date Time Captured", timestamp(exif["DateTimeOriginal"])),
                    ("Date Time Digitized", timestamp(exif["DateTimeDigitized"])),
                    ("Date Time Modified", timestamp(tiff["DateTime"])),
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
                "Location",
                [
                    ("GPS", coordinates), ("Altitude", altitude),
                    ("Direction", text(gps["ImgDirection"]).map { "\($0)° \(text(gps["ImgDirectionRef"]) ?? "")" }),
                ]),
            group(
                "Attribution and comments",
                [
                    ("Artist", text(tiff["Artist"])), ("Software", text(tiff["Software"])),
                    ("User Comment", text(exif["UserComment"])),
                ]),
        ]
        return ImageDetails(
            entry: entry, width: orientedWidth, height: orientedHeight, groups: groups,
            captureTimestamp: exif["DateTimeOriginal"] as? String)
    }

    public static func decode(at url: URL) throws -> CGImage {
        try decode(at: url, maximumPixelSize: nil)
    }

    public static func thumbnail(at url: URL) throws -> CGImage {
        try decode(at: url, maximumPixelSize: 320)
    }

    private static func decode(at url: URL, maximumPixelSize: Int?) throws -> CGImage {
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
            kCGImageSourceThumbnailMaxPixelSize: min(maximumPixelSize ?? max(width, height), max(width, height)),
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
    public let parentAccess: FileAccess?
    private let scoped: Bool

    public init(url: URL) {
        self.url = url
        parentAccess = nil
        scoped = url.startAccessingSecurityScopedResource()
    }

    /// A discovered child uses its parent's live grant, including while a background read finishes.
    public init?(childFolder url: URL, of parent: FileAccess) {
        guard url.deletingLastPathComponent().standardizedFileURL == parent.url.standardizedFileURL,
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]),
            values.isDirectory == true, values.isSymbolicLink != true, values.isPackage != true
        else { return nil }
        self.url = url
        parentAccess = parent
        scoped = false
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}
