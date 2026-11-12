import AppKit
import Darwin
import ImageIO
import LuloCore
import LuloImaging
import UniformTypeIdentifiers

/// Renders the actual viewer with synthetic data and checks that controls and metadata fit its window.
@main
@MainActor
enum RenderPreviews {
    static func main() {
        do { try render() } catch {
            FileHandle.standardError.write(Data("Native preview verification failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func render() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = output.appendingPathComponent("synthetic.png")
        try makeFixture(at: fixture)
        Preferences().save(to: .standard)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        let viewer = ViewerController(automaticallyRefresh: false)
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
        try verifyTransparentCanvas(window)
        try verifyDisplayToggle(viewer)
        try verifyReviewRegressions(viewer)
        try verifySmallCanvasImages()
        try verifyBackgroundColorSpace()
        try capture(window, to: output.appendingPathComponent("image-light.png"))
        viewer.toggleSidebar()
        settle()
        try capture(window, to: output.appendingPathComponent("metadata-light.png"))
        viewer.toggleBlurredBackground()
        for _ in 0..<5 { settle() }
        try capture(window, to: output.appendingPathComponent("metadata-blurred-light.png"))
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 720, height: 480))
        settle()
        guard abs(window.contentView!.bounds.width - 720) < 0.5 else { throw PreviewError.clippedCanvas }
        try capture(window, to: output.appendingPathComponent("metadata-blurred-compact-dark.png"))
        viewer.toggleBlurredBackground()
        for _ in 0..<3 { settle() }
        try capture(window, to: output.appendingPathComponent("metadata-compact-dark.png"))
        try verifyLoadingOverlay(window, output: output)
        FileHandle.standardError.write(Data("Checking D9 Sort & Filter popover.\n".utf8))
        if let browse = toolbarControl(window, "Browse")
            as? NSButton
        {
            browse.performClick(nil)
            settle()
            if let popover = app.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil }) {
                try capture(popover, to: output.appendingPathComponent("browse-dark.png"))
                try verifyFilterCheckboxes(popover: popover, viewer: window)
                try capture(popover, to: output.appendingPathComponent("browse-selected-dark.png"))
                try capture(window, to: output.appendingPathComponent("filter-badge-dark.png"), activate: false)
                browse.performClick(nil)
                settle()
                guard let canvas = descendants(window.contentView!).compactMap({ $0 as? ImageCanvas }).first,
                    canvas.image == nil,
                    let clear = descendants(canvas).compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == "Clear Filters" && !$0.isHidden })
                else {
                    throw PreviewError.filterDidNotApply
                }
                // Empty-state copy must use the available canvas width beside the metadata panel.
                guard
                    let title = descendants(canvas).compactMap({ $0 as? NSTextField })
                        .first(where: { $0.stringValue == "No images match the current filters." }),
                    let textHeight = title.cell?.cellSize(
                        forBounds: NSRect(
                            x: 0, y: 0, width: title.bounds.width, height: .greatestFiniteMagnitude)
                    ).height,
                    title.bounds.height + 1 >= textHeight,
                    canvas.bounds.contains(canvas.convert(title.bounds, from: title)),
                    canvas.bounds.contains(canvas.convert(clear.bounds, from: clear))
                else { throw PreviewError.clippedCanvas }
                try capture(window, to: output.appendingPathComponent("filtered-empty-dark.png"))
                clear.performClick(nil)
                let restoredDeadline = Date().addingTimeInterval(15)
                while canvas.image == nil && Date() < restoredDeadline { settle() }
                guard canvas.image != nil else { throw PreviewError.filterDidNotClear }
            } else {
                throw PreviewError.missingPopover
            }
        } else {
            throw PreviewError.missingFilterControls
        }
        try verifyArrowNavigation(viewer, output: output)
        try verifyCachedNavigation(fixture: fixture)
        try verifyObsoleteFolderScan(fixture: fixture)
        try verifyGallery(fixture: fixture, output: output)
        try verifyPreviewRetention()
        try verifyRefreshAnimation(fixture: fixture)
        try verifyRefreshAndRatings(output: output)
        try verifyAutomaticRefresh()
        try verifyTrashAction(fixture: fixture, output: output)
        print("Rendered native viewer previews and verified real-photo arrow navigation.")
        window.close()
    }

    /// Ensures tiny icons, thin panoramas and minimum zoom paint at both raster scales without invalid corners.
    private static func verifySmallCanvasImages() throws {
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        for (width, height, mode) in [(2, 2, "actual"), (10000, 20, "fit"), (100, 100, "minimum")] {
            canvas.image = try solidImage(width: width, height: height)
            canvas.resetZoom(to: mode == "actual" ? .actualSize : .fit)
            if mode == "minimum" {
                for _ in 0..<100 { canvas.zoom.scroll(up: false, currentScale: canvas.zoom.scale ?? 1) }
            }
            let rect = canvas.displayedImageRect
            guard min(rect.width, rect.height) < 6 else { throw PreviewError.clippedCanvas }
            for scale in [1, 2] {
                guard
                    let context = CGContext(
                        data: nil, width: 1000 * scale, height: 700 * scale, bitsPerComponent: 8,
                        bytesPerRow: 4000 * scale,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { throw PreviewError.captureFailed }
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                canvas.draw(canvas.bounds)
                NSGraphicsContext.restoreGraphicsState()
                guard let image = context.makeImage(),
                    let center = NSBitmapImageRep(cgImage: image).colorAt(x: 500 * scale, y: 350 * scale),
                    // A subpixel image can cover far less than one raster pixel.
                    center.alphaComponent > 0
                else { throw PreviewError.smallImageFailed(mode: mode, scale: scale, rect: rect) }
            }
        }
        print("Verified tiny-icon, thin-panorama and minimum-zoom canvas painting at 1x/2x raster scales.")
    }

    /// Ensures background brightness multiplies encoded sRGB values, catching accidental linear-light filtering.
    private static func verifyBackgroundColorSpace() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try solidImage(width: 32, height: 32)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PreviewError.captureFailed
        }
        try data.write(to: url)
        let loader = ThumbnailLoader()
        let renderer = BackgroundRenderer()
        var finished = false
        var images: BackgroundImages?
        let task = Task {
            defer { finished = true }
            if let thumbnail = try? await loader.load(at: url, access: FileAccess(url: url)) {
                images = await renderer.render(thumbnail)
            }
        }
        defer { task.cancel() }
        let deadline = Date().addingTimeInterval(15)
        while !finished && Date() < deadline { settle() }
        guard let images else { throw PreviewError.captureFailed }
        for (image, multiplier) in [(images.light, 1.06), (images.dark, 0.55)] {
            guard let color = NSBitmapImageRep(cgImage: image).colorAt(x: 16, y: 16)?.usingColorSpace(.sRGB),
                [color.redComponent, color.greenComponent, color.blueComponent].allSatisfy({
                    abs($0 - 0.5 * multiplier) < 0.015
                })
            else { throw PreviewError.captureFailed }
        }
        print("Verified light/dark background brightness in gamma-encoded sRGB.")
    }

    /// Provides neutral sRGB pixels without metadata for canvas and background rendering regressions.
    private static func solidImage(width: Int, height: Int) throws -> CGImage {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PreviewError.captureFailed }
        context.setFillColor(CGColor(colorSpace: context.colorSpace!, components: [0.5, 0.5, 0.5, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw PreviewError.captureFailed }
        return image
    }

    /// Ensures sort/filter actions retain a loaded poster and caption, while explicit refresh replaces its pixels.
    private static func verifyPreviewRetention() throws {
        let saved = Preferences(defaults: .standard)
        Preferences().save(to: .standard)
        defer { saved.save(to: .standard) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.png")
        try makeFixture(at: first, rating: 1)
        try makeFixture(at: folder.appendingPathComponent("b.png"), rating: 2)
        let viewer = ViewerController(automaticallyRefresh: false)
        guard let window = viewer.window, let root = window.contentView,
            let gallery = descendants(root).compactMap({ $0 as? GalleryView }).first,
            let collection = descendants(gallery).compactMap({ $0 as? NSCollectionView }).first,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let browse = toolbarControl(window, "Browse") as? NSButton
        else { throw PreviewError.galleryFailed(line: #line) }
        defer { window.close() }
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
                settle()
            }
            guard ready() else { throw PreviewError.galleryFailed(line: #line) }
        }
        viewer.open(first)
        try waitUntil { canvas.image != nil && window.attachedSheet == nil }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        viewer.showPreview()
        guard
            let poster = descendants(gallery).compactMap({ $0 as? NSImageView })
                .first(where: { !($0 is GalleryThumbnailView) }), let container = poster.superview,
            let caption = container.subviews.compactMap({ $0 as? NSTextField })
                .first(where: { !($0 is RatingChip) && $0.stringValue != "a.png" })
        else { throw PreviewError.galleryFailed(line: #line) }
        try waitUntil { collection.numberOfItems(inSection: 0) == 2 && poster.image?.size.width == 1200 }
        guard let original = poster.image, !caption.stringValue.isEmpty else {
            throw PreviewError.galleryFailed(line: #line)
        }
        let originalCaption = caption.stringValue
        browse.performClick(nil)
        settle()
        guard
            let popover = NSApp.windows.first(where: {
                $0 !== window && $0.isVisible
                    && $0.contentView.map {
                        descendants($0).compactMap { $0 as? NSButton }.contains { $0.title == "Descending" }
                    } == true
            }), let content = popover.contentView,
            let descending = descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                $0.title == "Descending"
            }),
            let oneStar = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "1 Star" })
        else { throw PreviewError.missingPopover }
        descending.performClick(nil)
        guard poster.image === original, caption.stringValue == originalCaption,
            collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)]
        else { throw PreviewError.galleryFailed(line: #line) }
        oneStar.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 1, poster.image === original,
            caption.stringValue == originalCaption
        else { throw PreviewError.galleryFailed(line: #line) }
        oneStar.performClick(nil)
        browse.performClick(nil)
        try makeFixture(at: first, rating: 1, orientation: 6, aperture: 7.1)
        viewer.refreshImages()
        try waitUntil { poster.image?.size.width == 800 && poster.image?.size.height == 1200 }
        guard poster.image !== original, caption.stringValue.contains("f/7.1") else {
            throw PreviewError.galleryFailed(line: #line)
        }
        print("Verified Preview poster/caption retention after sorting and filtering, and replacement after Refresh.")
    }

    /// Ensures native click states, unobscured layout, larger fit images, and painting without status mutations.
    private static func verifyReviewRegressions(_ viewer: ViewerController) throws {
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)
        else { throw PreviewError.captureFailed }
        for identifier in ["Metadata", "Blurred Background"] {
            guard let button = toolbarControl(window, identifier) as? CapsuleButton, button.showsSelection else {
                throw PreviewError.captureFailed
            }
            let initial = button.state
            for _ in 0..<3 {
                button.performClick(nil)
                guard button.state != initial, button.isVisuallySelected == (button.state == .on),
                    !button.isHighlighted
                else { throw PreviewError.captureFailed }
                button.performClick(nil)
                guard button.state == initial, !button.isHighlighted else { throw PreviewError.captureFailed }
            }
        }
        settle()
        let callback = canvas.zoomChanged
        var updates = 0
        canvas.zoomChanged = {
            updates += 1
            callback?()
        }
        defer { canvas.zoomChanged = callback }
        canvas.resetZoom()
        guard updates > 0 else { throw PreviewError.displayToggleFailed }
        updates = 0
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        guard updates == 0 else { throw PreviewError.displayToggleFailed }
        let rect = canvas.displayedImageRect
        guard abs(min(rect.minX, rect.minY) - 8) < 1 else { throw PreviewError.clippedCanvas }
        window.toolbar?.isVisible = false
        settle()
        let top = root.convert(canvas.bounds, from: canvas).maxY
        guard abs(top - root.safeAreaRect.maxY) < 1 else { throw PreviewError.clippedCanvas }
        window.toolbar?.isVisible = true
        settle()

        let tile = GalleryThumbnailView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        tile.image = NSImage(cgImage: canvas.image!, size: .zero)
        tile.presentation = .preview
        let area = NSTrackingArea(
            rect: tile.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: tile, userInfo: nil)
        tile.addTrackingArea(area)
        tile.updateTrackingAreas()
        guard tile.trackingAreas.contains(area) else { throw PreviewError.galleryFailed(line: #line) }
        let original = tile.displayedImageRect
        guard
            let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { throw PreviewError.galleryFailed(line: #line) }
        tile.mouseEntered(with: event)
        tile.resetHover()
        guard tile.displayedImageRect == original else { throw PreviewError.galleryFailed(line: #line) }
        print(
            "Verified native toggle release, safe-area layout, 8-point fit inset, pure canvas painting, and hover reset."
        )
    }

    /// Ensures the canvas preserves transparent source pixels against the window background.
    private static func verifyTransparentCanvas(_ window: NSWindow) throws {
        guard let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let original = canvas.image,
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PreviewError.captureFailed }
        context.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
        canvas.image = context.makeImage()
        defer { canvas.image = original }
        settle()
        guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else {
            throw PreviewError.captureFailed
        }
        root.cacheDisplay(in: root.bounds, to: bitmap)
        guard let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB),
            center.redComponent > 0.8, center.greenComponent > 0.8, center.blueComponent > 0.8
        else { throw PreviewError.captureFailed }
    }

    /// Ensures the toolbar selects the current mode, double-click stays in sync, and new viewers always start in fit.
    private static func verifyDisplayToggle(_ viewer: ViewerController) throws {
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let display = toolbarControl(window, "Display")
                as? ButtonChoices,
            display.selectedIndex == 0, display.buttons[1].glyph == nil, display.buttons[1].title == "100%",
            canvas.zoom.mode == .fit, canvas.zoom.scale == nil
        else { throw PreviewError.displayToggleFailed }
        for (segment, expected) in [(1, ViewingMode.actualSize), (1, .actualSize), (0, .fit), (0, .fit)] {
            canvas.zoom.scroll(up: true, currentScale: 2)
            display.buttons[segment].performClick(nil)
            guard display.buttons[segment].accessibilityRole() == .radioButton,
                display.buttons[segment].accessibilityValue() as? NSNumber == NSNumber(value: true),
                !display.buttons[segment].isHighlighted, display.buttons[segment].isVisuallySelected,
                canvas.zoom.mode == expected,
                canvas.zoom.scale == (expected == .fit ? nil : 1)
            else { throw PreviewError.displayToggleFailed }
            let cursor = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            try doubleClick(canvas, at: cursor)
            guard display.selectedIndex == (segment == 0 ? 1 : 0),
                canvas.zoom.scale == (expected == .fit ? 1 : nil)
            else { throw PreviewError.displayToggleFailed }
            try doubleClick(canvas, at: cursor)
            guard display.selectedIndex == segment else { throw PreviewError.displayToggleFailed }
            let restored = ViewerController()
            defer { restored.window?.close() }
            guard
                let restoredDisplay = toolbarControl(restored.window, "Display") as? ButtonChoices,
                restoredDisplay.selectedIndex == 0
            else { throw PreviewError.displayToggleFailed }
        }
        canvas.resetZoom(to: .actualSize)
        window.close()
        viewer.showWindow(nil)
        guard canvas.zoom.mode == .fit, canvas.zoom.scale == nil, display.selectedIndex == 0 else {
            throw PreviewError.displayToggleFailed
        }
    }

    private static func doubleClick(_ canvas: ImageCanvas, at point: CGPoint) throws {
        guard let window = canvas.window,
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)
        else { throw PreviewError.displayToggleFailed }
        canvas.mouseDown(with: event)
    }

    /// Ensures Gallery defaults to Preview and its grid preserves ratings, selection, filters, and Trash restrictions.
    private static func verifyGallery(fixture: URL, output: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = (1...80).map { folder.appendingPathComponent("photo\($0).png") }
        for (index, url) in urls.enumerated() {
            if index < 6 {
                try makeFixture(at: url, rating: (index + 1) % 6, orientation: index == 1 ? 6 : 1)
            } else {
                try FileManager.default.copyItem(at: fixture, to: url)
            }
        }
        try Data().write(to: folder.appendingPathComponent("broken.jpg"))
        let viewer = ViewerController()
        guard let window = viewer.window, let root = window.contentView,
            let gallery = descendants(root).compactMap({ $0 as? GalleryView }).first,
            let collection = descendants(gallery).compactMap({ $0 as? NSCollectionView }).first,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let display = toolbarControl(window, "Display")
                as? ButtonChoices,
            let layouts = toolbarControl(window, "GalleryLayout") as? ButtonChoices,
            let trash = toolbarControl(window, "Trash") as? NSButton
        else { throw PreviewError.galleryFailed(line: #line) }
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 680))
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.galleryFailed(line: #line) }
        }
        func key(_ code: UInt16) throws {
            let characters = code == 124 ? "\u{F703}" : "\r"
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)
            else { throw PreviewError.galleryFailed(line: #line) }
            collection.keyDown(with: event)
        }
        /// Ensures loaded and reused cells announce their own rating, including zero and missing ratings.
        func thumbnailsReady() -> Bool {
            let items = collection.visibleItems().filter { $0.textField?.stringValue != "broken.jpg" }
            return !items.isEmpty
                && items.allSatisfy {
                    guard let name = $0.textField?.stringValue, let preview = $0.imageView,
                        let image = preview.image
                    else { return false }
                    let rating = (1...5).first { name == "photo\($0).png" }
                    let label = name + (rating.map { ", \($0) of 5 stars" } ?? "")
                    return image.size.width <= 320 && image.size.height <= 320 && preview.accessibilityLabel() == label
                }
        }
        viewer.open(urls[0])
        try waitUntil { !canvas.isLoading && canvas.image != nil && window.attachedSheet == nil }
        canvas.resetZoom(to: .actualSize)
        viewer.toggleGallery()
        guard gallery.isHidden, collection.numberOfItems(inSection: 0) == 0, canvas.zoom.mode == .actualSize else {
            throw PreviewError.galleryFailed(line: #line)
        }
        (window.attachedSheet as? NSOpenPanel)?.cancel(nil)
        settle()
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        viewer.toggleGallery()
        guard viewer.selectedGalleryLayout == .preview, layouts.selectedIndex == 0,
            layouts.buttons.map({ $0.accessibilityLabel() }) == ["Preview (⌘2)", "Rows (⌘1)"]
        else { throw PreviewError.galleryFailed(line: #line) }
        // The following aspect-ratio checks exercise Rows rather than Preview's square crops.
        layouts.buttons[1].performClick(nil)
        for _ in 0..<4 { viewer.smallerThumbnails() }
        try waitUntil {
            collection.numberOfItems(inSection: 0) == 81
                && collection.visibleItems().contains { $0.imageView?.image != nil }
        }
        guard !gallery.isHidden, canvas.isHidden, collection.visibleItems().count < 81,
            collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)],
            !viewer.canTrashCurrentImage, !trash.isEnabled, !display.isEnabled,
            display.selectedIndex == 0, canvas.zoom.mode == .fit, canvas.zoom.scale == nil
        else { throw PreviewError.galleryFailed(line: #line) }
        viewer.trashCurrentImage()
        guard window.attachedSheet == nil else { throw PreviewError.galleryFailed(line: #line) }
        try waitUntil {
            descendants(gallery).compactMap { $0 as? GalleryThumbnailView }.contains { $0.failed }
        }
        try waitUntil { thumbnailsReady() }
        // Overlay geometry must locate the actual pixels, including the rotated portrait fixture.
        for index in 1...6 {
            guard
                let preview = collection.item(at: IndexPath(item: index, section: 0))?.imageView
                    as? GalleryThumbnailView, let image = preview.image
            else { throw PreviewError.galleryRatingPlacementFailed }
            let rect = preview.displayedImageRect
            guard abs(rect.width / rect.height - image.size.width / image.size.height) < 0.02,
                abs(rect.midX - preview.bounds.midX) < 0.01,
                abs(rect.midY - preview.bounds.midY) < 0.01,
                index != 2 || rect.height > rect.width
            else { throw PreviewError.galleryRatingPlacementFailed }
        }
        window.appearance = NSAppearance(named: .aqua)
        settle()
        try capture(window, to: output.appendingPathComponent("gallery-light.png"))
        try verifyD9Gallery(viewer, output: output)

        try key(124)
        guard collection.selectionIndexPaths == [IndexPath(item: 2, section: 0)] else {
            throw PreviewError.galleryFailed(line: #line)
        }
        try key(36)
        try waitUntil { gallery.isHidden && viewer.canTrashCurrentImage && window.title == "photo2.png" }
        guard display.isEnabled, display.selectedIndex == 0, canvas.zoom.mode == .fit, canvas.zoom.scale == nil else {
            throw PreviewError.displayToggleFailed
        }
        viewer.toggleGallery()
        guard collection.selectionIndexPaths == [IndexPath(item: 2, section: 0)] else {
            throw PreviewError.galleryFailed(line: #line)
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 720, height: 480))
        settle()
        try waitUntil { thumbnailsReady() }
        try capture(window, to: output.appendingPathComponent("gallery-compact-dark.png"))
        for index in [80, 1, 70, 2] {
            collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
            settle()
            try waitUntil { thumbnailsReady() }
        }
        // The existing filter controls must affect both views, including recovery from no matches.
        guard
            let browse = toolbarControl(window, "Browse")
                as? NSButton
        else { throw PreviewError.galleryFailed(line: #line) }
        browse.performClick(nil)
        settle()
        guard
            let popover = NSApp.windows.first(where: {
                $0 !== window && $0.isVisible
                    && $0.contentView.map {
                        descendants($0).compactMap { $0 as? NSButton }.contains {
                            $0.title == "5 Stars"
                        }
                    } == true
            }),
            let fiveStars = descendants(popover.contentView!).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "5 Stars" }),
            let fourStars = descendants(popover.contentView!).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "4 Stars" }),
            let jpeg = descendants(popover.contentView!).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "JPEG" }),
            let png = descendants(popover.contentView!).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "PNG" })
        else { throw PreviewError.galleryFailed(line: #line) }
        fiveStars.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 1 else { throw PreviewError.galleryFailed(line: #line) }
        try waitUntil { thumbnailsReady() }
        guard collection.item(at: IndexPath(item: 0, section: 0))?.textField?.stringValue == "photo5.png" else {
            throw PreviewError.galleryFailed(line: #line)
        }
        fourStars.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 2 else { throw PreviewError.galleryFailed(line: #line) }
        try waitUntil { thumbnailsReady() }
        jpeg.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 0 else { throw PreviewError.galleryFailed(line: #line) }
        png.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 2 else { throw PreviewError.galleryFailed(line: #line) }
        try waitUntil { thumbnailsReady() }
        png.performClick(nil)
        browse.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 0,
            let clear = descendants(gallery).compactMap({ $0 as? NSButton }).first(where: {
                $0.title == "Clear Filters"
            })
        else { throw PreviewError.galleryFailed(line: #line) }
        clear.performClick(nil)
        try waitUntil { collection.numberOfItems(inSection: 0) == 81 }
        // A new explicit open must close the gallery and discard its old cells and thumbnail requests.
        viewer.open(fixture)
        try waitUntil { gallery.isHidden && !canvas.isLoading && window.title == fixture.lastPathComponent }
        guard collection.numberOfItems(inSection: 0) == 0 else { throw PreviewError.galleryFailed(line: #line) }
        print(
            "Verified gallery permissions, rated thumbnails, keyboard opening, reuse, multi-select filters, Trash availability, and session reset."
        )
    }

    /// Ensures Trash confirmation, cancellation, failure, navigation, and stale completion use the captured image.
    private static func verifyTrashAction(fixture: URL, output: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("images")
        let discarded = root.appendingPathComponent("discarded")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: discarded, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = folder.appendingPathComponent("a.png")
        let second = folder.appendingPathComponent("b.png")
        let replacement = root.appendingPathComponent("new.png")
        for url in [first, second, replacement] { try FileManager.default.copyItem(at: fixture, to: url) }
        let operation = TrashPreviewOperation(destination: discarded)
        let viewer = ViewerController(moveToTrash: { try await operation.move($0, access: $1) })
        guard let window = viewer.window, let content = window.contentView,
            let canvas = descendants(content).compactMap({ $0 as? ImageCanvas }).first,
            let trash = toolbarControl(window, "Trash") as? NSButton
        else { throw PreviewError.trashFailed }
        defer { window.close() }
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.trashFailed }
        }
        func clickSheetButton(_ title: String) throws {
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title })
            else { throw PreviewError.trashFailed }
            button.performClick(nil)
            settle()
        }
        func confirmTrash() throws {
            viewer.trashCurrentImage()
            try clickSheetButton("Move to Trash")
            try waitUntil { operation.pendingURL != nil }
            guard !viewer.canTrashCurrentImage else { throw PreviewError.trashFailed }
        }
        guard !viewer.canTrashCurrentImage, !trash.isEnabled else { throw PreviewError.trashFailed }
        viewer.open(first)
        guard !viewer.canTrashCurrentImage else { throw PreviewError.trashFailed }
        try waitUntil { viewer.canTrashCurrentImage }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil {
            descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "1 of 2" }
        }
        trash.performClick(nil)
        settle()
        guard let sheet = window.attachedSheet else { throw PreviewError.trashFailed }
        try capture(sheet, to: output.appendingPathComponent("trash-confirmation.png"))
        try clickSheetButton("Cancel")
        guard operation.pendingURL == nil, viewer.canTrashCurrentImage,
            FileManager.default.fileExists(atPath: first.path)
        else { throw PreviewError.trashFailed }

        try confirmTrash()
        operation.fail()
        try waitUntil { window.attachedSheet != nil }
        try clickSheetButton("OK")
        guard window.title == "a.png", canvas.image != nil, FileManager.default.fileExists(atPath: first.path) else {
            throw PreviewError.trashFailed
        }
        try confirmTrash()
        try operation.succeed()
        try waitUntil { window.title == "b.png" && viewer.canTrashCurrentImage }
        guard !FileManager.default.fileExists(atPath: first.path), FileManager.default.fileExists(atPath: second.path)
        else { throw PreviewError.trashFailed }

        try confirmTrash()
        viewer.open(replacement)
        try waitUntil { !canvas.isLoading && window.attachedSheet == nil }
        guard operation.pendingURL == second, window.title == "new.png" else { throw PreviewError.trashFailed }
        try operation.succeed()
        try waitUntil { viewer.canTrashCurrentImage }
        guard window.title == "new.png", FileManager.default.fileExists(atPath: replacement.path) else {
            throw PreviewError.trashFailed
        }
        try confirmTrash()
        try operation.succeed()
        try waitUntil {
            descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "No images remaining" }
        }
        guard !viewer.canTrashCurrentImage, !trash.isEnabled, canvas.image == nil else {
            throw PreviewError.trashFailed
        }
        print("Verified Trash confirmation, cancellation, failure, next selection, last image, and stale completion.")
    }

    /// Ensures mouse hit testing and native tracking select each layout once, including after a toolbar update.
    private static func verifyGalleryMouseTracking(_ viewer: ViewerController) throws {
        guard let window = viewer.window, let root = window.contentView,
            let layouts = toolbarControl(window, "GalleryLayout") as? ButtonChoices,
            let gallery = descendants(root).compactMap({ $0 as? GalleryView }).first,
            let collection = descendants(gallery).compactMap({ $0 as? NSCollectionView }).first,
            let posterButton = descendants(gallery).compactMap({ $0 as? ProminentButton })
                .first(where: { $0.title == "View" }),
            let slider = toolbarControl(window, "ThumbnailSize") as? NSSlider
        else { throw PreviewError.galleryFailed(line: #line) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        settle()
        let selected = collection.selectionIndexPaths
        for index in layouts.buttons.indices {
            let button = layouts.buttons[index]
            let mode: GalleryLayout = index == 0 ? .preview : .rows
            let bounds = button.bounds
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let points = [
                center, CGPoint(x: bounds.minX + 2, y: bounds.midY),
                CGPoint(x: bounds.maxX - 2, y: bounds.midY),
                CGPoint(x: bounds.midX, y: bounds.minY + 2),
                CGPoint(x: bounds.midX, y: bounds.maxY - 2),
            ]
            for point in points {
                if mode == .preview { viewer.showRows() } else { viewer.showPreview() }
                try sendMouseGesture(to: button, at: point)
                guard viewer.selectedGalleryLayout == mode, layouts.selectedIndex == index,
                    button.state == .on, !button.isHighlighted,
                    collection.selectionIndexPaths == selected,
                    posterButton.isHiddenOrHasHiddenAncestor == (mode == .rows),
                    slider.accessibilityLabel() == (mode == .preview ? "Thumbnail size" : "Row height")
                else {
                    throw PreviewError.galleryMouseFailed(layout: mode.rawValue, point: point, line: #line)
                }
            }
            if mode == .preview { viewer.showRows() } else { viewer.showPreview() }
            let previous = viewer.selectedGalleryLayout
            let outside = CGPoint(x: center.x, y: bounds.minY - 20)
            try sendMouseGesture(to: button, at: center, releaseAt: outside)
            guard viewer.selectedGalleryLayout == previous, collection.selectionIndexPaths == selected,
                posterButton.isHiddenOrHasHiddenAncestor == (previous == .rows)
            else {
                throw PreviewError.galleryMouseFailed(layout: mode.rawValue, point: outside, line: #line)
            }
            try sendMouseGesture(to: button, at: center) {
                viewer.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
            }
            guard viewer.selectedGalleryLayout == mode, layouts.selectedIndex == index,
                collection.selectionIndexPaths == selected,
                posterButton.isHiddenOrHasHiddenAncestor == (mode == .rows)
            else { throw PreviewError.galleryMouseFailed(layout: mode.rawValue, point: center, line: #line) }
        }
        print("Verified gallery mouse centers/edges, drag cancellation, and toolbar updates during tracking.")
    }

    /// Sends queued mouse events through NSApplication so the window hit-tests and the button tracks its release.
    private static func sendMouseGesture(
        to button: NSButton, at point: CGPoint, releaseAt end: CGPoint? = nil,
        duringTracking: (@MainActor @Sendable () -> Void)? = nil
    ) throws {
        guard let window = button.window else { throw PreviewError.missingWindow }
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: button.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            else { throw PreviewError.galleryFailed(line: #line) }
            return event
        }
        let down = try event(.leftMouseDown, at: point)
        let up = try event(.leftMouseUp, at: end ?? point)
        var timer: Timer?
        defer {
            timer?.invalidate()
            // A rejected mouse-down can leave its release queued; do not contaminate the next gesture.
            while let event = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true)
            {
                NSApp.sendEvent(event)
            }
        }
        if let duringTracking {
            // Withhold mouse-up until AppKit enters its tracking loop, establishing the overlap deterministically.
            let release = Timer(timeInterval: 0.01, repeats: false) { _ in
                MainActor.assumeIsolated {
                    duringTracking()
                    NSApp.postEvent(up, atStart: true)
                }
            }
            timer = release
            RunLoop.main.add(release, forMode: .eventTracking)
        } else {
            NSApp.postEvent(up, atStart: true)
            if let end { NSApp.postEvent(try event(.leftMouseDragged, at: end), atStart: true) }
        }
        NSApp.postEvent(down, atStart: true)
        guard
            let queued = NSApp.nextEvent(
                matching: .leftMouseDown, until: Date(), inMode: .default, dequeue: true)
        else { throw PreviewError.galleryFailed(line: #line) }
        NSApp.sendEvent(queued)
        guard timer?.isValid != true else { throw PreviewError.galleryFailed(line: #line) }
    }

    /// Ensures Preview/Rows buttons select their layouts and preserve selection and alignment down to 720 pt.
    private static func verifyD9Gallery(_ viewer: ViewerController, output: URL) throws {
        guard let window = viewer.window, let root = window.contentView,
            let gallery = descendants(root).compactMap({ $0 as? GalleryView }).first,
            let collection = descendants(gallery).compactMap({ $0 as? NSCollectionView }).first,
            let layouts = toolbarControl(window, "GalleryLayout") as? ButtonChoices,
            let slider = toolbarControl(window, "ThumbnailSize") as? NSSlider
        else { throw PreviewError.galleryFailed(line: #line) }
        let selected = collection.selectionIndexPaths
        for width in [1000.0, 720] {
            window.setContentSize(NSSize(width: width, height: 680))
            try verifyGalleryMouseTracking(viewer)
            for preview in [true, false] {
                layouts.buttons[preview ? 0 : 1].performClick(nil)
                settle()
                guard collection.selectionIndexPaths == selected,
                    viewer.selectedGalleryLayout == (preview ? .preview : .rows),
                    layouts.selectedIndex == (preview ? 0 : 1),
                    layouts.buttons[layouts.selectedIndex].accessibilityValue() as? NSNumber == NSNumber(value: true),
                    slider.accessibilityLabel() == (preview ? "Thumbnail size" : "Row height"),
                    let galleryButton = toolbarControl(window, "Gallery") as? CapsuleButton,
                    !galleryButton.isVisuallySelected,
                    layouts.buttons.allSatisfy({ !$0.isVisuallySelected && !$0.isHighlighted })
                else { throw PreviewError.galleryFailed(line: #line) }
                let before = slider.doubleValue
                let mode = preview ? GalleryLayout.preview : .rows
                slider.doubleValue = mode.sizeRange.lowerBound
                slider.sendAction(slider.action, to: slider.target)
                guard slider.accessibilityPerformIncrement(),
                    slider.doubleValue == mode.adjustedSize(mode.sizeRange.lowerBound, steps: 1),
                    slider.accessibilityPerformDecrement(), slider.doubleValue == mode.sizeRange.lowerBound
                else { throw PreviewError.galleryFailed(line: #line) }
                slider.doubleValue = before
                slider.sendAction(slider.action, to: slider.target)
                guard
                    let arrow = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
                        charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)
                else { throw PreviewError.galleryFailed(line: #line) }
                window.makeFirstResponder(slider)
                slider.keyDown(with: arrow)
                guard slider.doubleValue == before + (preview ? 6 : 10), collection.selectionIndexPaths == selected
                else {
                    throw PreviewError.galleryFailed(line: #line)
                }
                viewer.smallerThumbnails()
                viewer.largerThumbnails()
                guard slider.doubleValue > before, collection.selectionIndexPaths == selected else {
                    throw PreviewError.galleryFailed(line: #line)
                }
                slider.doubleValue = before
                slider.sendAction(slider.action, to: slider.target)
                guard abs(root.bounds.width - width) < 0.5 else { throw PreviewError.galleryFailed(line: #line) }
                let required = ["Display", "Navigation", "Files", "Actions"]
                guard
                    window.toolbar?.visibleItems?.map({ $0.itemIdentifier.rawValue })
                        .filter({ required.contains($0) }) == required
                else {
                    let widths =
                        window.toolbar?.items.map {
                            "\($0.itemIdentifier.rawValue): fit=\($0.view?.fittingSize.width ?? 0), frame=\($0.view?.frame.width ?? 0)"
                        } ?? []
                    FileHandle.standardError.write(Data("Toolbar layout: \(widths)\n".utf8))
                    throw PreviewError.galleryFailed(line: #line)
                }
                if preview {
                    let chips = descendants(gallery).compactMap { $0 as? RatingChip }.filter { !$0.isHidden }
                    guard let chip = chips.first,
                        let caption = descendants(gallery).compactMap({ $0 as? NSTextField })
                            .first(where: { $0.stringValue == "photo1.png" && $0.superview === chip.superview }),
                        abs(chip.frame.midY - caption.frame.midY) < 0.5,
                        abs(chip.bounds.width - chip.intrinsicContentSize.width) < 0.5
                    else { throw PreviewError.galleryRatingPlacementFailed }
                    guard let poster = caption.superview,
                        let metadata = poster.subviews.compactMap({ $0 as? NSTextField })
                            .first(where: { $0 !== caption && !($0 is RatingChip) }),
                        let viewButton = poster.subviews.compactMap({ $0 as? NSButton }).first,
                        abs(metadata.frame.midY - viewButton.frame.midY) < 0.5,
                        metadata.frame.maxX + 16 <= viewButton.frame.minX,
                        max(metadata.frame.maxY, viewButton.frame.maxY) < caption.frame.minY,
                        min(metadata.frame.minY, viewButton.frame.minY) == 0
                    else { throw PreviewError.galleryFailed(line: #line) }
                }
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance)
                    for blur in [false, true] {
                        if viewer.isBlurredBackground != blur { viewer.toggleBlurredBackground() }
                        // Let the thumbnail, Core Image worker, and crossfade finish before capturing pixels.
                        for _ in 0..<5 { settle() }
                        try capture(
                            window,
                            to: output.appendingPathComponent(
                                "d9-\(preview ? "preview" : "rows")-\(Int(width))-\(appearance.rawValue)-\(blur ? "blur" : "plain").png"
                            ))
                    }
                }
            }
        }
        viewer.showPreview()
        guard layouts.selectedIndex == 0 else { throw PreviewError.galleryFailed(line: #line) }
        viewer.showRows()
        guard layouts.selectedIndex == 1 else { throw PreviewError.galleryFailed(line: #line) }
        if viewer.isBlurredBackground { viewer.toggleBlurredBackground() }
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1000, height: 680))
        settle()
        guard collection.selectionIndexPaths == selected else { throw PreviewError.galleryFailed(line: #line) }
    }

    /// Ensures real checkbox actions retain multiple choices, intersect groups, and recover after deselection.
    private static func verifyFilterCheckboxes(popover: NSWindow, viewer: NSWindow) throws {
        let buttons = descendants(popover.contentView!).compactMap { $0 as? NSButton }
        guard let unrated = buttons.first(where: { $0.title == "Unrated / 0 Stars" }),
            let fiveStars = buttons.first(where: { $0.title == "5 Stars" }),
            let jpeg = buttons.first(where: { $0.title == "JPEG" }),
            let png = buttons.first(where: { $0.title == "PNG" }),
            let clear = buttons.first(where: { $0.title == "Clear Filters" }),
            let canvas = descendants(viewer.contentView!).compactMap({ $0 as? ImageCanvas }).first,
            let browse = toolbarControl(viewer, "Browse")
                as? NSButton
        else { throw PreviewError.missingFilterControls }
        for choices in descendants(popover.contentView!).compactMap({ $0 as? ButtonChoices }) {
            let original = choices.selectedIndex
            for button in choices.buttons {
                button.performClick(nil)
                guard choices.selectedIndex == button.tag,
                    button.accessibilityValue() as? NSNumber == NSNumber(value: true),
                    choices.buttons.allSatisfy({ !$0.isVisuallySelected && !$0.isHighlighted })
                else { throw PreviewError.filterDidNotApply }
            }
            choices.buttons[original].performClick(nil)
        }
        let choices = buttons.filter { $0.action == fiveStars.action }
        guard choices.count == 9, choices.allSatisfy({ $0.state == .off }) else {
            throw PreviewError.filterDidNotClear
        }
        guard
            (choices + [clear]).allSatisfy({
                popover.contentView!.bounds.contains($0.convert($0.bounds, to: popover.contentView))
            })
        else { throw PreviewError.missingFilterControls }
        unrated.performClick(nil)
        fiveStars.performClick(nil)
        png.performClick(nil)
        jpeg.performClick(nil)
        guard unrated.state == .on, fiveStars.state == .on, png.state == .on, jpeg.state == .on,
            canvas.image != nil, browse.accessibilityLabel() == "Sort & Filter, 4 active filters",
            browse.toolTip == browse.accessibilityLabel(),
            descendants(viewer.contentView!).compactMap({ $0 as? NSTextField }).contains(where: {
                $0.stringValue == "Filtered by Unrated / 0 Stars, 5 Stars · JPEG, PNG"
            })
        else { throw PreviewError.filterDidNotApply }
        // The synthetic PNG is unrated: either group's exclusion must hide it.
        png.performClick(nil)
        guard canvas.image == nil else { throw PreviewError.filterDidNotApply }
        jpeg.performClick(nil)
        let deadline = Date().addingTimeInterval(15)
        while canvas.image == nil && Date() < deadline { settle() }
        guard canvas.image != nil, browse.accessibilityLabel() == "Sort & Filter, 2 active filters" else {
            throw PreviewError.filterDidNotClear
        }
        clear.performClick(nil)
        guard choices.allSatisfy({ $0.state == .off }), browse.accessibilityLabel() == "Sort & Filter" else {
            throw PreviewError.filterDidNotClear
        }
        unrated.performClick(nil)
        fiveStars.performClick(nil)
        unrated.performClick(nil)
        guard canvas.image == nil, fiveStars.state == .on,
            browse.accessibilityLabel() == "Sort & Filter, 1 active filter",
            (browse as? CapsuleButton)?.badgeCount == 1,
            descendants(canvas).compactMap({ $0 as? NSTextField }).contains(where: {
                $0.stringValue == "Filtered by 5 Stars"
            })
        else { throw PreviewError.filterDidNotApply }
        if viewer.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            guard let background = descendants(viewer.contentView!).compactMap({ $0 as? ViewerBackground }).first,
                let color = background.layer?.backgroundColor,
                let resolved = NSColor(cgColor: color)?.usingColorSpace(.sRGB), resolved.redComponent < 0.2
            else { throw PreviewError.filterDidNotApply }
        }
    }

    /// Ensures the loading card stays compact and legible over retained pixels in both appearances.
    private static func verifyLoadingOverlay(_ window: NSWindow, output: URL) throws {
        guard let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let image = canvas.image
        else { throw PreviewError.imageDidNotLoad }
        let filename = "A very long incoming photo filename with shooting details and a sequence number 123456789.jpg"
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            canvas.showLoading(filename: filename)
            settle()
            root.layoutSubtreeIfNeeded()
            guard canvas.image === image, canvas.isLoading,
                let box = descendants(canvas).compactMap({ $0 as? PanelView }).first,
                !box.isHidden, box.frame.width <= 360, box.frame.height <= 80,
                canvas.bounds.contains(box.frame),
                descendants(box).compactMap({ $0 as? NSTextField }).contains(where: {
                    $0.stringValue == "Loading " + filename
                }),
                descendants(box).contains(where: { $0 is NSProgressIndicator && !$0.isHidden })
            else { throw PreviewError.loadingOverlayFailed(line: #line) }
            try capture(window, to: output.appendingPathComponent("loading-\(appearance.rawValue).png"))
        }
        canvas.image = image
        guard !canvas.isLoading else { throw PreviewError.loadingOverlayFailed(line: #line) }
    }

    /// Ensures real arrow events keep image/metadata selection consistent through reversals and rapid repeats.
    private static func verifyArrowNavigation(_ viewer: ViewerController, output: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = URL(fileURLWithPath: "Tests/LuloImagingTests/Fixtures/DSCF2143-LR-light.jpg")
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        for url in urls { try FileManager.default.copyItem(at: photo, to: url) }
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let metadata = descendants(root).compactMap({ $0 as? NSTextView }).first
        else { throw PreviewError.missingWindow }
        func waitUntil(_ stage: String, _ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard ready() else {
                let diagnostic =
                    "Navigation timeout: \(stage), title=\(window.title), image=\(canvas.image?.width ?? 0)x\(canvas.image?.height ?? 0), metadataCharacters=\(metadata.string.count), labels=\(descendants(root).compactMap { ($0 as? NSTextField)?.stringValue })\n"
                FileHandle.standardError.write(Data(diagnostic.utf8))
                throw PreviewError.navigationFailed
            }
        }
        viewer.open(urls[0])
        try waitUntil("initial photo") { canvas.image != nil && metadata.string.contains("a.jpg") }
        // Only this temporary, harness-owned folder is granted; the real sandbox sheet is tested manually.
        guard folder.standardizedFileURL == urls[0].deletingLastPathComponent().standardizedFileURL else {
            FileHandle.standardError.write(Data("Navigation test grant does not match the opened parent.\n".utf8))
            throw PreviewError.navigationFailed
        }
        let discovered = try ImageLoader.discover(in: folder)
        guard discovered.count == 3, discovered.contains(where: { $0.url == urls[0] }) else {
            throw PreviewError.navigationFailed
        }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil("folder discovery") {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "1 of 3" }
        }
        func arrow(_ direction: Int) throws {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: direction > 0 ? 124 : 123)
            else { throw PreviewError.navigationFailed }
            let retainedImage = canvas.image
            let retainedScale = canvas.zoom.scale
            canvas.keyDown(with: event)
            // Keep the previous pixels while checking the cache; a miss may show the overlay after yielding.
            guard canvas.image === retainedImage, canvas.zoom.scale == retainedScale, canvas.isLoading,
                metadata.string.isEmpty,
                descendants(canvas).compactMap({ $0 as? PanelView }).allSatisfy(\.isHidden)
            else { throw PreviewError.loadingOverlayFailed(line: #line) }
        }
        var index = 0
        for direction in [1, 1, -1, -1] {
            canvas.zoom.scroll(up: true, currentScale: 1)
            try arrow(direction)
            index = (index + direction + urls.count) % urls.count
            try waitUntil("arrow to \(urls[index].lastPathComponent)") {
                canvas.image != nil && !canvas.isLoading && metadata.string.contains(urls[index].lastPathComponent)
            }
            guard canvas.image?.width == 4085, canvas.image?.height == 6128, canvas.zoom.scale == nil else {
                throw PreviewError.navigationFailed
            }
        }
        // An off-center double-click must preserve the image point under the cursor in AppKit coordinates.
        let fitRect = canvas.displayedImageRect
        let imagePoint = CGPoint(x: 0.6, y: 0.65)
        let cursor = CGPoint(
            x: fitRect.minX + fitRect.width * imagePoint.x,
            y: fitRect.minY + fitRect.height * imagePoint.y)
        try doubleClick(canvas, at: cursor)
        let zoomedRect = canvas.displayedImageRect
        guard canvas.zoom.mode == .actualSize, canvas.zoom.scale == 1,
            abs(zoomedRect.minX + zoomedRect.width * imagePoint.x - cursor.x) < 0.01,
            abs(zoomedRect.minY + zoomedRect.height * imagePoint.y - cursor.y) < 0.01
        else { throw PreviewError.displayToggleFailed }
        let dragEnd = CGPoint(x: cursor.x + 20, y: cursor.y - 15)
        for (type, point) in [
            (NSEvent.EventType.leftMouseDown, cursor), (.leftMouseDragged, dragEnd), (.leftMouseUp, dragEnd),
        ] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw PreviewError.displayToggleFailed }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        let actualRect = canvas.displayedImageRect
        guard abs(actualRect.minX - zoomedRect.minX - 20) < 0.01,
            abs(actualRect.minY - zoomedRect.minY + 15) < 0.01
        else { throw PreviewError.displayToggleFailed }
        let center = canvas.zoom.center
        for direction in [1, 1, -1, -1] {
            try arrow(direction)
            index = (index + direction + urls.count) % urls.count
            try waitUntil("zoomed arrow") {
                !canvas.isLoading && metadata.string.contains(urls[index].lastPathComponent)
            }
            guard canvas.zoom.mode == .actualSize, canvas.zoom.scale == 1,
                canvas.zoom.center == center, canvas.displayedImageRect == actualRect
            else { throw PreviewError.displayToggleFailed }
        }
        // Queue rapid selections without waiting for intermediate decodes, including a direction reversal.
        for direction in [1, 1, 1, -1, 1, -1, -1] {
            try arrow(direction)
            index = (index + direction + urls.count) % urls.count
        }
        try waitUntil("arrow to \(urls[index].lastPathComponent)") {
            canvas.image != nil && !canvas.isLoading && metadata.string.contains(urls[index].lastPathComponent)
        }
        guard window.title == urls[index].lastPathComponent, canvas.zoom.scale == 1,
            canvas.zoom.center == center
        else { throw PreviewError.navigationFailed }
        viewer.open(urls[0])
        viewer.open(urls[2])
        try waitUntil("superseded open") { canvas.image != nil && metadata.string.contains("c.jpg") }
        guard window.title == "c.jpg", canvas.zoom.mode == .fit, canvas.zoom.scale == nil,
            canvas.zoom.center == CGPoint(x: 0.5, y: 0.5)
        else { throw PreviewError.navigationFailed }
        try waitUntil("rediscovery after explicit opens") {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "3 of 3" }
        }
        // Invalidating a cached neighbor must clear the retained pixels without losing the viewing mode/region.
        try doubleClick(canvas, at: cursor)
        let errorCenter = canvas.zoom.center
        try Data("corrupt image".utf8).write(to: urls[1])
        try arrow(-1)
        try waitUntil("recoverable error") { !canvas.isLoading && canvas.image == nil }
        try capture(window, to: output.appendingPathComponent("error-dark.png"))
        guard
            descendants(canvas).compactMap({ $0 as? NSTextField }).contains(where: {
                $0.stringValue == "Can’t open this file." && !$0.isHiddenOrHasHiddenAncestor
            })
        else { throw PreviewError.loadingOverlayFailed(line: #line) }
        try arrow(-1)
        try waitUntil("navigation after error") {
            !canvas.isLoading && canvas.image != nil && metadata.string.contains("a.jpg")
        }
        settle()
        guard !canvas.isLoading, canvas.zoom.mode == .actualSize, canvas.zoom.scale == 1,
            canvas.zoom.center == errorCenter
        else { throw PreviewError.loadingOverlayFailed(line: #line) }
        print("Verified arrow wrapping/reversal, rapid selections, and superseded explicit opens with the real photo.")
    }

    /// Ensures cached next/previous images replace the canvas without ever presenting a loading overlay.
    private static func verifyCachedNavigation(fixture: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["a.png", "b.png"].map { folder.appendingPathComponent($0) }
        for url in urls { try FileManager.default.copyItem(at: fixture, to: url) }
        let store = ImageStore()
        let viewer = ViewerController(imageStore: store, automaticallyRefresh: false)
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let overlay = descendants(canvas).compactMap({ $0 as? PanelView }).first
        else { throw PreviewError.navigationFailed }
        defer { window.close() }
        func waitWithoutOverlay(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                guard overlay.isHidden else { throw PreviewError.loadingOverlayFailed(line: #line) }
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard ready(), overlay.isHidden else { throw PreviewError.loadingOverlayFailed(line: #line) }
        }
        var warmed: Result<Void, Error>?
        let warmup = Task {
            do {
                // The first explicit open starts generation 1; prewarm that same viewer session.
                for url in urls { _ = try await store.load(at: url, generation: 1, access: FileAccess(url: folder)) }
                warmed = .success(())
            } catch { warmed = .failure(error) }
        }
        defer { warmup.cancel() }
        try waitWithoutOverlay { warmed != nil }
        try warmed?.get()
        viewer.open(urls[0])
        try waitWithoutOverlay { !canvas.isLoading && canvas.image != nil && window.attachedSheet == nil }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitWithoutOverlay {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "1 of 2" }
        }
        for forward in [true, false, true, false] {
            let previous = canvas.image
            // A cached selection must also dismiss loading feedback left by the previous selection.
            canvas.showLoading(filename: "previous-request.png")
            if forward { viewer.nextImage() } else { viewer.previousImage() }
            guard canvas.isLoading, overlay.isHidden, canvas.image === previous else {
                throw PreviewError.loadingOverlayFailed(line: #line)
            }
            try waitWithoutOverlay { !canvas.isLoading }
            guard canvas.image != nil, canvas.image !== previous,
                window.title == (forward ? "b.png" : "a.png")
            else { throw PreviewError.navigationFailed }
        }
        // Drain any queued notifications: completion must not be followed by a stale loading overlay.
        settle()
        guard !canvas.isLoading, overlay.isHidden else { throw PreviewError.loadingOverlayFailed(line: #line) }
        print("Verified cached next/previous navigation skips the loading overlay.")
    }

    /// Ensures a new explicit open cancels an active scan, retains its grant until exit, and rejects its results.
    private static func verifyObsoleteFolderScan(fixture: URL) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let oldFolder = root.appendingPathComponent("old", isDirectory: true)
        let newFolder = root.appendingPathComponent("new", isDirectory: true)
        for folder in [oldFolder, newFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<8 {
            try FileManager.default.copyItem(at: fixture, to: oldFolder.appendingPathComponent("image\(index).png"))
        }
        let newImage = newFolder.appendingPathComponent("new.png")
        try FileManager.default.copyItem(at: fixture, to: newImage)
        let gate = ScanCheckpointGate()
        let viewer = ViewerController { folder, isCancelled in
            defer { gate.finish() }
            return try ImageLoader.discover(
                in: folder,
                isCancelled: {
                    gate.checkpoint()
                    return isCancelled()
                })
        }
        defer {
            gate.release()
            viewer.window?.close()
        }
        guard let window = viewer.window, let content = window.contentView,
            let canvas = descendants(content).compactMap({ $0 as? ImageCanvas }).first
        else { throw PreviewError.missingWindow }
        func waitUntil(_ stage: String, _ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard ready() else {
                FileHandle.standardError.write(Data("Scan cancellation timeout: \(stage), state=\(gate.state)\n".utf8))
                throw PreviewError.navigationFailed
            }
        }
        viewer.open(oldFolder.appendingPathComponent("image0.png"))
        try waitUntil("initial image") { canvas.image != nil && !canvas.isLoading }
        weak var retainedGrant: FileAccess?
        // AppKit drains autoreleased Objective-C blocks/operation arrays after each real event.
        // Match that lifetime here instead of retaining them in the command-line harness's outer pool.
        autoreleasepool {
            let grant = FileAccess(url: oldFolder)
            retainedGrant = grant
            viewer.useAuthorizedFolder(grant)
        }
        // The third checkpoint follows the first metadata read. No sleeps or disk-speed assumptions.
        try waitUntil("scan checkpoint") { gate.state.paused }
        autoreleasepool { viewer.open(newImage) }
        try waitUntil("new image while scan is blocked") {
            canvas.image != nil && !canvas.isLoading && window.title == "new.png"
        }
        guard retainedGrant != nil else { throw PreviewError.navigationFailed }
        gate.release()
        try waitUntil("scan exit and grant release") { gate.state.finished && retainedGrant == nil }
        guard gate.state.checks == 3, !gate.state.timedOut, window.title == "new.png",
            descendants(content).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == "1 of 1" })
        else { throw PreviewError.navigationFailed }
        print(
            "Verified an active scan stops after one metadata read, preserves the new session, and releases its grant.")
    }

    /// Ensures the Refresh glyph advances while a manual scan is blocked, stays still for automatic work,
    /// and returns to its idle frame after the scan/load finish, without retaining selected styling.
    private static func verifyRefreshAnimation(fixture: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = folder.appendingPathComponent("image.png")
        try FileManager.default.copyItem(at: fixture, to: imageURL)
        let gate = ScanCheckpointGate()
        let viewer = ViewerController(
            discoverImages: { folder, isCancelled in
                try ImageLoader.discover(
                    in: folder,
                    isCancelled: {
                        gate.checkpoint()
                        return isCancelled()
                    })
            }, automaticallyRefresh: false)
        defer {
            gate.release()
            viewer.window?.close()
        }
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let refresh = toolbarControl(window, "Refresh") as? CapsuleButton,
            let idle = refresh.glyph
        else { throw PreviewError.refreshFailed(line: #line) }
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.refreshFailed(line: #line) }
        }
        viewer.open(imageURL)
        try waitUntil { canvas.image != nil && !canvas.isLoading && window.attachedSheet == nil }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil { gate.state.paused }
        settle()
        guard refresh.glyph === idle else { throw PreviewError.refreshFailed(line: #line) }
        refresh.performClick(nil)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settle()
            guard refresh.glyph === idle else { throw PreviewError.refreshFailed(line: #line) }
        } else {
            try waitUntil { refresh.glyph !== idle }
            guard refresh.glyph?.tiffRepresentation != idle.tiffRepresentation else {
                throw PreviewError.refreshFailed(line: #line)
            }
        }
        guard !refresh.isVisuallySelected, !refresh.isHighlighted else {
            throw PreviewError.refreshFailed(line: #line)
        }
        gate.release()
        try waitUntil { !canvas.isLoading && refresh.glyph === idle }
        settle()
        guard refresh.glyph === idle, !gate.state.timedOut else { throw PreviewError.refreshFailed(line: #line) }
        print("Verified manual Refresh glyph animation, idle automatic scans, and animation cleanup.")
    }

    /// Ensures Refresh updates pixels, ratings, and folder membership while keeping the current view and selection.
    private static func verifyRefreshAndRatings(output: URL) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.png")
        let second = folder.appendingPathComponent("b.png")
        let third = folder.appendingPathComponent("c.png")
        try makeFixture(at: first, rating: 1)
        try makeFixture(at: second, rating: 2)
        let viewer = ViewerController(automaticallyRefresh: false)
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let gallery = descendants(root).compactMap({ $0 as? GalleryView }).first,
            let collection = descendants(gallery).compactMap({ $0 as? NSCollectionView }).first,
            let refresh = toolbarControl(window, "Refresh")
                as? NSButton
        else { throw PreviewError.refreshFailed(line: #line) }
        defer { window.close() }
        func waitUntil(line: Int = #line, _ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.refreshFailed(line: line) }
        }
        func hasStatus(_ text: String) -> Bool {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == text }
        }
        viewer.open(first)
        try waitUntil { canvas.image != nil && !canvas.isLoading && window.attachedSheet == nil }
        guard refresh.isEnabled, hasStatus("1 of 1"),
            let rating = descendants(root).compactMap({ $0 as? NSTextField }).first(where: {
                $0.identifier?.rawValue == "StatusRating" && $0.stringValue == "★ 1"
            })
        else {
            let labels = descendants(root).compactMap { ($0 as? NSTextField)?.stringValue }
            FileHandle.standardError.write(
                Data(
                    "Refresh setup: enabled=\(refresh.isEnabled), canRefresh=\(viewer.canRefresh), labels=\(labels)\n"
                        .utf8))
            throw PreviewError.refreshFailed(line: #line)
        }
        viewer.toggleSidebar()
        for stars in [2, 3, 4, 5, 0, nil, 1] as [Int?] {
            try makeFixture(at: first, rating: stars)
            let previous = canvas.image
            refresh.performClick(nil)
            guard rating.isHidden else { throw PreviewError.refreshFailed(line: #line) }
            try waitUntil { canvas.image != nil && canvas.image !== previous && !canvas.isLoading }
            let count = stars ?? 0
            guard rating.stringValue == (count == 0 ? "" : "★ \(count)"), rating.isHidden == (count == 0),
                hasStatus("1 of 1"), window.title == "a.png"
            else { throw PreviewError.refreshFailed(line: #line) }
            if count > 0 {
                guard rating.accessibilityLabel() == "\(count) \(count == 1 ? "star" : "stars")" else {
                    throw PreviewError.refreshFailed(line: #line)
                }
            }
        }
        // A filtered-out single file must reappear when its refreshed rating now matches.
        guard
            let browse = toolbarControl(window, "Browse")
                as? NSButton
        else { throw PreviewError.refreshFailed(line: #line) }
        browse.performClick(nil)
        settle()
        guard
            let popover = NSApp.windows.first(where: {
                guard $0 !== window, $0.isVisible, let content = $0.contentView else { return false }
                return descendants(content).compactMap { $0 as? NSButton }.contains { $0.title == "5 Stars" }
            }),
            let fiveStars = descendants(popover.contentView!).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "5 Stars" }),
            let clearFilters = descendants(popover.contentView!).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "Clear Filters" })
        else { throw PreviewError.refreshFailed(line: #line) }
        fiveStars.performClick(nil)
        guard canvas.image == nil, rating.isHidden else { throw PreviewError.refreshFailed(line: #line) }
        try makeFixture(at: first, rating: 5)
        viewer.refreshImages()
        try waitUntil { canvas.image != nil && !canvas.isLoading }
        guard fiveStars.state == .on, rating.stringValue == "★ 5" else {
            throw PreviewError.refreshFailed(line: #line)
        }
        clearFilters.performClick(nil)
        browse.performClick(nil)
        try makeFixture(at: first, rating: 1)
        viewer.refreshImages()
        try waitUntil { !canvas.isLoading && rating.stringValue == "★ 1" }
        // Refresh must bypass the cache even when no file attributes changed.
        let previous = canvas.image
        refresh.performClick(nil)
        try waitUntil { canvas.image !== previous && !canvas.isLoading }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            window.setContentSize(NSSize(width: 720, height: 480))
            settle()
            try capture(window, to: output.appendingPathComponent("viewer-rating-\(appearance.rawValue).png"))
        }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil { hasStatus("1 of 2") }
        viewer.toggleGallery()
        try waitUntil {
            collection.visibleItems().count == 2 && collection.visibleItems().allSatisfy { $0.imageView?.image != nil }
        }
        guard rating.isHidden, refresh.isEnabled else { throw PreviewError.refreshFailed(line: #line) }
        let originalThumbnail = collection.item(at: IndexPath(item: 0, section: 0))?.imageView?.image
        // ImageEntry has no dimensions; this replacement must reload even when the entry array compares equal.
        try makeFixture(at: first, rating: 1, orientation: 6)
        refresh.performClick(nil)
        try waitUntil {
            guard let image = collection.item(at: IndexPath(item: 0, section: 0))?.imageView?.image else {
                return false
            }
            return image !== originalThumbnail && image.size.height > image.size.width
        }
        try makeFixture(at: third, rating: 5)
        try FileManager.default.removeItem(at: second)
        refresh.performClick(nil)
        try waitUntil { collection.visibleItems().contains { $0.textField?.stringValue == "c.png" } }
        guard collection.numberOfItems(inSection: 0) == 2,
            collection.selectionIndexPaths == [IndexPath(item: 0, section: 0)], !gallery.isHidden
        else { throw PreviewError.refreshFailed(line: #line) }
        // The directly opened file must disappear too, rather than being appended back into discovery.
        try FileManager.default.removeItem(at: first)
        refresh.performClick(nil)
        try waitUntil { collection.numberOfItems(inSection: 0) == 1 }
        viewer.toggleGallery()
        try waitUntil { !canvas.isLoading && canvas.image != nil && window.title == "c.png" }
        guard rating.stringValue == "★ 5", !rating.isHidden else { throw PreviewError.refreshFailed(line: #line) }
        try Data("corrupt".utf8).write(to: third)
        refresh.performClick(nil)
        try waitUntil { !canvas.isLoading && canvas.image == nil }
        guard rating.isHidden else { throw PreviewError.refreshFailed(line: #line) }
        try FileManager.default.removeItem(at: third)
        refresh.performClick(nil)
        try waitUntil { hasStatus("0 images") && hasStatus("No images remaining") }
        print("Verified manual refresh, folder additions/deletions, thumbnail replacement, and viewer ratings.")
    }

    /// Ensures actual filesystem changes refresh single-file and folder sessions without a button click.
    private static func verifyAutomaticRefresh() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("a.png")
        let second = folder.appendingPathComponent("b.png")
        try makeFixture(at: first, rating: 1)
        let viewer = ViewerController()
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let gallery = descendants(root).compactMap({ $0 as? GalleryView }).first,
            let collection = descendants(gallery).compactMap({ $0 as? NSCollectionView }).first
        else { throw PreviewError.refreshFailed(line: #line) }
        defer { window.close() }
        func waitUntil(line: Int = #line, _ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.refreshFailed(line: line) }
        }
        func hasLabel(_ text: String) -> Bool {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == text }
        }
        viewer.open(first)
        try waitUntil { canvas.image != nil && !canvas.isLoading && window.attachedSheet == nil }
        // Give the single-file monitor its initial snapshot before replacing the file.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        try makeFixture(at: second, rating: 2)
        try makeFixture(at: first, rating: 5, orientation: 6)
        try waitUntil { hasLabel("★ 5") && canvas.image?.height == 1200 && !canvas.isLoading }
        guard hasLabel("1 of 1") else { throw PreviewError.refreshFailed(line: #line) }
        try FileManager.default.removeItem(at: first)
        try waitUntil { !canvas.isLoading && canvas.image == nil }
        try makeFixture(at: first, rating: 3)
        try waitUntil { canvas.image != nil && !canvas.isLoading && hasLabel("★ 3") }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil { hasLabel("1 of 2") }
        viewer.toggleGallery()
        let third = folder.appendingPathComponent("c.png")
        try makeFixture(at: third, rating: 4)
        try FileManager.default.removeItem(at: second)
        try waitUntil {
            collection.visibleItems().contains { $0.textField?.stringValue == "c.png" && $0.imageView?.image != nil }
        }
        guard collection.numberOfItems(inSection: 0) == 2 else { throw PreviewError.refreshFailed(line: #line) }
        try FileManager.default.removeItem(at: first)
        try waitUntil { collection.numberOfItems(inSection: 0) == 1 }
        viewer.toggleGallery()
        try waitUntil { window.title == "c.png" && !canvas.isLoading && canvas.image != nil && hasLabel("★ 4") }
        // A new session must stop observing the previous folder and reject already queued callbacks.
        let otherFolder = folder.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let other = otherFolder.appendingPathComponent("new.png")
        try makeFixture(at: other)
        viewer.open(other)
        try waitUntil { window.title == "new.png" && !canvas.isLoading && window.attachedSheet == nil }
        try FileManager.default.removeItem(at: third)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        guard window.title == "new.png", canvas.image != nil, hasLabel("1 of 1") else {
            throw PreviewError.refreshFailed(line: #line)
        }
        print("Verified automatic replacement, deletion/recreation, folder discovery, and session isolation.")
    }

    private static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }

    private static func toolbarControl(_ window: NSWindow?, _ name: String) -> NSView? {
        window?.toolbar?.items.compactMap(\.view).flatMap(descendants).first { $0.identifier?.rawValue == name }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func capture(_ window: NSWindow, to url: URL, activate: Bool = true) throws {
        if activate && window.canBecomeKey {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            settle()
        }
        guard let view = window.contentView?.superview else { throw PreviewError.missingWindow }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewError.captureFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.captureFailed }
        try data.write(to: url)
        // Verify the rendered window contains a usable image area even with the inspector visible.
        if let canvas = descendants(view).compactMap({ $0 as? ImageCanvas }).first, !canvas.isHiddenOrHasHiddenAncestor
        {
            guard canvas.frame.width >= 300, canvas.frame.height >= 250 else { throw PreviewError.clippedCanvas }
        }
    }

    private static func makeFixture(at url: URL, rating: Int? = nil, orientation: Int = 1, aperture: Double = 2.8)
        throws
    {
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
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [
                "DateTimeOriginal": "2026:01:02 03:04:05", "FNumber": aperture, "FocalLength": 35,
            ],
            kCGImagePropertyTIFFDictionary: ["Make": "Synthetic Camera", "Model": "Preview Fixture", "Artist": "Lulo"],
        ]
        if let rating {
            let metadata = CGImageMetadataCreateMutable()
            guard CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(rating) as CFString)
            else { throw PreviewError.captureFailed }
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.captureFailed }
    }

    private enum PreviewError: Error {
        case displayToggleFailed
        case smallImageFailed(mode: String, scale: Int, rect: CGRect)
        case missingWindow, imageDidNotLoad, captureFailed, clippedCanvas, missingPopover
        case galleryFailed(line: Int)
        case galleryMouseFailed(layout: String, point: CGPoint, line: Int)
        case galleryRatingPlacementFailed
        case trashFailed
        case refreshFailed(line: Int)
        case missingFilterControls, filterDidNotApply, filterDidNotClear, navigationFailed
        case loadingOverlayFailed(line: Int)
    }
}

// NSCondition protects every state access shared by the UI harness and the discovery worker.
private final class ScanCheckpointGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var checks = 0
    private var paused = false
    private var released = false
    private var finished = false
    private var timedOut = false

    var state: (checks: Int, paused: Bool, finished: Bool, timedOut: Bool) {
        condition.lock()
        defer { condition.unlock() }
        return (checks, paused, finished, timedOut)
    }

    func checkpoint() {
        condition.lock()
        defer { condition.unlock() }
        checks += 1
        guard checks == 3 else { return }
        paused = true
        let deadline = Date().addingTimeInterval(15)
        while !released {
            if !condition.wait(until: deadline) {
                timedOut = true
                break
            }
        }
    }

    func release() {
        condition.lock()
        defer { condition.unlock() }
        released = true
        condition.broadcast()
    }

    func finish() {
        condition.lock()
        defer { condition.unlock() }
        finished = true
    }
}

/// Holds an operation at its asynchronous boundary; only owned synthetic files are moved within the test directory.
@MainActor
private final class TrashPreviewOperation {
    private let destination: URL
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var pendingURL: URL?

    init(destination: URL) { self.destination = destination }

    func move(_ url: URL, access: FileAccess) async throws {
        defer { withExtendedLifetime(access) {} }
        try await withCheckedThrowingContinuation { continuation in
            self.pendingURL = url
            self.continuation = continuation
        }
    }

    func fail() {
        pendingURL = nil
        continuation?.resume(throwing: CocoaError(.fileWriteNoPermission))
        continuation = nil
    }

    func succeed() throws {
        guard let url = pendingURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.moveItem(at: url, to: destination.appendingPathComponent(url.lastPathComponent))
        pendingURL = nil
        continuation?.resume()
        continuation = nil
    }
}
