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
        let viewer = ViewerController(automaticallyRefresh: false)
        viewer.showWindow(nil)
        guard let window = viewer.window else { throw PreviewError.missingWindow(line: #line) }
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
            throw PreviewError.imageDidNotLoad(line: #line)
        }
        settle()
        try verifyDisplayToggle(viewer)
        try verifyBreadcrumb(window, visible: [fixture.lastPathComponent])
        try capture(window, to: output.appendingPathComponent("image-light.png"))
        viewer.toggleSidebar()
        settle()
        try capture(window, to: output.appendingPathComponent("metadata-light.png"))
        try verifyBlurredBackground(viewer, output: output, name: "metadata")
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 720, height: 480))
        settle()
        try capture(window, to: output.appendingPathComponent("metadata-compact-dark.png"))
        try verifyToolbarFits(window)
        try verifyLoadingOverlay(window, output: output)
        if let browse = toolbarButton(window, "Sort & Filter") {
            browse.performClick(nil)
            settle()
            if let popover = app.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil }) {
                try capture(popover, to: output.appendingPathComponent("browse-dark.png"))
                try verifyFilterCheckboxes(popover: popover, viewer: window)
                browse.performClick(nil)
                settle()
                guard let canvas = descendants(window.contentView!).compactMap({ $0 as? ImageCanvas }).first,
                    canvas.image == nil,
                    let clear = descendants(canvas).compactMap({ $0 as? NSButton })
                        .first(where: { $0.title == "Clear Filters" && !$0.isHidden })
                else {
                    throw PreviewError.filterDidNotApply(line: #line)
                }
                try capture(window, to: output.appendingPathComponent("filtered-empty-dark.png"))
                clear.performClick(nil)
                let restoredDeadline = Date().addingTimeInterval(15)
                while canvas.image == nil && Date() < restoredDeadline { settle() }
                guard canvas.image != nil else { throw PreviewError.filterDidNotClear(line: #line) }
            } else {
                throw PreviewError.missingPopover(line: #line)
            }
        } else {
            throw PreviewError.missingFilterControls(line: #line)
        }
        try verifyArrowNavigation(viewer)
        try verifyCachedNavigation(fixture: fixture)
        try verifyObsoleteFolderScan(fixture: fixture)
        try verifyGallery(fixture: fixture, output: output)
        try verifyRefreshAndRatings(output: output)
        try verifyAutomaticRefresh()
        try verifyTrashAction(fixture: fixture, output: output)
        print("Rendered native viewer previews and verified real-photo arrow navigation.")
        window.close()
    }

    /// Ensures the toolbar selects the current mode, double-click stays in sync, and new viewers always start in fit.
    private static func verifyDisplayToggle(_ viewer: ViewerController) throws {
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let fit = toolbarButton(window, "Fit to window"), let actual = toolbarButton(window, "100%")
        else { throw PreviewError.displayToggleFailed(line: #line) }
        guard fit.state == .on, actual.state == .off, canvas.zoom.mode == .fit, canvas.zoom.scale == nil,
            fit.accessibilityRole() == .radioButton, zoomText(root)?.hasPrefix("Fit, ") == true
        else {
            let state =
                "fit=\(fit.state.rawValue) actual=\(actual.state.rawValue) mode=\(canvas.zoom.mode) "
                + "scale=\(String(describing: canvas.zoom.scale)) role=\(String(describing: fit.accessibilityRole())) "
                + "zoom=\(String(describing: zoomText(root)))\n"
            FileHandle.standardError.write(Data(state.utf8))
            throw PreviewError.displayToggleFailed(line: #line)
        }
        for (button, expected) in [(actual, ViewingMode.actualSize), (actual, .actualSize), (fit, .fit), (fit, .fit)] {
            canvas.zoom.scroll(up: true, currentScale: 2)
            button.performClick(nil)
            guard canvas.zoom.mode == expected,
                canvas.zoom.scale == (expected == .fit ? nil : 1), button.state == .on,
                (button === fit ? actual : fit).state == .off,
                zoomText(root) == (expected == .fit ? canvas.zoomDescription : "100%")
            else { throw PreviewError.displayToggleFailed(line: #line) }
            let cursor = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
            try doubleClick(canvas, at: cursor)
            guard (button === fit ? actual : fit).state == .on, button.state == .off,
                canvas.zoom.scale == (expected == .fit ? 1 : nil)
            else { throw PreviewError.displayToggleFailed(line: #line) }
            try doubleClick(canvas, at: cursor)
            guard button.state == .on else { throw PreviewError.displayToggleFailed(line: #line) }
            let restored = ViewerController()
            defer { restored.window?.close() }
            guard let restoredWindow = restored.window, toolbarButton(restoredWindow, "Fit to window")?.state == .on
            else { throw PreviewError.displayToggleFailed(line: #line) }
        }
        canvas.resetZoom(to: .actualSize)
        window.close()
        viewer.showWindow(nil)
        guard canvas.zoom.mode == .fit, canvas.zoom.scale == nil, fit.state == .on else {
            throw PreviewError.displayToggleFailed(line: #line)
        }
    }

    private static func doubleClick(_ canvas: ImageCanvas, at point: CGPoint) throws {
        guard let window = canvas.window,
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1)
        else { throw PreviewError.displayToggleFailed(line: #line) }
        canvas.mouseDown(with: event)
    }

    /// Ensures the grid preserves ratings, previews, selection, and multi-select filters while disabling Trash.
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
            let fit = toolbarButton(window, "Fit to window"), let trash = toolbarButton(window, "Move to Trash"),
            let poster = descendants(gallery).compactMap({ $0 as? PosterView }).first
        else { throw PreviewError.galleryFailed(line: #line) }
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 680))
        window.appearance = NSAppearance(named: .aqua)
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.galleryFailed(line: #line) }
        }
        func key(_ code: UInt16) throws {
            let characters = [123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}"][code] ?? "\r"
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
        try waitUntil {
            collection.numberOfItems(inSection: 0) == 81
                && collection.visibleItems().contains { $0.imageView?.image != nil }
        }
        guard !gallery.isHidden, canvas.isHidden, collection.visibleItems().count < 81,
            collection.selectionIndexPaths == [IndexPath(item: 1, section: 0)],
            !viewer.canTrashCurrentImage, !trash.isEnabled, fit.isHiddenOrHasHiddenAncestor,
            canvas.zoom.mode == .fit, canvas.zoom.scale == nil, viewer.galleryLayout == .rows
        else { throw PreviewError.galleryFailed(line: #line) }
        try verifyBreadcrumb(
            window, visible: [folder.deletingLastPathComponent().lastPathComponent, folder.lastPathComponent])
        viewer.trashCurrentImage()
        guard window.attachedSheet == nil else { throw PreviewError.galleryFailed(line: #line) }
        try waitUntil {
            descendants(gallery).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == "Preview unavailable" && !$0.isHiddenOrHasHiddenAncestor
            }
        }
        try waitUntil { thumbnailsReady() }
        // Rows tiles take each image's own aspect ratio from discovery, including the rotated portrait fixture.
        for index in 1...6 {
            guard let image = collection.item(at: IndexPath(item: index, section: 0))?.imageView?.image else {
                throw PreviewError.galleryRatingPlacementFailed(line: #line)
            }
            let frame = itemFrame(collection, index)
            guard abs(frame.width / frame.height - image.size.width / image.size.height) < 0.02,
                index != 2 || frame.height > frame.width
            else { throw PreviewError.galleryRatingPlacementFailed(line: #line) }
        }
        settle()
        try capture(window, to: output.appendingPathComponent("gallery-light.png"))
        try key(124)
        guard collection.selectionIndexPaths == [IndexPath(item: 2, section: 0)] else {
            throw PreviewError.galleryFailed(line: #line)
        }
        // Down and up move between visual rows to the nearest horizontal centre.
        let start = itemFrame(collection, 2)
        try key(125)
        guard let below = collection.selectionIndexPaths.first?.item, itemFrame(collection, below).minY > start.maxY
        else { throw PreviewError.galleryFailed(line: #line) }
        try key(126)
        guard let above = collection.selectionIndexPaths.first?.item,
            itemFrame(collection, above).minY == start.minY
        else { throw PreviewError.galleryFailed(line: #line) }
        let second = IndexPath(item: 2, section: 0)
        collection.selectItems(at: [second], scrollPosition: [])
        collection.delegate?.collectionView?(collection, didSelectItemsAt: [second])
        guard collection.selectionIndexPaths == [second] else { throw PreviewError.galleryFailed(line: #line) }
        try verifyThumbnailSizes(viewer, collection: collection)
        try verifyPreviewLayout(viewer, collection: collection, poster: poster, output: output)
        try key(36)
        try waitUntil { gallery.isHidden && viewer.canTrashCurrentImage && window.title == "photo2.png" }
        guard !fit.isHiddenOrHasHiddenAncestor, fit.state == .on, canvas.zoom.mode == .fit, canvas.zoom.scale == nil
        else { throw PreviewError.displayToggleFailed(line: #line) }
        try verifyBreadcrumb(
            window,
            visible: [folder.deletingLastPathComponent().lastPathComponent, folder.lastPathComponent, "photo2.png"])
        // The folder segment is a link with the same effect as the Gallery button.
        guard
            let folderLink = descendants(window.toolbar!.items.compactMap(\.view)).compactMap({ $0 as? NSButton })
                .first(where: { $0.title == folder.lastPathComponent && !$0.isHidden })
        else { throw PreviewError.galleryFailed(line: #line) }
        folderLink.performClick(nil)
        guard !gallery.isHidden, collection.selectionIndexPaths == [IndexPath(item: 2, section: 0)] else {
            throw PreviewError.galleryFailed(line: #line)
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 720, height: 480))
        settle()
        try waitUntil { thumbnailsReady() }
        try verifyToolbarFits(window)
        // Below 1000 points the breadcrumb drops the parent folder.
        try verifyBreadcrumb(window, visible: [folder.lastPathComponent])
        try capture(window, to: output.appendingPathComponent("gallery-compact-dark.png"))
        viewer.showPreview()
        settle()
        try waitUntil { thumbnailsReady() && poster.preview.image != nil }
        try verifyToolbarFits(window)
        try capture(window, to: output.appendingPathComponent("gallery-preview-compact-dark.png"))
        try verifyBlurredBackground(viewer, output: output, name: "gallery-preview")
        viewer.showRows()
        for index in [80, 1, 70, 2] {
            collection.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .centeredVertically)
            settle()
            try waitUntil { thumbnailsReady() }
        }
        // The existing filter controls must affect both views, including recovery from no matches.
        guard let browse = toolbarButton(window, "Sort & Filter") else { throw PreviewError.galleryFailed(line: #line) }
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
        guard badgeCount(browse) == 3, browse.accessibilityLabel() == "Sort & Filter, 3 active filters" else {
            throw PreviewError.galleryFailed(line: #line)
        }
        try capture(window, to: output.appendingPathComponent("gallery-filtered-compact-dark.png"))
        browse.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 0,
            let clear = descendants(gallery).compactMap({ $0 as? NSButton }).first(where: {
                $0.title == "Clear Filters" && !$0.isHiddenOrHasHiddenAncestor
            })
        else { throw PreviewError.galleryFailed(line: #line) }
        try capture(window, to: output.appendingPathComponent("gallery-no-match-compact-dark.png"))
        clear.performClick(nil)
        guard badgeCount(browse) == 0 else { throw PreviewError.galleryFailed(line: #line) }
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
            let trash = toolbarButton(window, "Move to Trash")
        else { throw PreviewError.trashFailed(line: #line) }
        defer { window.close() }
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.trashFailed(line: #line) }
        }
        func clickSheetButton(_ title: String) throws {
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == title })
            else { throw PreviewError.trashFailed(line: #line) }
            button.performClick(nil)
            settle()
        }
        func confirmTrash() throws {
            viewer.trashCurrentImage()
            try clickSheetButton("Move to Trash")
            try waitUntil { operation.pendingURL != nil }
            guard !viewer.canTrashCurrentImage else { throw PreviewError.trashFailed(line: #line) }
        }
        guard !viewer.canTrashCurrentImage, !trash.isEnabled else { throw PreviewError.trashFailed(line: #line) }
        viewer.open(first)
        guard !viewer.canTrashCurrentImage else { throw PreviewError.trashFailed(line: #line) }
        try waitUntil { viewer.canTrashCurrentImage }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil {
            descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "1 of 2" }
        }
        trash.performClick(nil)
        settle()
        guard let sheet = window.attachedSheet else { throw PreviewError.trashFailed(line: #line) }
        try capture(sheet, to: output.appendingPathComponent("trash-confirmation.png"))
        try clickSheetButton("Cancel")
        guard operation.pendingURL == nil, viewer.canTrashCurrentImage,
            FileManager.default.fileExists(atPath: first.path)
        else { throw PreviewError.trashFailed(line: #line) }

        try confirmTrash()
        operation.fail()
        try waitUntil { window.attachedSheet != nil }
        try clickSheetButton("OK")
        guard window.title == "a.png", canvas.image != nil, FileManager.default.fileExists(atPath: first.path) else {
            throw PreviewError.trashFailed(line: #line)
        }
        try confirmTrash()
        try operation.succeed()
        try waitUntil { window.title == "b.png" && viewer.canTrashCurrentImage }
        guard !FileManager.default.fileExists(atPath: first.path), FileManager.default.fileExists(atPath: second.path)
        else { throw PreviewError.trashFailed(line: #line) }

        try confirmTrash()
        viewer.open(replacement)
        try waitUntil { !canvas.isLoading && window.attachedSheet == nil }
        guard operation.pendingURL == second, window.title == "new.png" else {
            throw PreviewError.trashFailed(line: #line)
        }
        try operation.succeed()
        try waitUntil { viewer.canTrashCurrentImage }
        guard window.title == "new.png", FileManager.default.fileExists(atPath: replacement.path) else {
            throw PreviewError.trashFailed(line: #line)
        }
        try confirmTrash()
        try operation.succeed()
        try waitUntil {
            descendants(content).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "No images remaining." }
        }
        guard !viewer.canTrashCurrentImage, !trash.isEnabled, canvas.image == nil else {
            throw PreviewError.trashFailed(line: #line)
        }
        print("Verified Trash confirmation, cancellation, failure, next selection, last image, and stale completion.")
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
            let browse = toolbarButton(viewer, "Sort & Filter")
        else { throw PreviewError.missingFilterControls(line: #line) }
        let choices = buttons.filter { $0.action == fiveStars.action }
        guard choices.count == 9, choices.allSatisfy({ $0.state == .off }) else {
            throw PreviewError.filterDidNotClear(line: #line)
        }
        guard
            (choices + [clear]).allSatisfy({
                popover.contentView!.bounds.contains($0.convert($0.bounds, to: popover.contentView))
            })
        else { throw PreviewError.missingFilterControls(line: #line) }
        unrated.performClick(nil)
        fiveStars.performClick(nil)
        png.performClick(nil)
        jpeg.performClick(nil)
        guard unrated.state == .on, fiveStars.state == .on, png.state == .on, jpeg.state == .on,
            canvas.image != nil, browse.accessibilityLabel() == "Sort & Filter, 4 active filters",
            browse.toolTip == browse.accessibilityLabel(), badgeCount(browse) == 4,
            descendants(viewer.contentView!).compactMap({ $0 as? NSTextField }).contains(where: {
                $0.stringValue == "Filtered by Unrated / 0 Stars, 5 Stars · JPEG, PNG"
            })
        else { throw PreviewError.filterDidNotApply(line: #line) }
        // The synthetic PNG is unrated: either group's exclusion must hide it.
        png.performClick(nil)
        guard canvas.image == nil else { throw PreviewError.filterDidNotApply(line: #line) }
        jpeg.performClick(nil)
        let deadline = Date().addingTimeInterval(15)
        while canvas.image == nil && Date() < deadline { settle() }
        // The count is ticked boxes, not filter groups: two ratings remain ticked.
        guard canvas.image != nil, browse.accessibilityLabel() == "Sort & Filter, 2 active filters",
            badgeCount(browse) == 2
        else {
            throw PreviewError.filterDidNotClear(line: #line)
        }
        clear.performClick(nil)
        guard choices.allSatisfy({ $0.state == .off }), browse.accessibilityLabel() == "Sort & Filter",
            badgeCount(browse) == 0
        else {
            throw PreviewError.filterDidNotClear(line: #line)
        }
        unrated.performClick(nil)
        fiveStars.performClick(nil)
        unrated.performClick(nil)
        guard canvas.image == nil, fiveStars.state == .on,
            browse.accessibilityLabel() == "Sort & Filter, 1 active filter",
            badgeCount(browse) == 1
        else { throw PreviewError.filterDidNotApply(line: #line) }
    }

    /// Ensures the loading card stays compact and legible over retained pixels in both appearances.
    private static func verifyLoadingOverlay(_ window: NSWindow, output: URL) throws {
        guard let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let image = canvas.image
        else { throw PreviewError.imageDidNotLoad(line: #line) }
        let filename = "A very long incoming photo filename with shooting details and a sequence number 123456789.jpg"
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            canvas.showLoading(filename: filename)
            settle()
            root.layoutSubtreeIfNeeded()
            let box = canvas.loadingBox
            guard canvas.image === image, canvas.isLoading,
                !box.isHidden, box.frame.width <= 320, box.frame.height <= 80,
                canvas.bounds.contains(box.frame),
                descendants(box).compactMap({ $0 as? NSTextField }).contains(where: {
                    $0.stringValue == "Loading \(filename)" && $0.toolTip == filename
                }),
                descendants(box).contains(where: { $0 is NSProgressIndicator && !$0.isHidden })
            else { throw PreviewError.loadingOverlayFailed(line: #line) }
            try capture(window, to: output.appendingPathComponent("loading-\(appearance.rawValue).png"))
        }
        canvas.image = image
        guard !canvas.isLoading else { throw PreviewError.loadingOverlayFailed(line: #line) }
    }

    /// Ensures real arrow events keep image/metadata selection consistent through reversals and rapid repeats.
    private static func verifyArrowNavigation(_ viewer: ViewerController) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = URL(fileURLWithPath: "Tests/LuloImagingTests/Fixtures/DSCF2143-LR-light.jpg")
        let urls = ["a.jpg", "b.jpg", "c.jpg"].map { folder.appendingPathComponent($0) }
        for url in urls { try FileManager.default.copyItem(at: photo, to: url) }
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let metadata = descendants(root).compactMap({ $0 as? NSTextView }).first
        else { throw PreviewError.missingWindow(line: #line) }
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
                throw PreviewError.navigationFailed(line: #line)
            }
        }
        viewer.open(urls[0])
        try waitUntil("initial photo") { canvas.image != nil && metadata.string.contains("a.jpg") }
        // Only this temporary, harness-owned folder is granted; the real sandbox sheet is tested manually.
        guard folder.standardizedFileURL == urls[0].deletingLastPathComponent().standardizedFileURL else {
            FileHandle.standardError.write(Data("Navigation test grant does not match the opened parent.\n".utf8))
            throw PreviewError.navigationFailed(line: #line)
        }
        let discovered = try ImageLoader.discover(in: folder)
        guard discovered.count == 3, discovered.contains(where: { $0.url == urls[0] }) else {
            throw PreviewError.navigationFailed(line: #line)
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
            else { throw PreviewError.navigationFailed(line: #line) }
            let retainedImage = canvas.image
            let retainedScale = canvas.zoom.scale
            canvas.keyDown(with: event)
            // Keep the previous pixels while checking the cache; a miss may show the overlay after yielding.
            guard canvas.image === retainedImage, canvas.zoom.scale == retainedScale, canvas.isLoading,
                metadata.string.isEmpty,
                canvas.loadingBox.isHidden
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
                throw PreviewError.navigationFailed(line: #line)
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
        else { throw PreviewError.displayToggleFailed(line: #line) }
        let dragEnd = CGPoint(x: cursor.x + 20, y: cursor.y - 15)
        for (type, point) in [
            (NSEvent.EventType.leftMouseDown, cursor), (.leftMouseDragged, dragEnd), (.leftMouseUp, dragEnd),
        ] {
            guard
                let event = NSEvent.mouseEvent(
                    with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else { throw PreviewError.displayToggleFailed(line: #line) }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        let actualRect = canvas.displayedImageRect
        guard abs(actualRect.minX - zoomedRect.minX - 20) < 0.01,
            abs(actualRect.minY - zoomedRect.minY + 15) < 0.01
        else { throw PreviewError.displayToggleFailed(line: #line) }
        let center = canvas.zoom.center
        for direction in [1, 1, -1, -1] {
            try arrow(direction)
            index = (index + direction + urls.count) % urls.count
            try waitUntil("zoomed arrow") {
                !canvas.isLoading && metadata.string.contains(urls[index].lastPathComponent)
            }
            guard canvas.zoom.mode == .actualSize, canvas.zoom.scale == 1,
                canvas.zoom.center == center, canvas.displayedImageRect == actualRect
            else { throw PreviewError.displayToggleFailed(line: #line) }
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
        else { throw PreviewError.navigationFailed(line: #line) }
        viewer.open(urls[0])
        viewer.open(urls[2])
        try waitUntil("superseded open") { canvas.image != nil && metadata.string.contains("c.jpg") }
        guard window.title == "c.jpg", canvas.zoom.mode == .fit, canvas.zoom.scale == nil,
            canvas.zoom.center == CGPoint(x: 0.5, y: 0.5)
        else { throw PreviewError.navigationFailed(line: #line) }
        try waitUntil("rediscovery after explicit opens") {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "3 of 3" }
        }
        // Invalidating a cached neighbor must clear the retained pixels without losing the viewing mode/region.
        try doubleClick(canvas, at: cursor)
        let errorCenter = canvas.zoom.center
        try Data("corrupt image".utf8).write(to: urls[1])
        try arrow(-1)
        try waitUntil("recoverable error") { !canvas.isLoading && canvas.image == nil }
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
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first
        else { throw PreviewError.navigationFailed(line: #line) }
        let overlay = canvas.loadingBox
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
            else { throw PreviewError.navigationFailed(line: #line) }
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
        else { throw PreviewError.missingWindow(line: #line) }
        func waitUntil(_ stage: String, _ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard ready() else {
                FileHandle.standardError.write(Data("Scan cancellation timeout: \(stage), state=\(gate.state)\n".utf8))
                throw PreviewError.navigationFailed(line: #line)
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
        guard retainedGrant != nil else { throw PreviewError.navigationFailed(line: #line) }
        gate.release()
        try waitUntil("scan exit and grant release") { gate.state.finished && retainedGrant == nil }
        guard gate.state.checks == 3, !gate.state.timedOut, window.title == "new.png",
            descendants(content).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == "1 of 1" })
        else { throw PreviewError.navigationFailed(line: #line) }
        print(
            "Verified an active scan stops after one metadata read, preserves the new session, and releases its grant.")
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
            let refresh = toolbarButton(window, "Refresh (⌘R)")
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
        guard refresh.isEnabled, hasStatus("1 of 1"), statusRating(root) == 1,
            let rating = descendants(root).compactMap({ $0 as? RatingChip }).first(where: {
                $0.accessibilityIdentifier() == "status-rating"
            })
        else { throw PreviewError.refreshFailed(line: #line) }
        viewer.toggleSidebar()
        for stars in [2, 3, 4, 5, 0, nil, 1] as [Int?] {
            try makeFixture(at: first, rating: stars)
            let previous = canvas.image
            refresh.performClick(nil)
            guard rating.isHidden else { throw PreviewError.refreshFailed(line: #line) }
            try waitUntil { canvas.image != nil && canvas.image !== previous && !canvas.isLoading }
            let count = stars ?? 0
            guard statusRating(root) == (count == 0 ? nil : count), rating.isHidden == (count == 0),
                hasStatus("1 of 1"), window.title == "a.png"
            else { throw PreviewError.refreshFailed(line: #line) }
            if count > 0 {
                guard rating.accessibilityLabel() == "\(count) \(count == 1 ? "star" : "stars")" else {
                    throw PreviewError.refreshFailed(line: #line)
                }
            }
        }
        // A filtered-out single file must reappear when its refreshed rating now matches.
        guard let browse = toolbarButton(window, "Sort & Filter") else { throw PreviewError.refreshFailed(line: #line) }
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
        guard fiveStars.state == .on, statusRating(root) == 5 else {
            throw PreviewError.refreshFailed(line: #line)
        }
        clearFilters.performClick(nil)
        browse.performClick(nil)
        try makeFixture(at: first, rating: 1)
        viewer.refreshImages()
        try waitUntil { !canvas.isLoading && statusRating(root) == 1 }
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
        guard statusRating(root) == 5 else { throw PreviewError.refreshFailed(line: #line) }
        try Data("corrupt".utf8).write(to: third)
        refresh.performClick(nil)
        try waitUntil { !canvas.isLoading && canvas.image == nil }
        guard rating.isHidden else { throw PreviewError.refreshFailed(line: #line) }
        try FileManager.default.removeItem(at: third)
        refresh.performClick(nil)
        try waitUntil { hasStatus("0 images") && hasStatus("No images remaining.") }
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
        try waitUntil { statusRating(root) == 5 && canvas.image?.height == 1200 && !canvas.isLoading }
        guard hasLabel("1 of 1") else { throw PreviewError.refreshFailed(line: #line) }
        try FileManager.default.removeItem(at: first)
        try waitUntil { !canvas.isLoading && canvas.image == nil }
        try makeFixture(at: first, rating: 3)
        try waitUntil { canvas.image != nil && !canvas.isLoading && statusRating(root) == 3 }
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
        try waitUntil { window.title == "c.png" && !canvas.isLoading && canvas.image != nil && statusRating(root) == 4 }
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

    /// Finds a toolbar capsule button by its accessibility label, or by the label's prefix for counted labels.
    private static func toolbarButton(_ window: NSWindow, _ label: String) -> ToolbarButton? {
        descendants(window.toolbar?.items.compactMap(\.view) ?? []).compactMap { $0 as? ToolbarButton }
            .first { $0.accessibilityLabel()?.hasPrefix(label) == true }
    }

    private static func descendants(_ views: [NSView]) -> [NSView] { views.flatMap { descendants($0) } }

    private static func itemFrame(_ collection: NSCollectionView, _ index: Int) -> NSRect {
        collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame ?? .zero
    }

    private static func zoomText(_ root: NSView) -> String? {
        descendants(root).compactMap { $0 as? NSTextField }.first {
            !$0.isHiddenOrHasHiddenAncestor && ($0.stringValue.hasPrefix("Fit, ") || $0.stringValue.hasSuffix("%"))
        }?.stringValue
    }

    /// The visible badge number, or 0 when the badge is hidden.
    private static func badgeCount(_ browse: NSView) -> Int {
        descendants(browse).compactMap { $0 as? BadgeView }.first.map { $0.isHidden ? 0 : $0.count } ?? -1
    }

    /// The status line's rating chip value, or nil while it is hidden.
    private static func statusRating(_ root: NSView) -> Int? {
        let chip = descendants(root).compactMap { $0 as? RatingChip }.first {
            $0.accessibilityIdentifier() == "status-rating"
        }
        guard let chip, !chip.isHidden else { return nil }
        return chip.rating
    }

    /// Ensures the breadcrumb shows exactly these names (parent, folder, file) in order, with the full path available.
    private static func verifyBreadcrumb(_ window: NSWindow, visible names: [String]) throws {
        guard
            let crumb = descendants(window.toolbar?.items.compactMap(\.view) ?? []).compactMap({ $0 as? BreadcrumbView }
            ).first
        else { throw PreviewError.breadcrumbFailed(line: #line) }
        crumb.layoutSubtreeIfNeeded()
        let shown = crumb.arrangedSubviews.filter { !$0.isHidden }.compactMap { view -> String? in
            if let button = view as? NSButton { return button.title }
            guard let label = view as? NSTextField, label.stringValue != "/" else { return nil }
            return label.stringValue
        }
        guard shown == names, crumb.toolTip?.hasPrefix("/") == true,
            crumb.accessibilityValue() as? String == crumb.toolTip
        else {
            FileHandle.standardError.write(Data("Breadcrumb showed \(shown), expected \(names)\n".utf8))
            throw PreviewError.breadcrumbFailed(line: #line)
        }
    }

    /// Ensures every capsule (and the breadcrumb) stays in the toolbar instead of moving to an overflow menu.
    private static func verifyToolbarFits(_ window: NSWindow) throws {
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard let items = window.toolbar?.items, items.count >= 5,
            items.allSatisfy({ $0.view == nil || $0.view?.window === window })
        else { throw PreviewError.toolbarOverflow(width: window.frame.width) }
    }

    /// Ensures Blurred Background toggles from the toolbar, persists, shows the selected image, and turns off again.
    private static func verifyBlurredBackground(_ viewer: ViewerController, output: URL, name: String) throws {
        guard let window = viewer.window, let backdrop = window.contentView as? BackdropView,
            let blur = toolbarButton(window, "Blurred Background"), !backdrop.isBlurred, blur.state == .off
        else { throw PreviewError.backgroundFailed(line: #line) }
        blur.performClick(nil)
        let deadline = Date().addingTimeInterval(15)
        while backdrop.image == nil && Date() < deadline { settle() }
        guard backdrop.isBlurred, blur.state == .on, backdrop.image != nil, viewer.blurredBackground,
            Preferences(defaults: .standard).blurredBackground
        else { throw PreviewError.backgroundFailed(line: #line) }
        settle()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            settle()
            try capture(window, to: output.appendingPathComponent("\(name)-blur-\(appearance.rawValue).png"))
        }
        viewer.toggleBlurredBackground()
        guard !backdrop.isBlurred, blur.state == .off, !Preferences(defaults: .standard).blurredBackground else {
            throw PreviewError.backgroundFailed(line: #line)
        }
    }

    /// Ensures the size controls snap, persist per layout, keep the selection visible, and respect their limits.
    private static func verifyThumbnailSizes(_ viewer: ViewerController, collection: NSCollectionView) throws {
        guard let window = viewer.window, let larger = toolbarButton(window, "Larger thumbnails"),
            let smaller = toolbarButton(window, "Smaller thumbnails"),
            let slider = descendants(window.toolbar?.items.compactMap(\.view) ?? []).compactMap({ $0 as? NSSlider })
                .first,
            slider.accessibilityLabel() == "Row height", slider.doubleValue == 200
        else { throw PreviewError.sizeFailed(line: #line) }
        let selected = IndexPath(item: 2, section: 0)
        let height = itemFrame(collection, 2).height
        viewer.largerThumbnails()
        collection.layoutSubtreeIfNeeded()
        guard Preferences(defaults: .standard).thumbnailSize(for: .rows) == 220, slider.doubleValue == 220,
            itemFrame(collection, 2).height > height, collection.selectionIndexPaths == [selected],
            collection.visibleRect.intersects(itemFrame(collection, 2))
        else { throw PreviewError.sizeFailed(line: #line) }
        for _ in 0..<20 { smaller.performClick(nil) }
        guard Preferences(defaults: .standard).thumbnailSize(for: .rows) == 120, !smaller.isEnabled, larger.isEnabled
        else { throw PreviewError.sizeFailed(line: #line) }
        slider.doubleValue = 203
        slider.sendAction(slider.action, to: slider.target)
        guard Preferences(defaults: .standard).thumbnailSize(for: .rows) == 200, slider.doubleValue == 200 else {
            throw PreviewError.sizeFailed(line: #line)
        }
    }

    /// Ensures Preview shows square tiles, a poster of the selection with its caption, and keeps its own size.
    private static func verifyPreviewLayout(
        _ viewer: ViewerController, collection: NSCollectionView, poster: PosterView, output: URL
    ) throws {
        guard let window = viewer.window, let rows = toolbarButton(window, "Rows"),
            let preview = toolbarButton(window, "Preview"), rows.state == .on,
            preview.accessibilityRole() == .radioButton
        else { throw PreviewError.previewFailed(line: #line) }
        let selected = collection.selectionIndexPaths
        preview.performClick(nil)
        let deadline = Date().addingTimeInterval(15)
        while (poster.preview.image == nil || poster.caption.stringValue.isEmpty) && Date() < deadline { settle() }
        let tile = itemFrame(collection, 2)
        guard viewer.galleryLayout == .preview, preview.state == .on, rows.state == .off, !poster.isHidden,
            Preferences(defaults: .standard).galleryLayout == .preview, collection.selectionIndexPaths == selected,
            abs(tile.width - tile.height) < 0.01, tile.width - 8 >= 128,
            poster.entry?.url.lastPathComponent == "photo2.png", poster.preview.image != nil,
            poster.caption.stringValue.contains("f/2.8")
        else { throw PreviewError.previewFailed(line: #line) }
        viewer.largerThumbnails()
        guard Preferences(defaults: .standard).thumbnailSize(for: .preview) == 140,
            Preferences(defaults: .standard).thumbnailSize(for: .rows) == 200
        else { throw PreviewError.previewFailed(line: #line) }
        viewer.smallerThumbnails()
        settle()
        try capture(window, to: output.appendingPathComponent("gallery-preview-light.png"))
        viewer.showRows()
        guard viewer.galleryLayout == .rows, poster.isHidden, collection.selectionIndexPaths == selected else {
            throw PreviewError.previewFailed(line: #line)
        }
    }

    private static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func capture(_ window: NSWindow, to url: URL) throws {
        guard let view = window.contentView?.superview else { throw PreviewError.missingWindow(line: #line) }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewError.captureFailed(line: #line)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.captureFailed(line: #line)
        }
        try data.write(to: url)
        // Verify the rendered window contains a usable image area even with the inspector visible.
        if let canvas = descendants(view).compactMap({ $0 as? ImageCanvas }).first, !canvas.isHiddenOrHasHiddenAncestor
        {
            guard canvas.frame.width >= 300, canvas.frame.height >= 250 else {
                throw PreviewError.clippedCanvas(line: #line)
            }
        }
    }

    private static func makeFixture(at url: URL, rating: Int? = nil, orientation: Int = 1) throws {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 4800,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw PreviewError.captureFailed(line: #line)
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
            throw PreviewError.captureFailed(line: #line)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [
                "DateTimeOriginal": "2026:01:02 03:04:05", "FNumber": 2.8, "FocalLength": 35,
            ],
            kCGImagePropertyTIFFDictionary: ["Make": "Synthetic Camera", "Model": "Preview Fixture", "Artist": "Lulo"],
        ]
        if let rating {
            let metadata = CGImageMetadataCreateMutable()
            guard CGImageMetadataSetValueWithPath(metadata, nil, "xmp:Rating" as CFString, String(rating) as CFString)
            else { throw PreviewError.captureFailed(line: #line) }
            CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
        } else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw PreviewError.captureFailed(line: #line) }
    }

    private enum PreviewError: Error {
        case displayToggleFailed(line: Int)
        case missingWindow(line: Int)
        case imageDidNotLoad(line: Int)
        case captureFailed(line: Int)
        case clippedCanvas(line: Int)
        case missingPopover(line: Int)
        case galleryFailed(line: Int)
        case galleryRatingPlacementFailed(line: Int)
        case trashFailed(line: Int)
        case missingFilterControls(line: Int)
        case filterDidNotApply(line: Int)
        case filterDidNotClear(line: Int)
        case navigationFailed(line: Int)
        case refreshFailed(line: Int)
        case loadingOverlayFailed(line: Int)
        case breadcrumbFailed(line: Int)
        case backgroundFailed(line: Int)
        case sizeFailed(line: Int)
        case previewFailed(line: Int)
        case toolbarOverflow(width: CGFloat)
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
