import Foundation

public enum GalleryLayout: String, CaseIterable, Sendable {
    case rows
    case preview

    public var sizeRange: ClosedRange<Double> { self == .rows ? 120...300 : 88...220 }
    public var sizeStep: Double { self == .rows ? 10 : 6 }
    public var defaultSize: Double { self == .rows ? 200 : 128 }

    public func clampedSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSize }
        return min(sizeRange.upperBound, max(sizeRange.lowerBound, value))
    }
}

/// Geometry shared by collection layout and vertical keyboard navigation, in top-left coordinates.
public struct GalleryGeometry: Sendable {
    public let frames: [CGRect]
    public let height: Double

    public init(aspectRatios: [Double], width: Double, targetSize: Double, layout: GalleryLayout) {
        let width = max(1, width)
        let target = layout.clampedSize(targetSize)
        var frames: [CGRect] = []
        var y = 0.0
        if layout == .preview {
            let columns = max(1, Int((width + 10) / (target + 10)))
            let side = (width - Double(columns - 1) * 10) / Double(columns)
            for index in aspectRatios.indices {
                frames.append(
                    CGRect(
                        x: Double(index % columns) * (side + 10),
                        y: Double(index / columns) * (side + 10), width: side, height: side))
            }
            y = Double(frames.last?.maxY ?? 0)
        } else {
            let ratios = aspectRatios.map { $0.isFinite && $0 > 0 ? $0 : 1.5 }
            var start = 0
            while start < ratios.count {
                var end = start
                var sum = ratios[start]
                while end + 1 < ratios.count && sum * target + Double(end - start) * 6 < width {
                    end += 1
                    sum += ratios[end]
                }
                let fitted = max(1, width - Double(end - start) * 6) / sum
                // The final row may shrink to fit, but must never stretch beyond the target.
                let rowHeight = end == ratios.count - 1 ? min(target, fitted) : fitted
                var x = 0.0
                for index in start...end {
                    let tileWidth = ratios[index] * rowHeight
                    frames.append(CGRect(x: x, y: y, width: tileWidth, height: rowHeight))
                    x += tileWidth + 6
                }
                y += rowHeight + 6
                start = end + 1
            }
            if !frames.isEmpty { y -= 6 }
        }
        self.frames = frames
        height = y
    }

    public func verticalNeighbor(of index: Int, direction: Int) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        let current = frames[index]
        let candidates = frames.indices.filter {
            direction < 0 ? frames[$0].midY < current.minY : frames[$0].midY > current.maxY
        }
        guard
            let row = candidates.min(by: {
                abs(frames[$0].midY - current.midY) < abs(frames[$1].midY - current.midY)
            })
        else { return nil }
        return candidates.filter { frames[$0].minY == frames[row].minY }.min {
            abs(frames[$0].midX - current.midX) < abs(frames[$1].midX - current.midX)
        }
    }
}
