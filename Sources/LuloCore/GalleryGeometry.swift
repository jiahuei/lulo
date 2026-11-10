import Foundation

// Apple's geometry types live in CoreGraphics; Linux Foundation provides them directly.
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Tile frames for the gallery layouts, in a top-down coordinate space starting at the content origin.
public enum GalleryGeometry {
    /// Fills each row exactly by scaling images at their own aspect ratios; the last row keeps the target height.
    public static func justifiedRows(
        aspectRatios: [Double], width: Double, targetHeight: Double, spacing: Double
    ) -> [CGRect] {
        var frames = [CGRect](repeating: .zero, count: aspectRatios.count)
        var row: [Int] = []
        var rowAspect = 0.0
        var y = 0.0
        func place(height: Double) {
            var x = 0.0
            for index in row {
                let tileWidth = aspectRatios[index] * height
                frames[index] = CGRect(x: x, y: y, width: tileWidth, height: height)
                x += tileWidth + spacing
            }
        }
        for index in aspectRatios.indices {
            row.append(index)
            rowAspect += aspectRatios[index]
            let available = max(1, width - spacing * Double(row.count - 1))
            if rowAspect * targetHeight >= available {
                let height = available / rowAspect
                place(height: height)
                y += height + spacing
                row = []
                rowAspect = 0
            }
        }
        // An incomplete last row would be enlarged past the target if stretched, so it stays left-aligned.
        place(height: targetHeight)
        return frames
    }

    /// Fills the width with equal square columns no smaller than the minimum tile size.
    public static func squareGrid(count: Int, width: Double, minimumTile: Double, spacing: Double) -> [CGRect] {
        let columns = max(1, Int((width + spacing) / (minimumTile + spacing)))
        let tile = max(1, (width - spacing * Double(columns - 1)) / Double(columns))
        return (0..<count).map { index in
            CGRect(
                x: Double(index % columns) * (tile + spacing), y: Double(index / columns) * (tile + spacing),
                width: tile, height: tile)
        }
    }

    /// The tile in the adjacent row whose horizontal center is nearest, or nil at the first or last row.
    public static func verticalNeighbor(of index: Int, in frames: [CGRect], direction: Int) -> Int? {
        guard frames.indices.contains(index), direction != 0 else { return nil }
        let rows = Set(frames.map(\.minY)).sorted()
        guard let row = rows.firstIndex(of: frames[index].minY), rows.indices.contains(row + direction.signum())
        else { return nil }
        let target = rows[row + direction.signum()]
        let center = frames[index].midX
        return frames.indices.filter { frames[$0].minY == target }.min {
            abs(frames[$0].midX - center) < abs(frames[$1].midX - center)
        }
    }
}
