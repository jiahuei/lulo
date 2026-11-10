import Foundation
import Testing

@testable import LuloCore

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Ensures full rows exactly fill the width at each image's aspect ratio while the last row keeps the target height.
@Test
func justifiedRowsFillWidthAndKeepLastRow() {
    let aspects = [1.5, 0.75, 1.0, 2.0, 1.5, 0.5]
    let frames = GalleryGeometry.justifiedRows(aspectRatios: aspects, width: 600, targetHeight: 200, spacing: 6)
    let rows = Dictionary(grouping: frames.indices, by: { frames[$0].minY }).sorted { $0.key < $1.key }
    // Rows close at [1.5, 0.75, 1.0] and [2.0, 1.5]; the 0.5 portrait is left over.
    #expect(rows.map(\.value) == [[0, 1, 2], [3, 4], [5]])
    for (offset, row) in rows.enumerated() {
        let tiles = row.value.map { frames[$0] }
        for (index, frame) in zip(row.value, tiles) {
            #expect(abs(frame.width / frame.height - aspects[index]) < 0.0001)
        }
        if offset < rows.count - 1 {
            // A complete row is scaled so its tiles and gaps end exactly at the content width.
            #expect(abs((tiles.map(\.maxX).max() ?? 0) - 600) < 0.0001)
        } else {
            #expect(tiles.allSatisfy { $0.height == 200 })
            #expect((tiles.map(\.maxX).max() ?? 0) < 600)
        }
        #expect(tiles.map(\.minX).min() == 0)
    }
    #expect(rows[1].key == frames[0].maxY + 6)
    // Order is preserved left to right within each row.
    for row in rows { #expect(row.value.map { frames[$0].minX } == row.value.map { frames[$0].minX }.sorted()) }
}

/// Ensures a row breaks where its height is closest to the target, even when that leaves it slightly taller.
@Test
func justifiedRowsBreakNearestTarget() {
    // Two 1.4 images fill 600 points at about 212; adding the 3.0 panorama would shrink the row to about 101.
    let frames = GalleryGeometry.justifiedRows(
        aspectRatios: [1.4, 1.4, 3.0], width: 600, targetHeight: 200, spacing: 6)
    #expect(frames.map(\.minY) == [0, 0, frames[0].maxY + 6])
    #expect(abs(frames[0].height - 594 / 2.8) < 0.0001)
    #expect(abs(frames[1].maxX - 600) < 0.0001)
    // The panorama alone fills the width at exactly the target height.
    #expect(abs(frames[2].height - 200) < 0.0001 && abs(frames[2].width - 600) < 0.0001)
}

/// Ensures a single image wider than the content shrinks to fit rather than overflowing the row.
@Test
func justifiedRowsShrinkPanoramas() {
    let frames = GalleryGeometry.justifiedRows(aspectRatios: [10], width: 500, targetHeight: 200, spacing: 6)
    #expect(frames == [CGRect(x: 0, y: 0, width: 500, height: 50)])
    #expect(GalleryGeometry.justifiedRows(aspectRatios: [], width: 500, targetHeight: 200, spacing: 6).isEmpty)
}

/// Ensures the square grid uses as many columns as fit at the minimum size and fills the width exactly.
@Test
func squareGridFillsColumns() {
    let frames = GalleryGeometry.squareGrid(count: 7, width: 560, minimumTile: 128, spacing: 10)
    // (560 + 10) / (128 + 10) allows four columns of 132.5 points.
    #expect(frames[0] == CGRect(x: 0, y: 0, width: 132.5, height: 132.5))
    #expect(frames[3].maxX == 560)
    #expect(frames[4] == CGRect(x: 0, y: 142.5, width: 132.5, height: 132.5))
    #expect(GalleryGeometry.squareGrid(count: 2, width: 50, minimumTile: 128, spacing: 10).map(\.minY) == [0, 60])
}

/// Ensures up and down choose the nearest horizontal center in the adjacent row and stop at the edges.
@Test
func verticalNeighborUsesNearestCenter() {
    let frames = [
        CGRect(x: 0, y: 0, width: 300, height: 100), CGRect(x: 306, y: 0, width: 294, height: 100),
        CGRect(x: 0, y: 106, width: 100, height: 100), CGRect(x: 106, y: 106, width: 100, height: 100),
        CGRect(x: 212, y: 106, width: 388, height: 100),
    ]
    #expect(GalleryGeometry.verticalNeighbor(of: 0, in: frames, direction: 1) == 3)
    #expect(GalleryGeometry.verticalNeighbor(of: 1, in: frames, direction: 1) == 4)
    #expect(GalleryGeometry.verticalNeighbor(of: 2, in: frames, direction: -1) == 0)
    #expect(GalleryGeometry.verticalNeighbor(of: 4, in: frames, direction: -1) == 1)
    #expect(GalleryGeometry.verticalNeighbor(of: 0, in: frames, direction: -1) == nil)
    #expect(GalleryGeometry.verticalNeighbor(of: 3, in: frames, direction: 1) == nil)
    #expect(GalleryGeometry.verticalNeighbor(of: 9, in: frames, direction: 1) == nil)
}

/// Ensures slider sizes snap to each layout's documented range and step, including invalid stored values.
@Test(arguments: GalleryLayout.allCases)
func gallerySizesSnapToSteps(_ layout: GalleryLayout) {
    #expect(layout.clampedSize(layout.defaultSize) == layout.defaultSize)
    #expect(layout.clampedSize(0) == layout.sizeRange.lowerBound)
    #expect(layout.clampedSize(10_000) == layout.sizeRange.upperBound)
    #expect(layout.clampedSize(.nan) == layout.defaultSize)
    let nearlyOneStep = layout.defaultSize + layout.sizeStep * 0.6
    #expect(layout.clampedSize(nearlyOneStep) == layout.defaultSize + layout.sizeStep)
    #expect(layout.sizeRange == (layout == .rows ? 120...300 : 88...220))
    // Both ends of the range are selectable, and stepping stops there.
    let sizes = layout.sizes
    #expect(sizes.first == layout.sizeRange.lowerBound && sizes.last == layout.sizeRange.upperBound)
    #expect(sizes.contains(layout.defaultSize))
    #expect(layout.adjustedSize(layout.defaultSize, steps: 1) == layout.defaultSize + layout.sizeStep)
    #expect(layout.adjustedSize(layout.sizeRange.upperBound, steps: 1) == layout.sizeRange.upperBound)
    #expect(layout.adjustedSize(layout.sizeRange.lowerBound, steps: -3) == layout.sizeRange.lowerBound)
    #expect(layout.adjustedSize(layout.sizeRange.upperBound, steps: -1) == sizes[sizes.count - 2])
}

/// Ensures Preview's off-grid range ends (88 and 220) sit beside the 6-point steps counted from its default.
@Test
func previewSizesIncludeRangeEnds() {
    let sizes = GalleryLayout.preview.sizes
    #expect(Array(sizes.prefix(3)) == [88, 92, 98])
    #expect(Array(sizes.suffix(3)) == [212, 218, 220])
    #expect(GalleryLayout.preview.clampedSize(219.5) == 220)
    #expect(GalleryLayout.rows.sizes == Array(stride(from: 120.0, through: 300, by: 10)))
}
