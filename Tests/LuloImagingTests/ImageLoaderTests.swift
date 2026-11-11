import Foundation
import ImageIO
import LuloCore
import Testing
import UniformTypeIdentifiers

@testable import LuloImaging

private func withFolder(_ work: (URL) throws -> Void) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try work(folder)
}

func fixture(at url: URL, type: UTType = .png, orientation: Int = 1, dpi: Int = 72, rating: Int? = nil) throws {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(
        CGContext(
            data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 48,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 6, height: 8))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 6, y: 0, width: 6, height: 8))
    let image = try #require(context.makeImage())
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
        kCGImagePropertyExifDictionary: [
            "DateTimeOriginal": "2026:01:02 03:04:05", "FNumber": 2.8, "BodySerialNumber": "SYNTHETIC",
        ],
        kCGImagePropertyTIFFDictionary: [
            "Make": "Synthetic Camera", "Artist": "Lulo Tests", "DateTime": "2026:02:03 04:05:06",
        ],
    ]
    if let rating {
        let metadata = CGImageMetadataCreateMutable()
        #expect(CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(rating) as CFString))
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
    } else {
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    }
    #expect(CGImageDestinationFinalize(destination))
}

/// Ensures JPEG, PNG, and HEIF decode from synthetic fixtures without changing source bytes.
@Test(arguments: ["jpg", "jpeg", "png", "heic", "heif"])
func supportedFormatsRemainReadOnly(_ suffix: String) throws {
    try withFolder { folder in
        let url = folder.appendingPathComponent("sample.\(suffix)")
        let type: UTType = suffix == "png" ? .png : ["jpg", "jpeg"].contains(suffix) ? .jpeg : .heic
        try fixture(at: url, type: type)
        let before = try Data(contentsOf: url)
        let image = try ImageLoader.decode(at: url)
        #expect(image.width == 12)
        #expect(image.height == 8)
        let details = try ImageLoader.details(at: url)
        #expect(details.width == 12)
        #expect(details.height == 8)
        #expect(
            details.groups.map(\.name) == [
                "File", "Timestamps", "Exposure", "Camera and lens", "Location", "Attribution and comments",
            ])
        #expect(try Data(contentsOf: url) == before)
    }
}

/// Ensures EXIF orientation changes decoded geometry while print resolution does not change pixel size.
@Test
func orientationAndPrintResolution() throws {
    try withFolder { folder in
        for dpi in [72, 300] {
            let url = folder.appendingPathComponent("image-\(dpi).jpg")
            try fixture(at: url, type: .jpeg, orientation: 6, dpi: dpi)
            let image = try ImageLoader.decode(at: url)
            #expect(image.width == 8)
            #expect(image.height == 12)
            let details = try ImageLoader.details(at: url)
            #expect(details.width == image.width)
            #expect(details.height == image.height)
        }
    }
}

/// Ensures PNG decoding retains alpha and a color space for color-managed rendering.
@Test
func transparencyAndColorSpace() throws {
    try withFolder { folder in
        let url = folder.appendingPathComponent("alpha.png")
        try fixture(at: url)
        let image = try ImageLoader.decode(at: url)
        #expect(image.colorSpace != nil)
        #expect([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo))
    }
}

/// Ensures thumbnails respect orientation and preserve alpha, color information, and source bytes.
@Test(arguments: [1, 6])
func thumbnailRendering(_ orientation: Int) throws {
    try withFolder { folder in
        let url = folder.appendingPathComponent("thumbnail.png")
        try fixture(at: url, orientation: orientation)
        let before = try Data(contentsOf: url)
        let image = try ImageLoader.thumbnail(at: url)
        #expect(image.width == (orientation == 6 ? 8 : 12))
        #expect(image.height == (orientation == 6 ? 12 : 8))
        #expect(image.colorSpace != nil)
        #expect([CGImageAlphaInfo.premultipliedLast, .premultipliedFirst, .last, .first].contains(image.alphaInfo))
        #expect(try Data(contentsOf: url) == before)
    }
}

/// Ensures large-photo thumbnails stay within the gallery pixel budget without reducing viewer detail.
@Test
func thumbnailPixelBudget() throws {
    let url = try #require(
        Bundle.module.url(forResource: "DSCF2143-LR-light", withExtension: "jpg", subdirectory: "Fixtures"))
    let image = try ImageLoader.thumbnail(at: url)
    #expect(max(image.width, image.height) == 320)
    #expect(image.width > 0 && image.height > 0)
    #expect(image.bytesPerRow * image.height < 1024 * 1024)
    let full = try ImageLoader.decode(at: url)
    #expect(full.width == 4085 && full.height == 6128)
}

/// Ensures thumbnail failures remain recoverable and do not prevent decoding the next image.
@Test
func thumbnailFailures() throws {
    try withFolder { folder in
        let corrupt = folder.appendingPathComponent("corrupt.jpg")
        try Data().write(to: corrupt)
        for name in ["corrupt.jpg", "missing.png", "unsupported.raw"] {
            #expect(throws: ImageLoadError.self) { try ImageLoader.thumbnail(at: folder.appendingPathComponent(name)) }
        }
        let valid = folder.appendingPathComponent("valid.png")
        try fixture(at: valid)
        #expect(try ImageLoader.thumbnail(at: valid).width == 12)
    }
}

/// Ensures a cancelled gallery request is skipped and the decoder remains usable for the next request.
@Test
func cancelledThumbnailRequest() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let loader = ThumbnailLoader()
    let access = FileAccess(url: folder)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await loader.load(at: folder.appendingPathComponent("missing.png"), access: access)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    let valid = folder.appendingPathComponent("valid.png")
    try fixture(at: valid)
    let loaded = try await loader.load(at: valid, access: access)
    #expect(loaded.image.width == 12)
}

/// Ensures embedded XMP ratings are read and sidecars never change ratings or enter navigation.
@Test
func embeddedRatingAndSidecarExclusion() throws {
    try withFolder { folder in
        let url = folder.appendingPathComponent("rated.jpg")
        try fixture(at: url, type: .jpeg, rating: 4)
        try Data("<xmp:Rating>1</xmp:Rating>".utf8).write(to: folder.appendingPathComponent("rated.xmp"))
        #expect(try ImageLoader.details(at: url).entry.rating == 4)
        let entries = try ImageLoader.discover(in: folder)
        #expect(entries.count == 1)
        #expect(entries.first?.rating == 4)
    }
}

/// Ensures folder discovery skips RAW, subdirectories, and symbolic links but retains corrupt supported images.
@Test
func folderDiscoveryAndRecoverableErrors() throws {
    try withFolder { folder in
        try fixture(at: folder.appendingPathComponent("valid.png"))
        for name in ["raw.dng", "corrupt.jpg", "notes.txt"] {
            try Data().write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("nested.png"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("link.png"),
            withDestinationURL: folder.appendingPathComponent("valid.png"))
        let entries = try ImageLoader.discover(in: folder)
        #expect(Set(entries.map { $0.url.lastPathComponent }) == ["valid.png", "corrupt.jpg"])
        #expect(
            entries.first(where: { $0.url.lastPathComponent == "valid.png" })?.url
                == folder.appendingPathComponent("valid.png"))
        #expect(throws: ImageLoadError.self) {
            try ImageLoader.decode(at: folder.appendingPathComponent("corrupt.jpg"))
        }
        #expect(throws: ImageLoadError.self) {
            try ImageLoader.decode(at: folder.appendingPathComponent("missing.jpg"))
        }
        do {
            _ = try ImageLoader.decode(at: folder.appendingPathComponent("raw.dng"))
            Issue.record("RAW must be rejected before decoding")
        } catch { #expect(error.localizedDescription == "RAW images are not supported.") }
    }
}

/// Ensures capture timestamps respect embedded offsets and missing/invalid fields remain optional.
@Test
func captureTimestamp() {
    #expect(
        ImageLoader.captureDate("2026:01:02 03:04:05", offset: "+02:00")
            == ImageLoader.captureDate("2026:01:02 01:04:05", offset: nil))
    #expect(ImageLoader.captureDate(nil, offset: nil) == nil)
    #expect(ImageLoader.captureDate("not a date", offset: nil) == nil)
}

/// Ensures oversized images fail from their header before allocating a full decoded buffer.
@Test
func oversizedImageIsRecoverable() throws {
    try withFolder { folder in
        let url = folder.appendingPathComponent("oversized.jpg")
        try fixture(at: url, type: .jpeg)
        var bytes = Array(try Data(contentsOf: url))
        let marker = try #require(
            (0..<(bytes.count - 8)).first {
                bytes[$0] == 0xff && [UInt8(0xc0), UInt8(0xc2)].contains(bytes[$0 + 1])
            })
        // Change only the synthetic JPEG's SOF dimensions; no large pixel allocation is needed.
        bytes.replaceSubrange((marker + 5)...(marker + 8), with: [0x23, 0x28, 0x23, 0x28])
        try Data(bytes).write(to: url)
        do {
            _ = try ImageLoader.decode(at: url)
            Issue.record("Oversized image must be rejected before decoding")
        } catch { #expect(error.localizedDescription == "This image exceeds the 64 megapixel decoding limit.") }
        let next = folder.appendingPathComponent("next.png")
        try fixture(at: next)
        #expect(try ImageLoader.decode(at: next).width == 12)
    }
}

/// Ensures discovery carries oriented dimensions for justified rows without a second metadata read.
@Test(arguments: [1, 6])
func entryDimensionsAndMetadataLabels(_ orientation: Int) throws {
    try withFolder { folder in
        let url = folder.appendingPathComponent("geometry.jpg")
        try fixture(at: url, type: .jpeg, orientation: orientation)
        let details = try ImageLoader.details(at: url)
        #expect(details.entry.pixelSize == CGSize(width: orientation == 6 ? 8 : 12, height: orientation == 6 ? 12 : 8))
        #expect(try ImageLoader.discover(in: folder).first?.pixelSize == details.entry.pixelSize)
        let fields = Dictionary(uniqueKeysWithValues: details.groups.flatMap(\.fields).map { ($0.name, $0.value) })
        #expect(fields["Dimensions"] == "\(details.width) × \(details.height)")
        #expect(fields["File Dimensions"] == nil && fields["Current Dimensions"] == nil)
        #expect(fields["Date Time Captured"] == "2026:01:02 03:04:05")
        #expect(fields["Date Time Modified"] == "2026:02:03 04:05:06")
        #expect(details.groups.last?.name == "Attribution and comments")
    }
}
