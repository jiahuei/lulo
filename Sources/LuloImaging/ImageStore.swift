import Foundation
import ImageIO

// CGImage is immutable; decoding and cache mutation remain isolated to ImageStore.
public struct LoadedImage: @unchecked Sendable {
    public let image: CGImage
    public let details: ImageDetails
}

/// Serializes full-resolution decoding and retains at most ten images within the byte budget.
public actor ImageStore {
    public let byteLimit: Int
    public var cachedBytes: Int { cache.cachedBytes }
    private var generation: Int?
    private var cache: DecodedImageCache<LoadedImage>
    private let decode: @Sendable (URL) throws -> LoadedImage

    public init(byteLimit: Int = 1024 * 1024 * 1024) {
        self.byteLimit = max(0, byteLimit)
        cache = DecodedImageCache(byteLimit: self.byteLimit, countLimit: 10)
        decode = { url in
            try LoadedImage(image: ImageLoader.decode(at: url), details: ImageLoader.details(at: url))
        }
    }

    // Lets regression tests cancel a request at the precise decode-completion boundary.
    init(byteLimit: Int, decode: @escaping @Sendable (URL) throws -> LoadedImage) {
        self.byteLimit = max(0, byteLimit)
        cache = DecodedImageCache(byteLimit: self.byteLimit, countLimit: 10)
        self.decode = decode
    }

    /// Calls onCacheMiss on this actor only when validated cached pixels cannot satisfy the request.
    public func load(
        at url: URL, generation: Int, access: FileAccess? = nil, onCacheMiss: (@Sendable () -> Void)? = nil
    ) throws -> LoadedImage {
        // A cancelled queued navigation/prefetch must not spend time decoding or reset a newer session.
        try Task.checkCancellation()
        defer { withExtendedLifetime(access) {} }
        if self.generation != generation {
            cache.removeAll()
            self.generation = generation
        }
        let loaded = try cache.load(
            at: url,
            decode: {
                onCacheMiss?()
                return try decode(url)
            },
            byteCost: {
                $0.image.bytesPerRow * $0.image.height
            })
        // Image I/O cannot interrupt an active decode. Keep its completed result so a foreground
        // request for an in-flight prefetch does not decode the same image a second time.
        try Task.checkCancellation()
        return loaded
    }
}
