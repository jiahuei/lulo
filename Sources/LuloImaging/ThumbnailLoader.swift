import Foundation
import ImageIO

// CGImage is immutable and may be passed from the decoder to the main actor.
public struct LoadedThumbnail: @unchecked Sendable {
    public let image: CGImage
}

/// Keeps gallery decoding serial and independent of full-resolution viewer loads.
public actor ThumbnailLoader {
    public let byteLimit: Int
    public var cachedBytes: Int { cache.cachedBytes }
    private var cache: DecodedImageCache<LoadedThumbnail>
    private var generation: Int?
    private let decode: @Sendable (URL) throws -> LoadedThumbnail

    public init(byteLimit: Int = 1024 * 1024 * 1024) {
        self.byteLimit = max(0, byteLimit)
        cache = DecodedImageCache(byteLimit: self.byteLimit)
        decode = { try LoadedThumbnail(image: ImageLoader.thumbnail(at: $0)) }
    }

    // Matches ImageStore's deterministic decode-completion cancellation tests.
    init(byteLimit: Int, decode: @escaping @Sendable (URL) throws -> LoadedThumbnail) {
        self.byteLimit = max(0, byteLimit)
        cache = DecodedImageCache(byteLimit: self.byteLimit)
        self.decode = decode
    }

    public func load(at url: URL, access: FileAccess, generation: Int = 0) throws -> LoadedThumbnail {
        try Task.checkCancellation()
        defer { withExtendedLifetime(access) {} }
        if self.generation != generation {
            cache.removeAll()
            self.generation = generation
        }
        let loaded = try cache.load(
            at: url, decode: { try decode(url) },
            byteCost: {
                $0.image.bytesPerRow * $0.image.height
            })
        // Keep a finished decode for a revisit even if its original cell scrolled out of view.
        try Task.checkCancellation()
        return loaded
    }
}
