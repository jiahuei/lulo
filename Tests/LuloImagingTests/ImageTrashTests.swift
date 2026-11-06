import Foundation
import Testing

@testable import LuloImaging

/// Ensures native Trash preserves a synthetic image's bytes and removes only the requested authorized file.
@Test(arguments: [true, false])
func trashSyntheticImage(_ grantFolder: Bool) async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("image.png")
    let sibling = folder.appendingPathComponent("sibling.png")
    try fixture(at: image)
    try fixture(at: sibling)
    let bytes = try Data(contentsOf: image)
    let access = FileAccess(url: grantFolder ? folder : image)
    let destination = try #require(try await ImageTrash().move(at: image, access: access))
    defer { try? FileManager.default.removeItem(at: destination) }
    #expect(!FileManager.default.fileExists(atPath: image.path))
    #expect(try Data(contentsOf: destination) == bytes)
    #expect(try Data(contentsOf: sibling) == bytes)
}

/// Ensures missing files, image-named directories/symlinks, and files outside the grant are never removed.
@Test
func trashRejectsInvalidTargets() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("image.png")
    let directory = folder.appendingPathComponent("directory.png")
    let link = folder.appendingPathComponent("link.png")
    let missing = folder.appendingPathComponent("missing.png")
    try fixture(at: image)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: image)
    let bytes = try Data(contentsOf: image)
    let trash = ImageTrash()
    for url in [directory, link, missing] {
        await #expect(throws: (any Error).self) {
            try await trash.move(at: url, access: FileAccess(url: folder))
        }
    }
    await #expect(throws: (any Error).self) {
        try await trash.move(at: image, access: FileAccess(url: missing))
    }
    #expect(try Data(contentsOf: image) == bytes)
    #expect(FileManager.default.fileExists(atPath: directory.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == image.path)
}
