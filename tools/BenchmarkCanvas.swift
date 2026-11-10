import AppKit
import LuloImaging

/// Measures the production canvas paint path with a decoded photo; excludes loading and window-server composition.
@main
@MainActor
enum BenchmarkCanvas {
    static func main() throws {
        _ = NSApplication.shared
        let photo = try ImageLoader.decode(at: URL(fileURLWithPath: CommandLine.arguments[1]))
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        canvas.image = photo
        // Dark mode's photo shadow is the larger of the two, so both appearances are measured.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            canvas.appearance = NSAppearance(named: appearance)
            measure(canvas, label: appearance == .aqua ? "light" : "dark")
        }
    }

    private static func measure(_ canvas: ImageCanvas, label: String) {
        for backingScale in [1, 2] {
            let pixelsWide = 1200 * backingScale
            let pixelsHigh = 800 * backingScale
            guard
                let context = CGContext(
                    data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: pixelsWide * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { fatalError("Cannot create benchmark context") }
            context.scaleBy(x: CGFloat(backingScale), y: CGFloat(backingScale))
            for mode in ["fit", "zoom-pan"] {
                canvas.resetZoom()
                if mode == "zoom-pan" { canvas.zoom.scroll(up: true, currentScale: 1) }
                var samples: [Double] = []
                for index in 0..<21 {
                    if mode == "zoom-pan" {
                        canvas.zoom.pan(
                            by: NSSize(width: index.isMultiple(of: 2) ? 20 : -20, height: 10),
                            imageSize: canvas.displayedImageRect.size, viewport: canvas.bounds)
                    }
                    let start = ContinuousClock.now
                    autoreleasepool {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                        context.clear(canvas.bounds)
                        canvas.draw(canvas.bounds)
                        context.flush()
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    let elapsed = start.duration(to: .now).components
                    if index > 0 { samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15) }
                }
                print(
                    "canvas_\(label)_\(mode)_\(backingScale)x: milliseconds=\(samples); median=\(samples.sorted()[samples.count / 2]); max=\(samples.max()!)"
                )
            }
        }
    }
}
