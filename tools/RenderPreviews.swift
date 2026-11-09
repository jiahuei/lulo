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
        try verifyDisplayToggle(window)
        try capture(window, to: output.appendingPathComponent("image-light.png"))
        viewer.toggleSidebar()
        settle()
        try capture(window, to: output.appendingPathComponent("metadata-light.png"))
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 720, height: 480))
        settle()
        try capture(window, to: output.appendingPathComponent("metadata-compact-dark.png"))
        try verifyLoadingOverlay(window, output: output)
        if let browse = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Browse" })?.view
            as? NSButton
        {
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
        } else {
            throw PreviewError.missingFilterControls
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

    /// Ensures each zoom segment updates the image and saved default, including restoration in a new viewer.
    private static func verifyDisplayToggle(_ window: NSWindow) throws {
        guard let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let display = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Display" })?.view
                as? NSSegmentedControl,
            display.selectedSegment == 0, canvas.displayDefault == .fit, canvas.zoom.scale == nil
        else { throw PreviewError.displayToggleFailed }
        for (segment, expected) in [(1, DisplayDefault.actualSize), (0, DisplayDefault.fit)] {
            canvas.zoom.scroll(up: true, currentScale: 2)
            display.selectedSegment = segment
            display.sendAction(display.action, to: display.target)
            guard canvas.displayDefault == expected,
                canvas.zoom.scale == (expected == .fit ? nil : 1),
                Preferences(defaults: .standard).display == expected
            else { throw PreviewError.displayToggleFailed }
            let restored = ViewerController()
            defer { restored.window?.close() }
            guard
                let restoredDisplay = restored.window?.toolbar?.items.first(where: {
                    $0.itemIdentifier.rawValue == "Display"
                })?.view as? NSSegmentedControl,
                restoredDisplay.selectedSegment == segment
            else { throw PreviewError.displayToggleFailed }
        }
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
            let display = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Display" })?.view
                as? NSSegmentedControl,
            let trash = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Trash" })?.view as? NSButton
        else { throw PreviewError.galleryFailed }
        defer { window.close() }
        window.setContentSize(NSSize(width: 1000, height: 680))
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.galleryFailed }
        }
        func key(_ code: UInt16) throws {
            let characters = code == 124 ? "\u{F703}" : "\r"
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)
            else { throw PreviewError.galleryFailed }
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
        viewer.toggleGallery()
        guard gallery.isHidden, collection.numberOfItems(inSection: 0) == 0 else { throw PreviewError.galleryFailed }
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
            !viewer.canTrashCurrentImage, !trash.isEnabled, !display.isEnabled
        else { throw PreviewError.galleryFailed }
        viewer.trashCurrentImage()
        guard window.attachedSheet == nil else { throw PreviewError.galleryFailed }
        try waitUntil {
            descendants(gallery).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Preview unavailable" }
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
        try key(124)
        guard collection.selectionIndexPaths == [IndexPath(item: 2, section: 0)] else {
            throw PreviewError.galleryFailed
        }
        try key(36)
        try waitUntil { gallery.isHidden && viewer.canTrashCurrentImage && window.title == "photo2.png" }
        guard display.isEnabled else { throw PreviewError.displayToggleFailed }
        viewer.toggleGallery()
        guard collection.selectionIndexPaths == [IndexPath(item: 2, section: 0)] else {
            throw PreviewError.galleryFailed
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
            let browse = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Browse" })?.view
                as? NSButton
        else { throw PreviewError.galleryFailed }
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
        else { throw PreviewError.galleryFailed }
        fiveStars.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 1 else { throw PreviewError.galleryFailed }
        try waitUntil { thumbnailsReady() }
        guard collection.item(at: IndexPath(item: 0, section: 0))?.textField?.stringValue == "photo5.png" else {
            throw PreviewError.galleryFailed
        }
        fourStars.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 2 else { throw PreviewError.galleryFailed }
        try waitUntil { thumbnailsReady() }
        jpeg.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 0 else { throw PreviewError.galleryFailed }
        png.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 2 else { throw PreviewError.galleryFailed }
        try waitUntil { thumbnailsReady() }
        png.performClick(nil)
        browse.performClick(nil)
        guard collection.numberOfItems(inSection: 0) == 0,
            let clear = descendants(gallery).compactMap({ $0 as? NSButton }).first(where: {
                $0.title == "Clear Filters"
            })
        else { throw PreviewError.galleryFailed }
        clear.performClick(nil)
        try waitUntil { collection.numberOfItems(inSection: 0) == 81 }
        // A new explicit open must close the gallery and discard its old cells and thumbnail requests.
        viewer.open(fixture)
        try waitUntil { gallery.isHidden && !canvas.isLoading && window.title == fixture.lastPathComponent }
        guard collection.numberOfItems(inSection: 0) == 0 else { throw PreviewError.galleryFailed }
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
            let trash = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Trash" })?.view as? NSButton
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

    /// Ensures real checkbox actions retain multiple choices, intersect groups, and recover after deselection.
    private static func verifyFilterCheckboxes(popover: NSWindow, viewer: NSWindow) throws {
        let buttons = descendants(popover.contentView!).compactMap { $0 as? NSButton }
        guard let unrated = buttons.first(where: { $0.title == "Unrated / 0 Stars" }),
            let fiveStars = buttons.first(where: { $0.title == "5 Stars" }),
            let jpeg = buttons.first(where: { $0.title == "JPEG" }),
            let png = buttons.first(where: { $0.title == "PNG" }),
            let clear = buttons.first(where: { $0.title == "Clear Filters" }),
            let canvas = descendants(viewer.contentView!).compactMap({ $0 as? ImageCanvas }).first,
            let browse = viewer.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Browse" })?.view
                as? NSButton
        else { throw PreviewError.missingFilterControls }
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
            canvas.image != nil, browse.accessibilityLabel() == "Sort & Filter, 2 active filters",
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
        guard canvas.image != nil, browse.accessibilityLabel() == "Sort & Filter, 1 active filters" else {
            throw PreviewError.filterDidNotClear
        }
        clear.performClick(nil)
        guard choices.allSatisfy({ $0.state == .off }), browse.accessibilityLabel() == "Sort & Filter" else {
            throw PreviewError.filterDidNotClear
        }
        unrated.performClick(nil)
        fiveStars.performClick(nil)
        unrated.performClick(nil)
        guard canvas.image == nil, fiveStars.state == .on else { throw PreviewError.filterDidNotApply }
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
                let box = descendants(canvas).compactMap({ $0 as? NSVisualEffectView }).first,
                !box.isHidden, box.frame.width <= 360, box.frame.height <= 80,
                canvas.bounds.contains(box.frame),
                descendants(box).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue == filename }),
                descendants(box).contains(where: { $0 is NSProgressIndicator && !$0.isHidden })
            else { throw PreviewError.loadingOverlayFailed }
            try capture(window, to: output.appendingPathComponent("loading-\(appearance.rawValue).png"))
        }
        canvas.image = image
        guard !canvas.isLoading else { throw PreviewError.loadingOverlayFailed }
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
                descendants(canvas).compactMap({ $0 as? NSVisualEffectView }).allSatisfy(\.isHidden)
            else { throw PreviewError.loadingOverlayFailed }
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
        // Queue rapid selections without waiting for intermediate decodes, including a direction reversal.
        for direction in [1, 1, 1, -1, 1, -1, -1] {
            try arrow(direction)
            index = (index + direction + urls.count) % urls.count
        }
        try waitUntil("arrow to \(urls[index].lastPathComponent)") {
            canvas.image != nil && !canvas.isLoading && metadata.string.contains(urls[index].lastPathComponent)
        }
        guard window.title == urls[index].lastPathComponent else { throw PreviewError.navigationFailed }
        viewer.open(urls[0])
        viewer.open(urls[2])
        try waitUntil("superseded open") { canvas.image != nil && metadata.string.contains("c.jpg") }
        guard window.title == "c.jpg" else { throw PreviewError.navigationFailed }
        try waitUntil("rediscovery after explicit opens") {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "3 of 3" }
        }
        // Invalidating a cached neighbor must clear the retained pixels on failure and allow another arrow.
        try Data("corrupt image".utf8).write(to: urls[1])
        try arrow(-1)
        try waitUntil("recoverable error") { !canvas.isLoading && canvas.image == nil }
        guard
            descendants(canvas).compactMap({ $0 as? NSTextField }).contains(where: {
                $0.stringValue == "Cannot display this image" && !$0.isHiddenOrHasHiddenAncestor
            })
        else { throw PreviewError.loadingOverlayFailed }
        try arrow(-1)
        try waitUntil("navigation after error") {
            !canvas.isLoading && canvas.image != nil && metadata.string.contains("a.jpg")
        }
        settle()
        guard !canvas.isLoading else { throw PreviewError.loadingOverlayFailed }
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
        let viewer = ViewerController(imageStore: store)
        guard let window = viewer.window, let root = window.contentView,
            let canvas = descendants(root).compactMap({ $0 as? ImageCanvas }).first,
            let overlay = descendants(canvas).compactMap({ $0 as? NSVisualEffectView }).first
        else { throw PreviewError.navigationFailed }
        defer { window.close() }
        func waitWithoutOverlay(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                guard overlay.isHidden else { throw PreviewError.loadingOverlayFailed }
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            }
            guard ready(), overlay.isHidden else { throw PreviewError.loadingOverlayFailed }
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
                throw PreviewError.loadingOverlayFailed
            }
            try waitWithoutOverlay { !canvas.isLoading }
            guard canvas.image != nil, canvas.image !== previous,
                window.title == (forward ? "b.png" : "a.png")
            else { throw PreviewError.navigationFailed }
        }
        // Drain any queued notifications: completion must not be followed by a stale loading overlay.
        settle()
        guard !canvas.isLoading, overlay.isHidden else { throw PreviewError.loadingOverlayFailed }
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
            let refresh = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Refresh" })?.view
                as? NSButton
        else { throw PreviewError.refreshFailed }
        defer { window.close() }
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.refreshFailed }
        }
        func hasStatus(_ text: String) -> Bool {
            descendants(root).compactMap { $0 as? NSTextField }.contains { $0.stringValue == text }
        }
        viewer.open(first)
        try waitUntil { canvas.image != nil && !canvas.isLoading && window.attachedSheet == nil }
        guard refresh.isEnabled, hasStatus("1 of 1"),
            let rating = descendants(root).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == "★" })
        else { throw PreviewError.refreshFailed }
        viewer.toggleSidebar()
        for stars in [2, 3, 4, 5, 0, nil, 1] as [Int?] {
            try makeFixture(at: first, rating: stars)
            let previous = canvas.image
            refresh.performClick(nil)
            guard rating.isHidden else { throw PreviewError.refreshFailed }
            try waitUntil { canvas.image != nil && canvas.image !== previous && !canvas.isLoading }
            let count = stars ?? 0
            guard rating.stringValue == String(repeating: "★", count: count), rating.isHidden == (count == 0),
                hasStatus("1 of 1"), window.title == "a.png"
            else { throw PreviewError.refreshFailed }
            if count > 0 {
                guard rating.accessibilityLabel() == "\(count) \(count == 1 ? "star" : "stars")" else {
                    throw PreviewError.refreshFailed
                }
            }
        }
        // A filtered-out single file must reappear when its refreshed rating now matches.
        guard
            let browse = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "Browse" })?.view
                as? NSButton
        else { throw PreviewError.refreshFailed }
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
        else { throw PreviewError.refreshFailed }
        fiveStars.performClick(nil)
        guard canvas.image == nil, rating.isHidden else { throw PreviewError.refreshFailed }
        try makeFixture(at: first, rating: 5)
        viewer.refreshImages()
        try waitUntil { canvas.image != nil && !canvas.isLoading }
        guard fiveStars.state == .on, rating.stringValue == "★★★★★" else { throw PreviewError.refreshFailed }
        clearFilters.performClick(nil)
        browse.performClick(nil)
        try makeFixture(at: first, rating: 1)
        viewer.refreshImages()
        try waitUntil { !canvas.isLoading && rating.stringValue == "★" }
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
        guard rating.isHidden, refresh.isEnabled else { throw PreviewError.refreshFailed }
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
        else { throw PreviewError.refreshFailed }
        // The directly opened file must disappear too, rather than being appended back into discovery.
        try FileManager.default.removeItem(at: first)
        refresh.performClick(nil)
        try waitUntil { collection.numberOfItems(inSection: 0) == 1 }
        viewer.toggleGallery()
        try waitUntil { !canvas.isLoading && canvas.image != nil && window.title == "c.png" }
        guard rating.stringValue == "★★★★★", !rating.isHidden else { throw PreviewError.refreshFailed }
        try Data("corrupt".utf8).write(to: third)
        refresh.performClick(nil)
        try waitUntil { !canvas.isLoading && canvas.image == nil }
        guard rating.isHidden else { throw PreviewError.refreshFailed }
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
        else { throw PreviewError.refreshFailed }
        defer { window.close() }
        func waitUntil(_ ready: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !ready() && Date() < deadline {
                if let panel = window.attachedSheet as? NSOpenPanel { panel.cancel(nil) }
                settle()
            }
            guard ready() else { throw PreviewError.refreshFailed }
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
        try waitUntil { hasLabel("★★★★★") && canvas.image?.height == 1200 && !canvas.isLoading }
        guard hasLabel("1 of 1") else { throw PreviewError.refreshFailed }
        try FileManager.default.removeItem(at: first)
        try waitUntil { !canvas.isLoading && canvas.image == nil }
        try makeFixture(at: first, rating: 3)
        try waitUntil { canvas.image != nil && !canvas.isLoading && hasLabel("★★★") }
        viewer.useAuthorizedFolder(FileAccess(url: folder))
        try waitUntil { hasLabel("1 of 2") }
        viewer.toggleGallery()
        let third = folder.appendingPathComponent("c.png")
        try makeFixture(at: third, rating: 4)
        try FileManager.default.removeItem(at: second)
        try waitUntil {
            collection.visibleItems().contains { $0.textField?.stringValue == "c.png" && $0.imageView?.image != nil }
        }
        guard collection.numberOfItems(inSection: 0) == 2 else { throw PreviewError.refreshFailed }
        try FileManager.default.removeItem(at: first)
        try waitUntil { collection.numberOfItems(inSection: 0) == 1 }
        viewer.toggleGallery()
        try waitUntil { window.title == "c.png" && !canvas.isLoading && canvas.image != nil && hasLabel("★★★★") }
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
            throw PreviewError.refreshFailed
        }
        print("Verified automatic replacement, deletion/recreation, folder discovery, and session isolation.")
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
        if let canvas = descendants(view).compactMap({ $0 as? ImageCanvas }).first, !canvas.isHiddenOrHasHiddenAncestor
        {
            guard canvas.frame.width >= 300, canvas.frame.height >= 250 else { throw PreviewError.clippedCanvas }
        }
    }

    private static func makeFixture(at url: URL, rating: Int? = nil, orientation: Int = 1) throws {
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
                "DateTimeOriginal": "2026:01:02 03:04:05", "FNumber": 2.8, "FocalLength": 35,
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
        case missingWindow, imageDidNotLoad, captureFailed, clippedCanvas, missingPopover, galleryFailed
        case galleryRatingPlacementFailed
        case trashFailed, refreshFailed
        case missingFilterControls, filterDidNotApply, filterDidNotClear, navigationFailed, loadingOverlayFailed
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
