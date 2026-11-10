import Foundation

// Apple's geometry types live in CoreGraphics; Linux Foundation provides them directly.
#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// Tile frames for the gallery layouts, in a top-down coordinate space starting at the content origin.
public enum GalleryGeometry {
    /// Fills each row exactly by scaling images at their own aspect ratios; the last row keeps the target height.
    /// Each row breaks where its height comes closest to the target, so a row can be slightly taller than the
    /// target rather than always shrinking to take one more image.
    public static func justifiedRows(
        aspectRatios: [Double], width: Double, targetHeight: Double, spacing: Double
    ) -> [CGRect] {
        var frames: [CGRect] = []
        frames.reserveCapacity(aspectRatios.count)
        var start = 0
        var y = 0.0
        while start < aspectRatios.count {
            var end = start
            var rowAspect = aspectRatios[start]
            var height = max(1, width) / rowAspect
            while end + 1 < aspectRatios.count, height > targetHeight {
                let nextAspect = rowAspect + aspectRatios[end + 1]
                let nextHeight = max(1, width - spacing * Double(end - start + 1)) / nextAspect
                if abs(height - targetHeight) <= abs(nextHeight - targetHeight) { break }
                end += 1
                rowAspect = nextAspect
                height = nextHeight
            }
            // An incomplete last row would be enlarged past the target if stretched, so it stays left-aligned.
            if end == aspectRatios.count - 1, height > targetHeight { height = targetHeight }
            var x = 0.0
            for index in start...end {
                let tileWidth = aspectRatios[index] * height
                frames.append(CGRect(x: x, y: y, width: tileWidth, height: height))
                x += tileWidth + spacing
            }
            y += height + spacing
            start = end + 1
        }
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
