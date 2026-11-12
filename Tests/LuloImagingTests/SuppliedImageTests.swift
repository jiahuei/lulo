import CryptoKit
import Foundation
import ImageIO
import LuloCore
import Testing

@testable import LuloImaging

private struct SuppliedImage: Sendable {
    let name: String
    let format: ImageFormat
    let width: Int
    let height: Int

    static let all = [
        SuppliedImage(name: "DSCF2180-LR-16.bmp", format: .bmp, width: 156, height: 104),
        SuppliedImage(name: "DSCF2180-LR-24.bmp", format: .bmp, width: 156, height: 104),
        SuppliedImage(name: "DSCF2180-LR-32.bmp", format: .bmp, width: 156, height: 104),
        SuppliedImage(name: "DSCF2180-LR.jxl", format: .jpegXL, width: 624, height: 416),
        SuppliedImage(name: "DSCF2180-LR.webp", format: .webP, width: 624, height: 416),
        SuppliedImage(name: "IMG_0308.heic", format: .heif, width: 1576, height: 2100),
    ]

    var url: URL {
        get throws {
            try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        }
    }
}

/// Ensures all supplied encodings render at full size and as bounded thumbnails without modifying their bytes.
@Test(arguments: SuppliedImage.all)
private func suppliedImageRendering(_ fixture: SuppliedImage) throws {
    let url = try fixture.url
    let before = SHA256.hash(data: try Data(contentsOf: url))
    #expect(try ImageLoader.validateFormat(url) == fixture.format)
    let details = try ImageLoader.details(at: url)
    #expect(details.entry.format == fixture.format)
    #expect(details.width == fixture.width)
    #expect(details.height == fixture.height)
    let image = try ImageLoader.decode(at: url)
    #expect(image.width == fixture.width)
    #expect(image.height == fixture.height)
    #expect(image.colorSpace != nil)
    let thumbnail = try ImageLoader.thumbnail(at: url)
    #expect(max(thumbnail.width, thumbnail.height) == min(320, max(fixture.width, fixture.height)))
    #expect(
        abs(Double(thumbnail.width) / Double(thumbnail.height) - Double(fixture.width) / Double(fixture.height)) < 0.01)
    #expect(thumbnail.colorSpace != nil)
    if fixture.format == .heif {
        let alpha: [CGImageAlphaInfo] = [.premultipliedLast, .premultipliedFirst, .last, .first]
        #expect(alpha.contains(image.alphaInfo))
        #expect(alpha.contains(thumbnail.alphaInfo))
    }
    #expect(SHA256.hash(data: try Data(contentsOf: url)) == before)
}

/// Ensures authorized-folder discovery includes every supplied file with the correct format and dimensions.
@Test
private func suppliedImageDiscovery() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for fixture in SuppliedImage.all {
        try FileManager.default.copyItem(at: fixture.url, to: folder.appendingPathComponent(fixture.name))
    }
    let entries = try ImageLoader.discover(in: folder)
    #expect(Set(entries.map { $0.url.lastPathComponent }) == Set(SuppliedImage.all.map(\.name)))
    for fixture in SuppliedImage.all {
        let entry = try #require(entries.first { $0.url.lastPathComponent == fixture.name })
        #expect(entry.format == fixture.format)
        #expect(entry.pixelSize == CGSize(width: fixture.width, height: fixture.height))
    }
}

/// Ensures corrupt and missing new formats fail recoverably while discovery and subsequent loading stay usable.
@Test(arguments: ["bmp", "jxl", "webp", "heic"])
private func extendedFormatFailures(_ suffix: String) throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let corrupt = folder.appendingPathComponent("corrupt.\(suffix)")
    try Data("invalid image".utf8).write(to: corrupt)
    for url in [corrupt, folder.appendingPathComponent("missing.\(suffix)")] {
        #expect(throws: ImageLoadError.self) { try ImageLoader.decode(at: url) }
        #expect(throws: ImageLoadError.self) { try ImageLoader.thumbnail(at: url) }
        #expect(throws: ImageLoadError.self) { try ImageLoader.details(at: url) }
    }
    let valid = folder.appendingPathComponent("valid.png")
    try fixture(at: valid)
    let entries = try ImageLoader.discover(in: folder)
    #expect(Set(entries.map(\.url)) == [corrupt, valid])
    #expect(try ImageLoader.decode(at: valid).width == 12)
    #expect(try ImageLoader.thumbnail(at: valid).width == 12)
}
