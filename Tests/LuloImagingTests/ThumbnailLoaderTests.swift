import Foundation
import ImageIO
import Testing

@testable import LuloImaging

private func thumbnailTestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Ensures thumbnails have a separate 1 GiB default budget without the viewer's ten-image count limit.
@Test
func thumbnailCacheDefaultsAndReuse() async throws {
    let folder = try thumbnailTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let loader = ThumbnailLoader()
    let access = FileAccess(url: folder)
    #expect(loader.byteLimit == 1024 * 1024 * 1024)
    var originals: [(URL, LoadedThumbnail)] = []
    for index in 0..<12 {
        let url = folder.appendingPathComponent("image\(index).png")
        try fixture(at: url)
        originals.append((url, try await loader.load(at: url, access: access)))
    }
    for (url, original) in originals {
        let reused = try await loader.load(at: url, access: access)
        #expect(reused.image === original.image)
    }
    let expectedBytes = originals.reduce(0) { $0 + $1.1.image.bytesPerRow * $1.1.image.height }
    #expect(await loader.cachedBytes == expectedBytes)
}

/// Ensures thumbnail byte eviction honors recency and oversized entries are returned without being cached.
@Test
func thumbnailCacheBudgetAndEviction() async throws {
    let folder = try thumbnailTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = ["a.png", "b.png", "c.png"].map { folder.appendingPathComponent($0) }
    for url in urls { try fixture(at: url) }
    let decoded = try ImageLoader.thumbnail(at: urls[0])
    let cost = decoded.bytesPerRow * decoded.height
    let loader = ThumbnailLoader(byteLimit: cost * 2)
    let access = FileAccess(url: folder)
    let first = try await loader.load(at: urls[0], access: access)
    let second = try await loader.load(at: urls[1], access: access)
    _ = try await loader.load(at: urls[0], access: access)
    _ = try await loader.load(at: urls[2], access: access)
    #expect(await loader.cachedBytes == cost * 2)
    let retained = try await loader.load(at: urls[0], access: access)
    #expect(retained.image === first.image)
    let evicted = try await loader.load(at: urls[1], access: access)
    #expect(evicted.image !== second.image)
    #expect(await loader.cachedBytes == cost * 2)
    for limit in [0, cost - 1] {
        let uncached = ThumbnailLoader(byteLimit: limit)
        let original = try await uncached.load(at: urls[0], access: access)
        let again = try await uncached.load(at: urls[0], access: access)
        #expect(original.image !== again.image)
        #expect(await uncached.cachedBytes == 0)
    }
}

/// Ensures changed, deleted, or corrupt files cannot return stale thumbnails and can recover after replacement.
@Test
func thumbnailCacheInvalidation() async throws {
    let folder = try thumbnailTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("image.png")
    try fixture(at: url)
    let loader = ThumbnailLoader()
    let access = FileAccess(url: folder)
    let original = try await loader.load(at: url, access: access)
    try fixture(at: url, orientation: 6)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
    let modified = try await loader.load(at: url, access: access)
    #expect(modified.image !== original.image)
    #expect(modified.image.width == 8 && modified.image.height == 12)
    #expect(await loader.cachedBytes == modified.image.bytesPerRow * modified.image.height)
    try FileManager.default.removeItem(at: url)
    await #expect(throws: ImageLoadError.self) { try await loader.load(at: url, access: access) }
    try Data().write(to: url)
    await #expect(throws: ImageLoadError.self) { try await loader.load(at: url, access: access) }
    #expect(await loader.cachedBytes == 0)
    try fixture(at: url)
    let recovered = try await loader.load(at: url, access: access)
    #expect(recovered.image.width == 12 && recovered.image.height == 8)
}

/// Ensures a completed thumbnail remains reusable after its requesting cell cancels, without retaining its grant.
@Test
@MainActor
func cancelledThumbnailDecodeIsReusable() async throws {
    let folder = try thumbnailTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("image.png")
    try fixture(at: url)
    let loaded = try LoadedThumbnail(image: ImageLoader.thumbnail(at: url))
    let loader = ThumbnailLoader(byteLimit: 1024 * 1024) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return loaded
    }
    weak var grant: FileAccess?
    let request = Task {
        let access = FileAccess(url: folder)
        grant = access
        return try await loader.load(at: url, access: access)
    }
    await #expect(throws: CancellationError.self) { try await request.value }
    #expect(grant == nil)
    let reused = try await loader.load(at: url, access: FileAccess(url: folder))
    #expect(reused.image === loaded.image)
}
