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

/// Ensures double-click goes to 100 percent then the saved default, including after manual zoom.
@Test(arguments: DisplayDefault.allCases)
func doubleClickDestinations(_ display: DisplayDefault) {
    var zoom = ZoomState()
    zoom.reset(to: display)
    zoom.scroll(up: true, currentScale: 0.5)
    zoom.doubleClick(default: display)
    #expect(zoom.scale == 1)
    zoom.doubleClick(default: display)
    #expect(zoom.scale == (display == .fit ? nil : 1))
    zoom.doubleClick(default: display)
    zoom.scroll(up: false, currentScale: 1)
    zoom.doubleClick(default: display)
    #expect(zoom.scale == 1)
}

/// Ensures upward scrolling increases zoom and a new image/session restores the saved display default.
@Test
func scrollingAndReset() throws {
    var zoom = ZoomState()
    zoom.scroll(up: true, currentScale: 1)
    #expect(try #require(zoom.scale) > 1)
    zoom.scroll(up: false, currentScale: 1)
    #expect(try #require(zoom.scale) < 1)
    zoom.reset(to: .fit)
    #expect(zoom.scale == nil)
    zoom.reset(to: .actualSize)
    #expect(zoom.scale == 1)
}
