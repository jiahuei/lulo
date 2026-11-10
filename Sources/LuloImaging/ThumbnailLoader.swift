import CoreImage
import Foundation
import ImageIO

// CGImage is immutable and may be passed from the decoder to the main actor.
public struct LoadedThumbnail: @unchecked Sendable {
    public let image: CGImage
}

/// The blurred window background, with separate light and dark variants because they differ in colour treatment.
public struct Backdrop: @unchecked Sendable {
    public let light: CGImage
    public let dark: CGImage
}

/// Keeps gallery decoding serial and independent of full-resolution viewer loads.
public actor ThumbnailLoader {
    public let byteLimit: Int
    public var cachedBytes: Int { cache.cachedBytes }
    private var cache: DecodedImageCache<LoadedThumbnail>
    private var generation: Int?
    private let decode: @Sendable (URL) throws -> LoadedThumbnail
    // D9's CSS filters work on gamma-encoded sRGB; in Core Image's default linear space, brightness 0.55 would
    // look like about 0.76.
    private lazy var context = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
    ])

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

    /// Small, heavily blurred copies of the cached thumbnail for the window background: saturation 1.5 and
    /// brightness 1.06 for light mode, saturation 1.6 and brightness 0.55 for dark mode.
    /// Blurring a 64-pixel copy is cheap enough to repeat, so only the thumbnail itself is cached.
    public func backdrop(at url: URL, access: FileAccess, generation: Int = 0) throws -> Backdrop {
        let thumbnail = try load(at: url, access: access, generation: generation).image
        let input = CIImage(cgImage: thumbnail)
        let scale = 64 / max(input.extent.width, input.extent.height, 1)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // The background covers the window at about 1150 points, so an 80-point blur is 7% of the image.
        let blurred = small.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 64 * 0.07])
        func variant(saturation: Double, brightness: Double) throws -> CGImage {
            // CIColorControls' brightness is additive, so the multiplicative brightness is a colour matrix.
            let adjusted = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: brightness, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: brightness, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: brightness, w: 0),
                    ])
            guard let image = context.createCGImage(adjusted, from: small.extent) else {
                throw ImageLoadError.unreadable
            }
            return image
        }
        let backdrop = try Backdrop(
            light: variant(saturation: 1.5, brightness: 1.06), dark: variant(saturation: 1.6, brightness: 0.55))
        try Task.checkCancellation()
        return backdrop
    }
}
