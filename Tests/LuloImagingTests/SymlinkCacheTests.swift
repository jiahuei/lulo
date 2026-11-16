import Foundation
import Testing

@testable import LuloImaging

/// Ensures both caches and the monitor's shared stamp follow target edits, replacement, removal, and retargeting.
@Test
func symlinkTargetValidation() async throws {
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: folder) }
    let target = folder.appendingPathComponent("target.png")
    let link = folder.appendingPathComponent("link.png")
    let replacement = folder.appendingPathComponent("replacement.png")
    try fixture(at: target, rating: 1)
    try manager.createSymbolicLink(at: link, withDestinationURL: target)
    let access = FileAccess(url: link)
    let store = ImageStore()
    let thumbnails = ThumbnailLoader()
    var full = try await store.load(at: link, generation: 1, access: access)
    var thumbnail = try await thumbnails.load(at: link, access: access)
    var stamp = try FileStamp(url: link)
    let linkAttributes = try manager.attributesOfItem(atPath: link.path)

    for change in ["modify", "replace", "recreate", "retarget"] {
        switch change {
        case "modify":
            try fixture(at: target, orientation: 6, rating: 5)
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: target.path)
        case "replace":
            try fixture(at: replacement, orientation: 6, rating: 5)
            let attributes = try manager.attributesOfItem(atPath: target.path)
            try manager.setAttributes(
                [.modificationDate: attributes[.modificationDate]!], ofItemAtPath: replacement.path)
            // Preserve size and mtime so only the target's file identity detects the atomic replacement.
            #expect(try Data(contentsOf: replacement).count == Data(contentsOf: target).count)
            _ = try manager.replaceItemAt(target, withItemAt: replacement)
        case "recreate":
            try manager.removeItem(at: target)
            #expect(throws: (any Error).self) { try FileStamp(url: link) }
            await #expect(throws: ImageLoadError.self) { try await store.load(at: link, generation: 1, access: access) }
            await #expect(throws: ImageLoadError.self) { try await thumbnails.load(at: link, access: access) }
            try fixture(at: target, orientation: 6, rating: 5)
        default:
            try fixture(at: replacement, orientation: 6, rating: 5)
            try manager.removeItem(at: link)
            try manager.createSymbolicLink(at: link, withDestinationURL: replacement)
        }
        let current = try FileStamp(url: link)
        #expect(current != stamp)
        let loaded = try await store.load(at: link, generation: 1, access: access)
        let preview = try await thumbnails.load(at: link, access: access)
        #expect(loaded.image !== full.image && preview.image !== thumbnail.image)
        #expect(loaded.image.width == 8 && preview.image.width == 8)
        #expect(loaded.details.entry.rating == 5 && loaded.details.entry.url == link)
        let reused = try await store.load(at: link, generation: 1, access: access)
        let reusedPreview = try await thumbnails.load(at: link, access: access)
        #expect(reused.image === loaded.image && reusedPreview.image === preview.image)
        if change != "retarget" {
            let unchanged = try manager.attributesOfItem(atPath: link.path)
            #expect(unchanged[.modificationDate] as? Date == linkAttributes[.modificationDate] as? Date)
            #expect(unchanged[.systemFileNumber] as? NSNumber == linkAttributes[.systemFileNumber] as? NSNumber)
        }
        stamp = current
        full = loaded
        thumbnail = preview
    }
}
