import AppKit
import ImageIO
import LuloCore
import UniformTypeIdentifiers

/// Renders the actual viewer with synthetic data and checks that controls and metadata fit its window.
@main
@MainActor
enum RenderPreviews {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = output.appendingPathComponent("synthetic.png")
        try makeFixture(at: fixture)
        Preferences().save(to: .standard)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let viewer = ViewerController()
        viewer.showWindow(nil)
        guard let window = viewer.window else { throw PreviewError.missingWindow }
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.appearance = NSAppearance(named: .aqua)
        settle()
        try capture(window, to: output.appendingPathComponent("empty-light.png"))

        viewer.open(fixture)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            // Preview rendering is unsandboxed. Decline the real sheet rather than bypassing
            // authorization in application code; these captures do not verify sandbox behavior.
            if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
            if descendants(window.contentView!).compactMap({ $0 as? ImageCanvas }).first?.image != nil { break }
            settle()
        }
        guard descendants(window.contentView!).compactMap({ $0 as? ImageCanvas }).first?.image != nil else {
            throw PreviewError.imageDidNotLoad
        }
        settle()
        try capture(window, to: output.appendingPathComponent("image-light.png"))
        viewer.toggleSidebar()
        settle()
        try capture(window, to: output.appendingPathComponent("metadata-light.png"))
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 720, height: 480))
        settle()
        try capture(window, to: output.appendingPathComponent("metadata-compact-dark.png"))
        if let browse = window.toolbar?.items.compactMap({ $0.view as? NSButton }).first(where: { $0.title == "Browse" }
        ) {
            browse.performClick(nil)
            settle()
            if let popover = app.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil }) {
                try capture(popover, to: output.appendingPathComponent("browse-dark.png"))
                guard
                    let rating = descendants(popover.contentView!).compactMap({ $0 as? NSPopUpButton })
                        .first(where: { $0.toolTip == "Filter by exact star rating" })
                else {
                    throw PreviewError.missingFilterControls
                }
                rating.selectItem(at: 6)
                rating.sendAction(rating.action, to: rating.target)
                browse.performClick(nil)
                settle()
                guard let canvas = descendants(window.contentView!).compactMap({ $0 as? ImageCanvas }).first,
                    canvas.image == nil,
                    let clear = descendants(canvas).compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == "Clear Filters" && !$0.isHidden })
                else {
                    throw PreviewError.filterDidNotApply
                }
                try capture(window, to: output.appendingPathComponent("filtered-empty-dark.png"))
                clear.performClick(nil)
                let restoredDeadline = Date().addingTimeInterval(15)
                while canvas.image == nil && Date() < restoredDeadline { settle() }
                guard canvas.image != nil else { throw PreviewError.filterDidNotClear }
            } else {
                throw PreviewError.missingPopover
            }
        }
        print("Rendered native viewer previews with a synthetic image.")
        window.close()
    }

    private static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func capture(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView?.superview else { throw PreviewError.missingWindow }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewError.captureFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.captureFailed }
        try data.write(to: url)
        // Verify the rendered window contains a usable image area even with the inspector visible.
        if let canvas = descendants(view).compactMap({ $0 as? ImageCanvas }).first {
            guard canvas.frame.width >= 300, canvas.frame.height >= 250 else { throw PreviewError.clippedCanvas }
        }
    }

    private static func makeFixture(at url: URL) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 4800,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw PreviewError.captureFailed
        }
        context.setFillColor(CGColor(red: 0.14, green: 0.24, blue: 0.33, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        context.setFillColor(CGColor(red: 0.83, green: 0.72, blue: 0.48, alpha: 1))
        context.fillEllipse(in: CGRect(x: 800, y: 470, width: 180, height: 180))
        context.setFillColor(CGColor(red: 0.28, green: 0.43, blue: 0.42, alpha: 1))
        context.move(to: CGPoint(x: 0, y: 0))
        context.addLines(between: [
            CGPoint(x: 0, y: 180), CGPoint(x: 360, y: 520), CGPoint(x: 720, y: 160),
            CGPoint(x: 1000, y: 360), CGPoint(x: 1200, y: 180), CGPoint(x: 1200, y: 0),
        ])
        context.closePath()
        context.fillPath()
        guard let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw PreviewError.captureFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                "DateTimeOriginal": "2026:01:02 03:04:05", "FNumber": 2.8, "FocalLength": 35,
            ],
            kCGImagePropertyTIFFDictionary: ["Make": "Synthetic Camera", "Model": "Preview Fixture", "Artist": "Lulo"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.captureFailed }
    }

    private enum PreviewError: Error {
        case missingWindow, imageDidNotLoad, captureFailed, clippedCanvas, missingPopover
        case missingFilterControls, filterDidNotApply, filterDidNotClear
    }
}
