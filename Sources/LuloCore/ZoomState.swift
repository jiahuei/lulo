import Foundation

public enum ViewingMode: String, CaseIterable, Sendable {
    case fit = "Fit to Window"
    case actualSize = "100%"
}

public struct ZoomState: Sendable {
    public private(set) var mode = ViewingMode.fit
    public private(set) var scale: Double?
    /// The preferred relative image position at the viewport center, retained across different image sizes.
    public private(set) var center = CGPoint(x: 0.5, y: 0.5)

    public init() {}

    public mutating func reset(to mode: ViewingMode = .fit) {
        self.mode = mode
        center = CGPoint(x: 0.5, y: 0.5)
        nextImage()
    }

    public mutating func doubleClick() {
        reset(to: scale == 1 ? .fit : .actualSize)
    }

    public mutating func nextImage() {
        // Scroll zoom is temporary; navigation keeps the selected mode and relative region.
        scale = mode == .fit ? nil : 1
    }

    public mutating func scroll(up: Bool, currentScale: Double) {
        scale = min(32, max(0.01, currentScale * (up ? 1.15 : 1 / 1.15)))
    }

    public func imageRect(imageSize: CGSize, viewport: CGRect) -> CGRect {
        let x = viewport.midX - center.x * imageSize.width
        let y = viewport.midY - center.y * imageSize.height
        return CGRect(
            x: imageSize.width <= viewport.width
                ? viewport.midX - imageSize.width / 2 : max(viewport.maxX - imageSize.width, min(viewport.minX, x)),
            y: imageSize.height <= viewport.height
                ? viewport.midY - imageSize.height / 2 : max(viewport.maxY - imageSize.height, min(viewport.minY, y)),
            width: imageSize.width, height: imageSize.height)
    }

    /// Positions a relative image point under a viewport point, constrained to the image edges.
    public mutating func anchor(_ imagePoint: CGPoint, at point: CGPoint, imageSize: CGSize, viewport: CGRect) {
        guard imageSize.width > 0, imageSize.height > 0 else { return }
        center = CGPoint(
            x: imagePoint.x + (viewport.midX - point.x) / imageSize.width,
            y: imagePoint.y + (viewport.midY - point.y) / imageSize.height)
        let rect = imageRect(imageSize: imageSize, viewport: viewport)
        // Navigation should follow the region actually visible after an edge-constrained gesture.
        center = CGPoint(
            x: (viewport.midX - rect.minX) / imageSize.width,
            y: (viewport.midY - rect.minY) / imageSize.height)
    }

    public mutating func pan(by delta: CGSize, imageSize: CGSize, viewport: CGRect) {
        let rect = imageRect(imageSize: imageSize, viewport: viewport)
        anchor(
            .zero, at: CGPoint(x: rect.minX + delta.width, y: rect.minY + delta.height),
            imageSize: imageSize, viewport: viewport)
    }

    public func effectiveScale(
        pixelWidth: Double, pixelHeight: Double, viewportWidth: Double, viewportHeight: Double,
        backingScale: Double
    ) -> Double {
        scale
            ?? min(
                viewportWidth * backingScale / max(1, pixelWidth),
                viewportHeight * backingScale / max(1, pixelHeight))
    }
}
