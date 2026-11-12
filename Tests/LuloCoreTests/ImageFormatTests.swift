import Foundation
import Testing

@testable import LuloCore

/// Ensures supported extensions are case-insensitive and retain their sort/filter grouping.
@Test(arguments: ["jpg", "jpeg", "png", "heic", "heif", "bmp", "jxl", "webp"])
func recognizedImageExtensions(_ suffix: String) throws {
    let expected: [String: ImageFormat] = [
        "jpg": .jpeg, "jpeg": .jpeg, "png": .png, "heic": .heif, "heif": .heif,
        "bmp": .bmp, "jxl": .jpegXL, "webp": .webP,
    ]
    let format = try #require(expected[suffix])
    for spelling in [suffix, suffix.uppercased()] {
        #expect(ImageFormat(url: URL(fileURLWithPath: "/image.\(spelling)")) == format)
    }
}

/// Ensures new types participate in type sorting, combined filters, selection, and wrapped navigation.
@Test(arguments: [true, false])
func extendedFormatFilteringAndNavigation(_ ascending: Bool) {
    let files: [(String, ImageFormat)] = [
        ("image.webp", .webP), ("image.png", .png), ("image.jxl", .jpegXL),
        ("image.jpg", .jpeg), ("image.heic", .heif), ("image.bmp", .bmp),
    ]
    var session = ViewingSession(preferences: Preferences(sort: .fileType, ascending: ascending))
    session.replaceEntries(files.map { ImageEntry(url: URL(fileURLWithPath: "/\($0.0)"), format: $0.1) })
    let sorted: [ImageFormat] = [.bmp, .heif, .jpeg, .jpegXL, .png, .webP]
    #expect(session.visibleEntries.map(\.format) == (ascending ? sorted : Array(sorted.reversed())))
    session.select(URL(fileURLWithPath: "/image.jxl"))
    session.filter.formats = [.bmp, .jpegXL, .webP]
    session.reconcileSelection()
    let filtered: [ImageFormat] = [.bmp, .jpegXL, .webP]
    #expect(session.visibleEntries.map(\.format) == (ascending ? filtered : Array(filtered.reversed())))
    #expect(session.selectedURL?.pathExtension == "jxl")
    session.navigate(1)
    #expect(session.selectedURL?.pathExtension == (ascending ? "webp" : "bmp"))
    session.navigate(1)
    #expect(session.selectedURL?.pathExtension == (ascending ? "bmp" : "webp"))
    session.filter.formats = [.heif]
    session.reconcileSelection()
    #expect(session.selectedURL?.pathExtension == "heic")
    session.filter = ImageFilter()
    session.reconcileSelection()
    #expect(session.visibleEntries.count == files.count)
}
