import Foundation
import Testing

@testable import LuloCore

/// Ensures complete justified rows fill the available width, preserve aspect, and leave the final row unstretched.
@Test
func justifiedRowsPreserveAspectAndLastRow() {
    let ratios = [1.5, 0.5, 2, 1, 1.5, 0.75, 1.5]
    for width in [300.0, 664, 944] {
        let geometry = GalleryGeometry(aspectRatios: ratios, width: width, targetSize: 200, layout: .rows)
        #expect(geometry.frames.count == ratios.count)
        for (index, frame) in geometry.frames.enumerated() {
            #expect(abs(frame.width / frame.height - ratios[index]) < 0.0001)
            #expect(frame.minX >= 0 && frame.maxX <= width + 0.0001)
            if index + 1 < ratios.count && geometry.frames[index + 1].minY != frame.minY {
                #expect(abs(frame.maxX - width) < 0.0001)
            }
        }
        #expect(geometry.frames.last!.height <= 200)
        #expect(abs(geometry.height - Double(geometry.frames.last!.maxY)) < 0.0001)
    }
    let single = GalleryGeometry(aspectRatios: [1.5], width: 944, targetSize: 200, layout: .rows)
    #expect(single.frames == [CGRect(x: 0, y: 0, width: 300, height: 200)])
}

/// Ensures Preview fills columns with square tiles, handles narrow widths, and leaves no phantom empty content.
@Test
func previewGridGeometry() {
    for width in [100.0, 300, 644] {
        let geometry = GalleryGeometry(
            aspectRatios: Array(repeating: 1.5, count: 20), width: width, targetSize: 128, layout: .preview)
        #expect(geometry.frames.allSatisfy { $0.width == $0.height && $0.maxX <= width + 0.0001 })
        #expect(abs(Double(geometry.frames.last!.maxY) - geometry.height) < 0.0001)
    }
    #expect(GalleryGeometry(aspectRatios: [], width: 720, targetSize: 200, layout: .rows).height == 0)
}

/// Ensures up/down choose the nearest horizontal center in the adjacent row and do not jump past the edges.
@Test
func verticalGalleryNavigation() {
    let geometry = GalleryGeometry(aspectRatios: [1, 1, 1, 2, 1, 1, 1], width: 606, targetSize: 200, layout: .rows)
    #expect(geometry.verticalNeighbor(of: 0, direction: -1) == nil)
    #expect(geometry.verticalNeighbor(of: 1, direction: 1) == 3)
    #expect(geometry.verticalNeighbor(of: 2, direction: 1) == 4)
    #expect(geometry.verticalNeighbor(of: 6, direction: 1) == nil)
    let fallback = GalleryGeometry(aspectRatios: [0, .nan], width: 700, targetSize: 200, layout: .rows)
    #expect(fallback.frames.allSatisfy { $0.width / $0.height == 1.5 })
}

/// Ensures the badge counts every checked box, including a fully checked group, and clearing removes the count.
@Test
func filterBadgeCountsCheckedValues() {
    var filter = ImageFilter()
    #expect(filter.activeCount == 0)
    filter.ratings = [1, 2]
    #expect(filter.activeCount == 2)
    filter.formats = [.jpeg]
    #expect(filter.activeCount == 3)
    filter.ratings = Set(0...5)
    filter.formats = Set(ImageFormat.allCases)
    #expect(filter.activeCount == 9)
    filter = ImageFilter()
    #expect(filter.activeCount == 0)
}

/// Ensures presentation preferences default to plain Rows and persist independently of opening, sort, and filters.
@Test
func presentationPreferencesRoundTrip() throws {
    let name = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let initial = Preferences(defaults: defaults)
    #expect(!initial.blurredBackground && initial.galleryLayout == .rows)
    #expect(initial.rowsTargetHeight == 200 && initial.previewTileSize == 128)
    var saved = initial
    saved.blurredBackground = true
    saved.galleryLayout = .preview
    saved.rowsTargetHeight = 120
    saved.previewTileSize = 188
    saved.save(to: defaults)
    #expect(Preferences(defaults: defaults) == saved)
    var session = ViewingSession(preferences: saved)
    session.open(ImageEntry(url: URL(fileURLWithPath: "/fixture.png"), format: .png))
    #expect(session.preferences == saved)
    defaults.set("unknown", forKey: "galleryLayout")
    defaults.set(-20.0, forKey: "rowsTargetHeight")
    defaults.set(900.0, forKey: "previewTileSize")
    let recovered = Preferences(defaults: defaults)
    #expect(recovered.galleryLayout == .rows)
    #expect(recovered.rowsTargetHeight == 120 && recovered.previewTileSize == 220)
}

/// Ensures rows choose the nearer break and the final partial row is no taller than its neighbor.
@Test
func rowsTrackTargetHeightWithoutTallFinalRow() {
    for ratio in [1.5, 2.0 / 3] {
        let geometry = GalleryGeometry(
            aspectRatios: Array(repeating: ratio, count: 10), width: 944, targetSize: 200, layout: .rows)
        let firstRow = geometry.frames.filter { $0.minY == 0 }
        let count = firstRow.count
        let height = firstRow[0].height
        for alternative in [count - 1, count + 1] where alternative > 0 {
            let alternativeHeight = (944 - Double(alternative - 1) * 6) / (Double(alternative) * ratio)
            #expect(abs(height - 200) <= abs(alternativeHeight - 200))
        }
        let last = geometry.frames.last!
        let previous = geometry.frames.last { $0.minY < last.minY }!
        #expect(last.height <= previous.height && last.height <= 200)
    }
}

/// Ensures mouse values, persisted sizes, keys and two-step buttons share one grid, including endpoints.
@Test
func thumbnailSizesDoNotDriftAtEndpoints() {
    for layout in GalleryLayout.allCases {
        let values = layout.sizes
        #expect(values.first == layout.sizeRange.lowerBound)
        #expect(values.last == layout.sizeRange.upperBound)
        #expect(values.contains(layout.defaultSize))
        for (index, value) in values.enumerated() {
            #expect(layout.snappedSize(value) == value)
            #expect(layout.adjustedSize(value, steps: 1) == values[min(index + 1, values.count - 1)])
            #expect(layout.adjustedSize(value, steps: -1) == values[max(index - 1, 0)])
            #expect(layout.adjustedSize(value, steps: 2) == values[min(index + 2, values.count - 1)])
        }
        #expect(layout.snappedSize(.nan) == layout.defaultSize)
    }
    #expect(Preferences(previewTileSize: 94).previewTileSize == 92)
    let grid = GalleryGeometry(aspectRatios: [1, 1, 1, 1], width: 300, targetSize: 128, layout: .preview)
    #expect(grid.frames[1].minX - grid.frames[0].maxX == 6)
    #expect(grid.frames[2].minY - grid.frames[0].maxY == 6)
}
