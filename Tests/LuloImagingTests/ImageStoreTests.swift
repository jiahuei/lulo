import Foundation
import ImageIO
import Testing

@testable import LuloImaging

private func cacheTestFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Ensures revisits reuse decoded pixels, recently used images survive eviction, and retained bytes stay bounded.
@Test
func imageStoreReuseAndBudget() async throws {
    let folder = try cacheTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = ["a.png", "b.png", "c.png", "d.png"].map { folder.appendingPathComponent($0) }
    for url in urls { try fixture(at: url) }
    let decoded = try ImageLoader.decode(at: urls[0])
    let cost = decoded.bytesPerRow * decoded.height
    let store = ImageStore(byteLimit: cost * 2)
    let a = try await store.load(at: urls[0], generation: 1)
    let b = try await store.load(at: urls[1], generation: 1)
    let again = try await store.load(at: urls[0], generation: 1)
    #expect(a.image === again.image)
    _ = try await store.load(at: urls[2], generation: 1)
    #expect(await store.cachedBytes <= cost * 2)
    let retained = try await store.load(at: urls[0], generation: 1)
    #expect(retained.image === a.image)
    let evicted = try await store.load(at: urls[1], generation: 1)
    #expect(evicted.image !== b.image)
    #expect(await store.cachedBytes <= cost * 2)
    let uncached = ImageStore(byteLimit: cost - 1)
    let first = try await uncached.load(at: urls[0], generation: 1)
    let second = try await uncached.load(at: urls[0], generation: 1)
    #expect(first.image !== second.image)
    #expect(await uncached.cachedBytes == 0)
}

/// Ensures the production full-resolution cache defaults to 1 GiB and evicts the least recent of ten images.
@Test
func imageStoreTenImageLimit() async throws {
    let folder = try cacheTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let urls = (0..<11).map { folder.appendingPathComponent("image\($0).png") }
    for url in urls { try fixture(at: url) }
    let store = ImageStore()
    #expect(await store.byteLimit == 1024 * 1024 * 1024)
    let first = try await store.load(at: urls[0], generation: 1)
    let second = try await store.load(at: urls[1], generation: 1)
    for url in urls[2..<10] { _ = try await store.load(at: url, generation: 1) }
    let cost = first.image.bytesPerRow * first.image.height
    #expect(await store.cachedBytes == cost * 10)
    let reused = try await store.load(at: urls[0], generation: 1)
    #expect(reused.image === first.image)
    _ = try await store.load(at: urls[10], generation: 1)
    #expect(await store.cachedBytes == cost * 10)
    let retained = try await store.load(at: urls[0], generation: 1)
    #expect(retained.image === first.image)
    let evicted = try await store.load(at: urls[1], generation: 1)
    #expect(evicted.image !== second.image)
    #expect(await store.cachedBytes == cost * 10)
}

/// Ensures changed/deleted source files and explicit new sessions never return stale cached pixels or metadata.
@Test
func imageStoreInvalidationAndRecovery() async throws {
    let folder = try cacheTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("image.png")
    try fixture(at: url, rating: 1)
    let store = ImageStore()
    let original = try await store.load(at: url, generation: 1)
    let reopened = try await store.load(at: url, generation: 2)
    #expect(original.image !== reopened.image)
    try fixture(at: url, rating: 5)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
    let modified = try await store.load(at: url, generation: 2)
    #expect(modified.image !== reopened.image)
    #expect(modified.details.entry.rating == 5)
    try FileManager.default.removeItem(at: url)
    await #expect(throws: ImageLoadError.self) { try await store.load(at: url, generation: 2) }
    try Data().write(to: url)
    await #expect(throws: ImageLoadError.self) { try await store.load(at: url, generation: 2) }
    try fixture(at: url, rating: 3)
    let recovered = try await store.load(at: url, generation: 2)
    #expect(recovered.details.entry.rating == 3)
}

/// Ensures cancelled queued work neither decodes a file nor clears a newer session's cache.
@Test
func cancelledImageLoadPreservesCurrentCache() async throws {
    let folder = try cacheTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("current.png")
    try fixture(at: url)
    let store = ImageStore()
    let current = try await store.load(at: url, generation: 2)
    let gate = AsyncStream<Void>.makeStream()
    let task = Task {
        for await _ in gate.stream { break }
        return try await store.load(at: folder.appendingPathComponent("missing.png"), generation: 1)
    }
    task.cancel()
    gate.continuation.finish()
    await #expect(throws: CancellationError.self) { try await task.value }
    let retained = try await store.load(at: url, generation: 2)
    #expect(retained.image === current.image)
}

/// Ensures selecting an in-flight prefetch reuses its finished decode even when the prefetch task is cancelled.
@Test
func completedCancelledDecodeIsReusable() async throws {
    let folder = try cacheTestFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("prefetched.png")
    try fixture(at: url)
    let loaded = try LoadedImage(image: ImageLoader.decode(at: url), details: ImageLoader.details(at: url))
    let store = ImageStore(byteLimit: 1024 * 1024) { _ in
        withUnsafeCurrentTask { $0?.cancel() }
        return loaded
    }
    let prefetch = Task { try await store.load(at: url, generation: 1) }
    await #expect(throws: CancellationError.self) { try await prefetch.value }
    // A second decode would cancel this task too. A cache hit must return the same immutable pixels.
    let selected = try await store.load(at: url, generation: 1)
    #expect(selected.image === loaded.image)
}
