import Foundation
import ImageIO

// CGImage is immutable and may be passed from the decoder to the main actor.
public struct LoadedThumbnail: @unchecked Sendable {
    public let image: CGImage
}

/// Keeps gallery decoding serial and independent of full-resolution viewer loads.
public actor ThumbnailLoader {
    public init() {}

    public func load(at url: URL, access: FileAccess) throws -> LoadedThumbnail {
        try Task.checkCancellation()
        defer { withExtendedLifetime(access) {} }
        let image = try autoreleasepool { try ImageLoader.thumbnail(at: url) }
        try Task.checkCancellation()
        return LoadedThumbnail(image: image)
    }
}
