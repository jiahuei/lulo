import AppKit
import ImageIO
import LuloCore
import LuloImaging
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
        try verifyArrowNavigation(viewer)
        print("Rendered native viewer previews and verified real-photo arrow navigation.")
        window.close()
    }

    /// Ensures real arrow events keep image/metadata selection consistent through reversals and rapid repeats.
    private static func verifyArrowNavigation(_ viewer: ViewerController) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = URL(fileURLWithPath: "Tests/LuloImagingTests/Fixtures/DSCF2143-LR-light.jpg")
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        for url in urls { try FileManager.default.copyItem(at: photo, to: url) }
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let metadata = descendants(root).compactMap({ $0 as? NSTextView }).first
        else { throw PreviewError.missingWindow }
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard ready() else { throw PreviewError.navigationFailed }
        }
        viewer.open(urls[0])
        try waitUntil { canvas.image != nil && metadata.string.contains("a.jpg") }
        // Only this temporary, harness-owned folder is granted; the real sandbox sheet is tested manually.
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "1 of 3" }
        }
        func arrow(_ direction: Int) throws {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: direction > 0 ? 124 : 123)
            else { throw PreviewError.navigationFailed }
            canvas.keyDown(with: event)
        }
        var index = 0
        for direction in [1, 1, -1, -1] {
            try arrow(direction)
            index = (index + direction + urls.count) % urls.count
            try waitUntil { canvas.image != nil && metadata.string.contains(urls[index].lastPathComponent) }
            guard canvas.image?.width == 4085, canvas.image?.height == 6128 else {
                throw PreviewError.navigationFailed
            }
        }
        // Queue rapid selections without waiting for intermediate decodes, including a direction reversal.
        for direction in [1, 1, 1, -1, 1, -1, -1] {
            try arrow(direction)
            index = (index + direction + urls.count) % urls.count
        }
        try waitUntil { canvas.image != nil && metadata.string.contains(urls[index].lastPathComponent) }
        guard window.title == urls[index].lastPathComponent else { throw PreviewError.navigationFailed }
        viewer.open(urls[0])
        viewer.open(urls[2])
        try waitUntil { canvas.image != nil && metadata.string.contains("c.jpg") }
        guard window.title == "c.jpg" else { throw PreviewError.navigationFailed }
        print("Verified arrow wrapping/reversal, rapid selections, and superseded explicit opens with the real photo.")
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
        case missingFilterControls, filterDidNotApply, filterDidNotClear, navigationFailed
    }
}
