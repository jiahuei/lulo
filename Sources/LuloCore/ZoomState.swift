import Foundation

public struct ZoomState: Sendable {
    public private(set) var scale: Double?
    private var returnToDefault = false

    public init() {}

    public mutating func reset(to display: DisplayDefault) {
        scale = display == .fit ? nil : 1
        returnToDefault = false
    }

    public mutating func doubleClick(default display: DisplayDefault) {
        if returnToDefault {
            reset(to: display)
        } else {
            scale = 1
            returnToDefault = true
        }
    }

    public mutating func scroll(up: Bool, currentScale: Double) {
        scale = min(32, max(0.01, currentScale * (up ? 1.15 : 1 / 1.15)))
        returnToDefault = false
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
