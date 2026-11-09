import Foundation
import Testing

@testable import LuloCore

/// Ensures fit preserves the whole image with unused viewport space and responds to resize/backing changes.
@Test
func fitGeometry() {
    let zoom = ZoomState()
    #expect(
        zoom.effectiveScale(
            pixelWidth: 1000, pixelHeight: 500, viewportWidth: 300, viewportHeight: 300, backingScale: 1) == 0.3)
    #expect(
        zoom.effectiveScale(
            pixelWidth: 1000, pixelHeight: 500, viewportWidth: 300, viewportHeight: 300, backingScale: 2) == 0.6)
    #expect(
        zoom.effectiveScale(
            pixelWidth: 1000, pixelHeight: 500, viewportWidth: 100, viewportHeight: 300, backingScale: 2) == 0.2)
}

/// Ensures 100 percent always means source pixels per backing pixel and never depends on print DPI.
@Test(arguments: [1.0, 2.0])
func actualSizeGeometry(_ backing: Double) {
    var zoom = ZoomState()
    zoom.reset(to: .actualSize)
    let scale = zoom.effectiveScale(
        pixelWidth: 1000, pixelHeight: 500, viewportWidth: 300, viewportHeight: 300, backingScale: backing)
    #expect(scale == 1)
    #expect(1000 * scale / backing == (backing == 1 ? 1000 : 500))
}

/// Ensures double-click toggles the current viewing mode, including when 100 percent was selected in the toolbar.
@Test(arguments: ViewingMode.allCases)
func doubleClickDestinations(_ mode: ViewingMode) {
    var zoom = ZoomState()
    zoom.reset(to: mode)
    zoom.doubleClick()
    #expect(zoom.mode == (mode == .fit ? .actualSize : .fit))
    #expect(zoom.scale == (mode == .fit ? 1 : nil))
    zoom.doubleClick()
    #expect(zoom.mode == mode)
    #expect(zoom.scale == (mode == .fit ? nil : 1))
}

/// Ensures manual zoom returns to 100 percent on double-click, then fit, regardless of the prior mode.
@Test(arguments: ViewingMode.allCases)
func doubleClickAfterScrolling(_ mode: ViewingMode) {
    var zoom = ZoomState()
    zoom.reset(to: mode)
    zoom.scroll(up: true, currentScale: 0.5)
    zoom.doubleClick()
    #expect(zoom.mode == .actualSize)
    #expect(zoom.scale == 1)
    zoom.doubleClick()
    #expect(zoom.mode == .fit)
    #expect(zoom.scale == nil)
}

/// Ensures scrolling remains bounded and temporary while navigation restores the selected viewing mode.
@Test(arguments: ViewingMode.allCases)
func scrollingAndNavigation(_ mode: ViewingMode) throws {
    var zoom = ZoomState()
    zoom.reset(to: mode)
    zoom.scroll(up: true, currentScale: 1)
    #expect(try #require(zoom.scale) > 1)
    zoom.scroll(up: false, currentScale: 1)
    #expect(try #require(zoom.scale) < 1)
    zoom.scroll(up: true, currentScale: 32)
    #expect(zoom.scale == 32)
    zoom.scroll(up: false, currentScale: 0.01)
    #expect(zoom.scale == 0.01)
    zoom.nextImage()
    #expect(zoom.mode == mode)
    #expect(zoom.scale == (mode == .fit ? nil : 1))
    zoom.reset()
    #expect(zoom.mode == .fit)
    #expect(zoom.scale == nil)
    #expect(zoom.center == CGPoint(x: 0.5, y: 0.5))
}

/// Ensures cursor anchoring accounts for fit letterboxing and backing scale without moving the clicked image point.
@Test(arguments: [1.0, 2.0])
func cursorAnchoredZoom(_ backing: Double) {
    var zoom = ZoomState()
    let viewport = CGRect(x: 20, y: 30, width: 300, height: 300)
    let fitSize = CGSize(width: 300, height: 150)
    let fitRect = zoom.imageRect(imageSize: fitSize, viewport: viewport)
    let imagePoint = CGPoint(x: 0.7, y: 0.6)
    let cursor = CGPoint(
        x: fitRect.minX + fitRect.width * imagePoint.x,
        y: fitRect.minY + fitRect.height * imagePoint.y)
    zoom.doubleClick()
    let size = CGSize(width: 2000 / backing, height: 1000 / backing)
    zoom.anchor(imagePoint, at: cursor, imageSize: size, viewport: viewport)
    let rect = zoom.imageRect(imageSize: size, viewport: viewport)
    #expect(abs(rect.minX + rect.width * imagePoint.x - cursor.x) < 0.000001)
    #expect(abs(rect.minY + rect.height * imagePoint.y - cursor.y) < 0.000001)
    zoom.doubleClick()
    #expect(zoom.imageRect(imageSize: fitSize, viewport: viewport) == fitRect)
}

/// Ensures navigation retains a panned relative center across image sizes, including a smaller intervening image.
@Test
func relativeRegionAcrossImages() {
    var zoom = ZoomState()
    zoom.doubleClick()
    let viewport = CGRect(x: 0, y: 0, width: 300, height: 200)
    let originalSize = CGSize(width: 1200, height: 800)
    zoom.anchor(CGPoint(x: 0.7, y: 0.3), at: CGPoint(x: 150, y: 100), imageSize: originalSize, viewport: viewport)
    zoom.pan(by: CGSize(width: -60, height: 40), imageSize: originalSize, viewport: viewport)
    let center = zoom.center
    #expect(abs(center.x - 0.75) < 0.000001)
    #expect(abs(center.y - 0.25) < 0.000001)
    for size in [CGSize(width: 2400, height: 1600), CGSize(width: 1600, height: 2400), originalSize] {
        zoom.nextImage()
        let rect = zoom.imageRect(imageSize: size, viewport: viewport)
        #expect(zoom.scale == 1)
        #expect(abs((viewport.midX - rect.minX) / rect.width - center.x) < 0.000001)
        #expect(abs((viewport.midY - rect.minY) / rect.height - center.y) < 0.000001)
    }
    zoom.nextImage()
    let small = zoom.imageRect(imageSize: CGSize(width: 100, height: 100), viewport: viewport)
    #expect(small == CGRect(x: 100, y: 50, width: 100, height: 100))
    #expect(zoom.center == center)
    zoom.nextImage()
    #expect(zoom.center == center)
    zoom.reset()
    #expect(zoom.center == CGPoint(x: 0.5, y: 0.5))
    #expect(zoom.scale == nil)
}

/// Ensures zooming or dragging near image edges never exposes empty space on an oversized axis.
@Test
func constrainedImagePosition() {
    var zoom = ZoomState()
    zoom.doubleClick()
    let viewport = CGRect(x: 0, y: 0, width: 300, height: 200)
    let size = CGSize(width: 1000, height: 100)
    zoom.anchor(.zero, at: CGPoint(x: 150, y: 100), imageSize: size, viewport: viewport)
    #expect(zoom.imageRect(imageSize: size, viewport: viewport) == CGRect(x: 0, y: 50, width: 1000, height: 100))
    zoom.pan(by: CGSize(width: -5000, height: 5000), imageSize: size, viewport: viewport)
    #expect(zoom.imageRect(imageSize: size, viewport: viewport) == CGRect(x: -700, y: 50, width: 1000, height: 100))
    zoom.pan(by: CGSize(width: 5000, height: -5000), imageSize: size, viewport: viewport)
    #expect(zoom.imageRect(imageSize: size, viewport: viewport) == CGRect(x: 0, y: 50, width: 1000, height: 100))
}
