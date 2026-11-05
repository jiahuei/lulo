import Foundation
import ImageIO

// CGImage is immutable; decoding and cache mutation remain isolated to ImageStore.
public struct LoadedImage: @unchecked Sendable {
    public let image: CGImage
    public let details: ImageDetails
}

/// Serializes full-resolution decoding and retains a small, byte-bounded working set for arrow navigation.
public actor ImageStore {
    public let byteLimit: Int
    public private(set) var cachedBytes = 0
    private var generation: Int?
    private var cache: [CachedImage] = []
    private let decode: @Sendable (URL) throws -> LoadedImage

    public init(byteLimit: Int = 256 * 1024 * 1024) {
        self.byteLimit = max(0, byteLimit)
        decode = { url in
            try LoadedImage(image: ImageLoader.decode(at: url), details: ImageLoader.details(at: url))
        }
    }

    // Lets regression tests cancel a request at the precise decode-completion boundary.
    init(byteLimit: Int, decode: @escaping @Sendable (URL) throws -> LoadedImage) {
        self.byteLimit = max(0, byteLimit)
        self.decode = decode
    }

    public func load(at url: URL, generation: Int, access: FileAccess? = nil) throws -> LoadedImage {
        // A cancelled queued navigation/prefetch must not spend time decoding or reset a newer session.
        try Task.checkCancellation()
        defer { withExtendedLifetime(access) {} }
        if self.generation != generation {
            cache.removeAll()
            cachedBytes = 0
            self.generation = generation
        }
        let stamp: FileStamp
        do { stamp = try FileStamp(url: url) } catch { throw ImageLoadError.unreadable }
        if let index = cache.firstIndex(where: { $0.url == url }) {
            let previous = cache.remove(at: index)
            if previous.stamp == stamp {
                cache.append(previous)
                return previous.loaded
            }
            cachedBytes -= previous.cost
        }
        let loaded = try autoreleasepool { try decode(url) }
        let cost = loaded.image.bytesPerRow * loaded.image.height
        // NSCache's cost limit is advisory. This small LRU enforces the decoded-buffer budget exactly.
        if cost <= byteLimit {
            while !cache.isEmpty && (cachedBytes + cost > byteLimit || cache.count >= 3) {
                cachedBytes -= cache.removeFirst().cost
            }
            cache.append(CachedImage(url: url, stamp: stamp, loaded: loaded, cost: cost))
            cachedBytes += cost
        }
        // Image I/O cannot interrupt an active decode. Keep its completed result so a foreground
        // request for an in-flight prefetch does not decode the same image a second time.
        try Task.checkCancellation()
        return loaded
    }

    private struct FileStamp: Equatable {
        let modified: Date?
        let size: UInt64?

        init(url: URL) throws {
            // URL resource values may be cached on the URL itself; stat afresh on each revisit.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.uint64Value
        }
    }

    private struct CachedImage {
        let url: URL
        let stamp: FileStamp
        let loaded: LoadedImage
        let cost: Int
    }
}
