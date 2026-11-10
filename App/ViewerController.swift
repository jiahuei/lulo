import AppKit
import LuloCore
import LuloImaging
import UniformTypeIdentifiers

@MainActor
final class ViewerController: NSWindowController {
    private var session = ViewingSession(preferences: Preferences(defaults: .standard))
    private let canvas = ImageCanvas()
    private let thumbnails: ThumbnailLoader
    private let gallery: GalleryView
    private let backdrop = BackdropView()
    private let breadcrumb = BreadcrumbView()
    private let metadataPanel = MetadataPanel()
    private var galleryVisible = false
    // Toolbar capsules, in order: library, navigation, display, and inspection.
    private let galleryButton = ToolbarButton(
        symbol: "square.grid.2x2", label: "Show gallery", type: .pushOnPushOff, target: nil, action: nil)
    private let openButton = ToolbarButton(symbol: "photo", label: "Open image", target: nil, action: nil)
    private let refresh = ToolbarButton(label: "Refresh (⌘R)", target: nil, action: nil)
    private let previous = ToolbarButton(symbol: "chevron.left", label: "Previous image", target: nil, action: nil)
    private let next = ToolbarButton(symbol: "chevron.right", label: "Next image", target: nil, action: nil)
    private let fitButton = ToolbarButton(
        symbol: "arrow.down.right.and.arrow.up.left", label: "Fit to window", type: .radio, target: nil, action: nil)
    private let actualSizeButton = ToolbarButton(title: "100%", label: "100%", type: .radio, target: nil, action: nil)
    private let rowsButton = ToolbarButton(
        symbol: "rectangle.grid.1x2", title: "Rows", label: "Rows (⌘1)", type: .radio, target: nil, action: nil)
    private let previewButton = ToolbarButton(
        symbol: "sidebar.squares.left", title: "Preview", label: "Preview (⌘2)", type: .radio, target: nil,
        action: nil)
    private let layoutDivider = HairlineDivider()
    private let smallerButton = ToolbarButton(
        symbol: "square.grid.3x3", label: "Smaller thumbnails", target: nil, action: nil)
    private let sizeSlider = ThumbnailSizeSlider()
    private let largerButton = ToolbarButton(symbol: "square", label: "Larger thumbnails", target: nil, action: nil)
    private let backgroundDivider = HairlineDivider()
    private let blurButton = ToolbarButton(
        symbol: "drop.halffull", label: "Blurred Background", type: .pushOnPushOff, target: nil, action: nil)
    private let browse = ToolbarButton(
        symbol: "line.3.horizontal.decrease.circle", label: "Sort & Filter", target: nil, action: nil)
    private let badge = BadgeView()
    private let info = ToolbarButton(
        symbol: "sidebar.right", label: "Show metadata", type: .pushOnPushOff, target: nil, action: nil)
    private let trash = ToolbarButton(symbol: "trash", label: "Move to Trash", target: nil, action: nil)
    private var sliderWidth: NSLayoutConstraint?
    private var capsules: [NSToolbarItem.Identifier: CapsuleView] = [:]
    private var sortButtons: [ToolbarButton] = []
    private var directionButtons: [ToolbarButton] = []
    private var ratingButtons: [NSButton] = []
    private var formatButtons: [NSButton] = []
    private let browsePopover = NSPopover()
    private let status = NSTextField(labelWithString: "")
    private let ratingChip = RatingChip()
    private let filterSummary = NSTextField(labelWithString: "")
    private let zoomLabel = NSTextField(labelWithString: "")
    private var currentRating: Int?
    typealias DiscoverImages = @Sendable (URL, @Sendable () -> Bool) throws -> [ImageEntry]
    typealias MoveToTrash = @Sendable (URL, FileAccess) async throws -> Void
    private let moveToTrash: MoveToTrash
    private var trashInProgress = false
    private let discoverImages: DiscoverImages
    private let worker = OperationQueue()
    private var fileAccess: FileAccess?
    private var folderAccess: FileAccess?
    private var folderPanel: NSOpenPanel?
    private let imageStore: ImageStore
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var posterTask: Task<Void, Never>?
    private var posterURL: URL?
    private var backdropTask: Task<Void, Never>?
    private var backdropURL: URL?
    private var navigationDirection = 1
    private var request = 0
    private var cacheGeneration = 0
    private var thumbnailGeneration = 0
    private var openedURL: URL?
    private let automaticallyRefresh: Bool
    private var changeMonitor: ImageChangeMonitor?
    private var automaticRefreshTask: Task<Void, Never>?
    /// A refresh the person started animates the Refresh glyph until its scan and image load finish.
    private var manualRefresh = false
    private var scanning = false
    private var scanToken = 0
    private var refreshTimer: Timer?
    private var refreshPhase = 0

    init(
        imageStore: ImageStore = ImageStore(),
        discoverImages: @escaping DiscoverImages = { try ImageLoader.discover(in: $0, isCancelled: $1) },
        moveToTrash: @escaping MoveToTrash = { _ = try await ImageTrash().move(at: $0, access: $1) },
        automaticallyRefresh: Bool = true
    ) {
        self.imageStore = imageStore
        self.moveToTrash = moveToTrash
        self.discoverImages = discoverImages
        self.automaticallyRefresh = automaticallyRefresh
        let thumbnails = ThumbnailLoader()
        self.thumbnails = thumbnails
        gallery = GalleryView(loader: thumbnails)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        // The title stays set for the Window menu and Mission Control; the breadcrumb replaces its display.
        window.title = "Lulo"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 400)
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        worker.maxConcurrentOperationCount = 1
        worker.qualityOfService = .userInitiated
        buildInterface()
        if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true) }
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible == false { canvas.resetZoom() }
        super.showWindow(sender)
    }

    var isGalleryVisible: Bool { galleryVisible }
    var galleryLayout: GalleryLayout { session.preferences.galleryLayout }
    var blurredBackground: Bool { session.preferences.blurredBackground }

    private func buildInterface() {
        guard let window else { return }
        let actions: [(NSButton, Selector)] = [
            (galleryButton, #selector(toggleGallery)), (openButton, #selector(openPanel)),
            (refresh, #selector(refreshImages)), (previous, #selector(previousImage)), (next, #selector(nextImage)),
            (fitButton, #selector(viewingModeChanged)), (actualSizeButton, #selector(viewingModeChanged)),
            (rowsButton, #selector(galleryLayoutChanged)), (previewButton, #selector(galleryLayoutChanged)),
            (smallerButton, #selector(smallerThumbnails)), (largerButton, #selector(largerThumbnails)),
            (blurButton, #selector(toggleBlurredBackground)), (browse, #selector(showBrowse)),
            (info, #selector(toggleSidebar)), (trash, #selector(trashCurrentImage)),
        ]
        for (button, action) in actions {
            button.target = self
            button.action = action
        }
        refresh.glyph = Theme.refreshGlyph(phase: 0)
        actualSizeButton.minimumWidth = 44
        sizeSlider.controlSize = .small
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(sizeSliderChanged)
        let sliderWidth = sizeSlider.widthAnchor.constraint(equalToConstant: 92)
        sliderWidth.isActive = true
        self.sliderWidth = sliderWidth
        badge.translatesAutoresizingMaskIntoConstraints = false
        browse.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 13), badge.heightAnchor.constraint(equalToConstant: 13),
            badge.topAnchor.constraint(equalTo: browse.topAnchor, constant: 1),
            badge.trailingAnchor.constraint(equalTo: browse.trailingAnchor, constant: -1),
        ])
        breadcrumb.showGallery = { [weak self] in self?.toggleGallery() }
        makeBrowsePopover()
        let toolbar = NSToolbar(identifier: "Viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        metadataPanel.isHidden = true
        gallery.isHidden = true
        let workspace = NSView()
        for view in [canvas, gallery] { pin(view, in: workspace) }
        let content = NSStackView(views: [workspace, metadataPanel])
        content.orientation = .horizontal
        content.alignment = .top
        content.distribution = .fill
        content.spacing = 0
        workspace.setContentHuggingPriority(.defaultLow, for: .horizontal)

        status.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        filterSummary.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        filterSummary.textColor = Theme.accentText
        filterSummary.lineBreakMode = .byTruncatingTail
        filterSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        zoomLabel.alignment = .right
        zoomLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        ratingChip.setAccessibilityIdentifier("status-rating")
        let footer = NSStackView(views: [status, ratingChip, filterSummary, spacer, zoomLabel])
        footer.spacing = 14
        footer.detachesHiddenViews = true
        footer.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 4, right: 20)
        footer.setCustomSpacing(10, after: status)

        window.contentView = backdrop
        for view in [content, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // Full-size content lets the background run under the transparent toolbar; controls stay below it.
            content.topAnchor.constraint(equalTo: backdrop.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor),
            workspace.heightAnchor.constraint(equalTo: content.heightAnchor),
            metadataPanel.heightAnchor.constraint(equalTo: content.heightAnchor),
            footer.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 34),
        ])
        canvas.navigate = { [weak self] delta in self?.navigate(delta) }
        canvas.zoomChanged = { [weak self] in self?.updateZoomControls() }
        gallery.selectionChanged = { [weak self] url in
            guard let self else { return }
            self.session.select(url)
            self.updateStatus()
            self.gallery.scrollSelectionIntoView()
        }
        gallery.openSelection = { [weak self] in self?.showSelectedImage() }
        gallery.navigate = { [weak self] delta in self?.navigate(delta) }
        canvas.resetZoom()
        canvas.showMessage(
            "Open an image.", detail: "View JPEG, PNG, and HEIF images.",
            actionTitle: "Open Image", action: { [weak self] in self?.openPanel() })
        applyGalleryLayout()
        applyBackground(animated: false)
        updateStatus()
        window.makeFirstResponder(canvas)
    }

    private func segment(_ titles: [String], action: Selector) -> (NSView, [ToolbarButton]) {
        let buttons = titles.map {
            let button = ToolbarButton(title: $0, label: $0, type: .radio, target: self, action: action)
            button.minimumWidth = 0
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.distribution = .fillEqually
        stack.spacing = 0
        let track = PanelView(fill: Theme.hoverFill, radius: 10)
        track.strokes = false
        pin(stack, in: track, insets: NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3))
        return (track, buttons)
    }

    private func makeBrowsePopover() {
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = Theme.textTertiary
            return label
        }
        let heading = NSTextField(labelWithString: "Sort & Filter")
        heading.font = .systemFont(ofSize: 15, weight: .bold)
        let (sortTrack, sortButtons) = segment(SortMethod.allCases.map(\.rawValue), action: #selector(sortChanged))
        let (directionTrack, directionButtons) = segment(["Ascending", "Descending"], action: #selector(sortChanged))
        self.sortButtons = sortButtons
        self.directionButtons = directionButtons
        ratingButtons = ["Unrated / 0 Stars", "1 Star", "2 Stars", "3 Stars", "4 Stars", "5 Stars"].map {
            NSButton(checkboxWithTitle: $0, target: self, action: #selector(filtersChanged))
        }
        formatButtons = ImageFormat.allCases.map {
            NSButton(checkboxWithTitle: $0.rawValue, target: self, action: #selector(filtersChanged))
        }
        let ratings = NSGridView(views: [
            [ratingButtons[0], ratingButtons[3]],
            [ratingButtons[1], ratingButtons[4]],
            [ratingButtons[2], ratingButtons[5]],
        ])
        ratings.rowSpacing = 6
        ratings.columnSpacing = 10
        ratings.xPlacement = .fill
        ratingButtons[0].widthAnchor.constraint(equalTo: ratingButtons[3].widthAnchor).isActive = true
        let formats = NSStackView(views: formatButtons)
        formats.spacing = 16
        let note = NSTextField(
            wrappingLabelWithString:
                "Select any matching values in each group. No checkmarks means all values. Rating and file type apply together."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.textSecondary
        let separator = NSBox()
        separator.boxType = .separator
        let reset = NSButton(title: "Clear Filters", target: self, action: #selector(clearFilters))
        reset.bezelStyle = .rounded
        let footer = NSStackView()
        footer.setViews([reset], in: .trailing)
        let sections: [[NSView]] = [
            [heading], [label("Sort by"), sortTrack], [label("Direction"), directionTrack],
            [label("Rating"), ratings], [label("File type"), formats], [note], [separator, footer],
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        for views in sections {
            let section = NSStackView(views: views)
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = 7
            stack.addArrangedSubview(section)
            for view in views + [section] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        }
        let container = NSView()
        pin(stack, in: container, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
        container.widthAnchor.constraint(equalToConstant: 330).isActive = true
        let controller = NSViewController()
        controller.view = container
        browsePopover.contentViewController = controller
        browsePopover.behavior = .transient
        browsePopover.contentSize = container.fittingSize
        updateSortControls()
    }

    @objc private func showBrowse() {
        if browsePopover.isShown {
            browsePopover.performClose(nil)
        } else {
            // Toolbar overflow detaches the button; anchor its popover inside the window in that case.
            guard let anchor = browse.window == nil ? window?.contentView : browse else { return }
            let bounds =
                anchor === browse
                ? browse.bounds : NSRect(x: anchor.bounds.maxX - 20, y: anchor.bounds.maxY - 1, width: 1, height: 1)
            browsePopover.show(relativeTo: bounds, of: anchor, preferredEdge: .minY)
        }
    }

    @objc private func clearFilters() {
        for button in ratingButtons + formatButtons { button.state = .off }
        filtersChanged()
    }

    var canTrashCurrentImage: Bool {
        !galleryVisible && session.selectedURL != nil && canvas.image != nil && !canvas.isLoading && !trashInProgress
            && window?.isVisible == true && window?.attachedSheet == nil
    }

    @objc func trashCurrentImage() {
        guard canTrashCurrentImage, let window, let url = session.selectedURL,
            let access = url == openedURL ? fileAccess : folderAccess
        else { return }
        let generation = session.generation
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = "You can put it back from the Trash in Finder."
        alert.alertStyle = .warning
        // The first button is the default, so Return cancels.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Move to Trash")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.updateStatus() }
            guard response == .alertSecondButtonReturn,
                self.session.generation == generation, self.session.selectedURL == url
            else { return }
            self.trashImage(at: url, access: access, generation: generation)
        }
    }

    private func trashImage(at url: URL, access: FileAccess, generation: Int) {
        trashInProgress = true
        prefetchTask?.cancel()
        updateStatus()
        let move = moveToTrash
        Task { [weak self] in
            let result: Result<Void, Error>
            do {
                try await move(url, access)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.trashInProgress = false
            guard self.session.generation == generation else {
                self.updateStatus()
                return
            }
            switch result {
            case .success:
                // A scan started before the move completed must not reintroduce the removed entry.
                self.worker.cancelAllOperations()
                let wasSelected = self.session.selectedURL == url
                self.session.removeEntry(at: url)
                if self.folderAccess == nil {
                    self.changeMonitor = nil
                    self.automaticRefreshTask?.cancel()
                }
                if wasSelected {
                    self.canvas.image = nil
                    self.loadSelection()
                }
                self.discoverFolder()
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "Could not move “\(url.lastPathComponent)” to the Trash"
                alert.informativeText = error.localizedDescription
                if let window = self.window {
                    alert.beginSheetModal(for: window) { [weak self] _ in self?.updateStatus() }
                }
            }
            self.updateStatus()
        }
    }

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        changeMonitor = nil
        automaticRefreshTask?.cancel()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        browsePopover.performClose(nil)
        setGalleryVisible(false)
        folderPanel?.cancel(nil)
        folderPanel = nil
        worker.cancelAllOperations()
        scanning = false
        manualRefresh = false
        loadTask?.cancel()
        prefetchTask?.cancel()
        navigationDirection = 1
        request += 1
        cacheGeneration += 1
        openedURL = url
        fileAccess = FileAccess(url: url)
        let entry = ImageFormat(url: url).map { ImageEntry(url: url, format: $0) }
        session.open(entry)
        for button in ratingButtons + formatButtons { button.state = .off }
        info.state = .off
        info.setLabel("Show metadata")
        metadataPanel.isHidden = true
        canvas.resetZoom()
        metadataPanel.clear()
        currentRating = nil
        status.stringValue = ""
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if folderAccess?.url.standardizedFileURL != parent { folderAccess = nil }
        do { _ = try ImageLoader.validateFormat(url) } catch {
            canvas.image = nil
            canvas.showMessage(
                "Can’t open this file.", detail: error.localizedDescription,
                actionTitle: "Open Another Image", action: { [weak self] in self?.openPanel() })
            updateStatus()
            return
        }
        loadSelection()
        startMonitoring()
        if folderAccess?.url.standardizedFileURL == parent {
            discoverFolder()
        } else {
            folderAccess = nil
            // Yield so the directly opened image can display while the permission sheet is shown.
            let generation = session.generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session.generation == generation else { return }
                self.requestFolder(parent, generation: generation)
            }
        }
    }

    private func requestFolder(_ parent: URL, generation: Int, showGallery: Bool = false) {
        guard let window, folderPanel == nil else { return }
        let panel = NSOpenPanel()
        folderPanel = panel
        panel.title = "Allow Folder Navigation"
        panel.message =
            "Choose the image's containing folder to browse its images. Cancel to view only the opened image."
        panel.prompt = "Allow Folder"
        panel.directoryURL = parent
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if self.folderPanel === panel { self.folderPanel = nil }
            defer { self.updateStatus() }
            guard self.session.generation == generation, response == .OK, let url = panel.url else { return }
            self.useAuthorizedFolder(FileAccess(url: url))
            if showGallery, self.folderAccess?.url.standardizedFileURL == parent {
                self.setGalleryVisible(true)
            }
        }
    }

    // The caller supplies the user's grant (or an owned test directory in the unsandboxed harness).
    func useAuthorizedFolder(_ access: FileAccess) {
        guard let openedURL,
            access.url.standardizedFileURL == openedURL.deletingLastPathComponent().standardizedFileURL
        else {
            status.stringValue = "Choose the containing folder to enable navigation."
            return
        }
        folderAccess = access
        startMonitoring()
        discoverFolder()
        updateStatus()
    }

    @objc func allowFolderNavigation() {
        guard let openedURL else { return }
        requestFolder(openedURL.deletingLastPathComponent().standardizedFileURL, generation: session.generation)
    }

    var canRefresh: Bool {
        openedURL != nil && !trashInProgress && window?.attachedSheet == nil
    }

    @objc func refreshImages() {
        guard canRefresh else { return }
        automaticRefreshTask?.cancel()
        manualRefresh = true
        refreshContents()
    }

    private func refreshContents() {
        worker.cancelAllOperations()
        cacheGeneration += 1
        thumbnailGeneration += 1
        // Bypassing both caches also reloads the poster and background for an unchanged selection.
        posterURL = nil
        backdropURL = nil
        // A single authorized image can become visible again after its embedded rating changes.
        loadSelection(reloadingOpenedImage: folderAccess == nil && !session.entries.isEmpty)
        discoverFolder()
        updateStatus()
    }

    private func startMonitoring() {
        changeMonitor = nil
        automaticRefreshTask?.cancel()
        guard automaticallyRefresh, let fileAccess else { return }
        let generation = session.generation
        changeMonitor = ImageChangeMonitor(fileAccess: fileAccess, folderAccess: folderAccess) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.session.generation == generation, self.changeMonitor != nil else { return }
                self.automaticRefreshTask?.cancel()
                self.automaticRefreshTask = Task { [weak self] in
                    // Coalesce saves and defer updates while confirmation/permission sheets are open.
                    repeat {
                        do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                        guard let self, self.session.generation == generation else { return }
                        if self.canRefresh {
                            self.refreshContents()
                            return
                        }
                    } while !Task.isCancelled
                }
            }
        }
    }

    private func discoverFolder() {
        guard let access = folderAccess else {
            scanning = false
            return
        }
        scanning = true
        scanToken += 1
        let token = scanToken
        let generation = session.generation
        let opened = session.entries.first(where: { $0.url == openedURL })
        let openedAccess = fileAccess
        let discover = discoverImages
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation else { return }
            let result = Result {
                var entries = try discover(access.url, { operation.isCancelled })
                // Keep directly opened hidden files/symlinks, but never resurrect a deleted image.
                if !operation.isCancelled, let opened,
                    !entries.contains(where: { $0.url == opened.url }),
                    FileManager.default.fileExists(atPath: opened.url.path)
                {
                    entries.append((try? ImageLoader.details(at: opened.url).entry) ?? opened)
                }
                return entries
            }
            withExtendedLifetime((access, openedAccess)) {
                let cancelled = operation.isCancelled
                // Posted even when cancelled so the Refresh animation never waits on a scan that will not report.
                _ = Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.scanToken == token { self.scanning = false }
                    guard !cancelled, self.session.generation == generation, self.scanToken == token else {
                        self.updateRefreshIndicator()
                        return
                    }
                    switch result {
                    case .success(let entries):
                        let selected = self.session.selectedURL
                        self.session.replaceEntries(entries)
                        if self.session.selectedURL != selected { self.loadSelection() }
                        self.updateStatus()
                        self.prefetchNeighbor()
                    case .failure:
                        self.updateStatus()
                        self.status.stringValue = "Folder could not be read. Refresh to try again."
                    }
                }
            }
        }
        worker.addOperation(operation)
    }

    private func loadSelection(reloadingOpenedImage: Bool = false) {
        loadTask?.cancel()
        prefetchTask?.cancel()
        request += 1
        guard !galleryVisible else {
            updateStatus()
            return
        }
        let currentRequest = request
        metadataPanel.clear()
        currentRating = nil
        guard let url = session.selectedURL ?? (reloadingOpenedImage ? openedURL : nil) else {
            canvas.image = nil
            window?.title = "Lulo"
            if session.entries.isEmpty {
                canvas.showMessage(
                    "No images remaining.", detail: "Open another image to continue.",
                    actionTitle: "Open Image", action: { [weak self] in self?.openPanel() })
            } else {
                canvas.showMessage(
                    "No images match the current filters.", detail: filterDescription,
                    actionTitle: "Clear Filters", action: { [weak self] in self?.clearFilters() })
            }
            updateStatus()
            return
        }
        canvas.beginLoading()
        window?.title = url.lastPathComponent
        let access = url == openedURL ? fileAccess : folderAccess
        let generation = cacheGeneration
        let store = imageStore
        loadTask = Task { [weak self] in
            do {
                let loaded = try await store.load(at: url, generation: generation, access: access) { [weak self] in
                    _ = Task { @MainActor [weak self] in
                        guard let self, self.request == currentRequest, self.canvas.isLoading else { return }
                        self.canvas.showLoading(filename: url.lastPathComponent)
                    }
                }
                guard !Task.isCancelled, let self, self.request == currentRequest else { return }
                self.session.updateEntry(loaded.details.entry)
                guard self.session.selectedURL == url else {
                    self.loadSelection()
                    return
                }
                self.canvas.image = loaded.image
                self.canvas.setAccessibilityLabel(url.lastPathComponent)
                self.metadataPanel.show(loaded.details)
                self.currentRating = loaded.details.entry.rating
                self.updateStatus()
                self.prefetchNeighbor()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.request == currentRequest else { return }
                self.canvas.image = nil
                self.canvas.showMessage(
                    "Can’t open this file.", detail: error.localizedDescription,
                    actionTitle: "Open Another Image", action: { [weak self] in self?.openPanel() })
                self.updateStatus()
            }
        }
        updateStatus()
    }

    private func prefetchNeighbor() {
        prefetchTask?.cancel()
        guard !galleryVisible, canvas.image != nil, !canvas.isLoading, session.visibleEntries.count > 1 else { return }
        var neighbor = session
        neighbor.navigate(navigationDirection)
        guard let url = neighbor.selectedURL, url != session.selectedURL else { return }
        let access = url == openedURL ? fileAccess : folderAccess
        guard let access else { return }
        let generation = cacheGeneration
        let store = imageStore
        // One likely next image shares the serial decoder; cancelled queued work is skipped.
        // A prefetch failure is presented only if the user actually selects that file.
        prefetchTask = Task(priority: .utility) {
            _ = try? await store.load(at: url, generation: generation, access: access)
        }
    }

    private func grant(for url: URL) -> FileAccess? {
        url == openedURL ? fileAccess : folderAccess
    }

    /// Checked values in rating/type order, as listed in the status line and the no-match message.
    private var filterDescription: String {
        let groups = [ratingButtons, formatButtons].map { $0.filter { $0.state == .on }.map(\.title) }
        return groups.filter { !$0.isEmpty }.map { $0.joined(separator: ", ") }.joined(separator: " · ")
    }

    private func updateStatus() {
        let entries = session.visibleEntries
        galleryButton.isEnabled = openedURL != nil
        info.isEnabled = !galleryVisible
        refresh.isEnabled = canRefresh
        ratingChip.rating = galleryVisible || canvas.image == nil || canvas.isLoading ? nil : currentRating
        if galleryVisible, let folderAccess {
            gallery.update(
                entries: entries, selectedURL: session.selectedURL, totalCount: session.entries.count,
                sort: session.preferences.sort, folderAccess: folderAccess, fileAccess: fileAccess,
                generation: thumbnailGeneration)
            gallery.emptyState.show(
                "No images match the current filters.", detail: filterDescription, actionTitle: "Clear Filters",
                action: { [weak self] in self?.clearFilters() })
            window?.title = folderAccess.url.lastPathComponent
        }
        if let index = entries.firstIndex(where: { $0.url == session.selectedURL }) {
            status.stringValue = "\(index + 1) of \(entries.count)"
        } else {
            status.stringValue = openedURL == nil ? "JPEG · PNG · HEIF" : "\(entries.count) images"
        }
        if changeMonitor?.isActive == false {
            status.stringValue += " · Automatic refresh unavailable; use Refresh"
        }
        previous.isEnabled = !entries.isEmpty
        next.isEnabled = !entries.isEmpty
        trash.isEnabled = canTrashCurrentImage
        let filters = filterDescription
        filterSummary.stringValue = filters.isEmpty ? "" : "Filtered by " + filters
        filterSummary.toolTip = filterSummary.stringValue
        let count = session.filter.activeCount
        badge.count = count
        browse.setLabel(count == 0 ? "Sort & Filter" : "Sort & Filter, \(count) active filter\(count == 1 ? "" : "s")")
        updateZoomControls()
        updateChrome()
        updateRefreshIndicator()
        updatePoster()
        updateBackdropImage()
    }

    private func updateZoomControls() {
        fitButton.state = canvas.zoom.mode == .fit ? .on : .off
        actualSizeButton.state = canvas.zoom.mode == .actualSize ? .on : .off
        zoomLabel.stringValue = galleryVisible ? "" : canvas.zoomDescription
    }

    /// Mode- and width-dependent chrome: the breadcrumb, display capsule contents, and narrow-window variants.
    private func updateChrome() {
        let width = window?.frame.width ?? 1000
        let compact = width < 900
        breadcrumb.update(
            folderURL: folderAccess?.url, fileURL: openedURL == nil ? nil : session.selectedURL ?? openedURL,
            galleryVisible: galleryVisible, compact: width < 1000)
        fitButton.isHidden = galleryVisible
        actualSizeButton.isHidden = galleryVisible
        for view in [rowsButton, previewButton, layoutDivider, sizeSlider] { view.isHidden = !galleryVisible }
        smallerButton.isHidden = !galleryVisible || compact
        largerButton.isHidden = !galleryVisible || compact
        sliderWidth?.constant = compact ? 64 : 92
        gallery.isCompact = compact
        // Measured unified-toolbar geometry: the first item starts 91 points from the left edge, the last ends
        // 13 points from the right, and items are about 10 points apart.
        let capsuleWidth = capsules.values.reduce(0) { $0 + $1.fittingSize.width + 10 }
        breadcrumb.maximumWidth = max(40, width - 91 - 13 - capsuleWidth - 10)
    }

    private func updateRefreshIndicator() {
        if manualRefresh && !scanning && !canvas.isLoading { manualRefresh = false }
        let animate = manualRefresh && !Theme.reduceMotion
        if animate, refreshTimer == nil {
            // Eight steps per 0.8-second turn, like a spinning progress indicator.
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
                // Invalidated here rather than inside the main-actor block, which cannot take the timer.
                guard let self else {
                    timer.invalidate()
                    return
                }
                MainActor.assumeIsolated {
                    // Reduce Motion can be turned on mid-refresh; the next tick stops the wheel.
                    if Theme.reduceMotion {
                        self.updateRefreshIndicator()
                        return
                    }
                    self.refreshPhase = (self.refreshPhase + 1) % 8
                    self.refresh.glyph = Theme.refreshGlyph(phase: self.refreshPhase)
                }
            }
            // Common modes keep the wheel turning while a menu or slider is tracking the pointer.
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
        } else if !animate, refreshTimer != nil {
            refreshTimer?.invalidate()
            refreshTimer = nil
            refreshPhase = 0
            refresh.glyph = Theme.refreshGlyph(phase: 0)
        }
    }

    /// Preview shows the cached thumbnail at once, then the full image and its caption details.
    private func updatePoster() {
        let url = galleryVisible && session.preferences.galleryLayout == .preview ? session.selectedURL : nil
        guard url != posterURL else { return }
        posterURL = url
        posterTask?.cancel()
        gallery.poster.setImage(nil, details: nil)
        guard let url, let access = grant(for: url) else { return }
        let loader = thumbnails
        let store = imageStore
        let thumbnailGeneration = self.thumbnailGeneration
        let cacheGeneration = self.cacheGeneration
        posterTask = Task { [weak self] in
            if let thumbnail = try? await loader.load(at: url, access: access, generation: thumbnailGeneration) {
                guard !Task.isCancelled, let self, self.posterURL == url else { return }
                self.gallery.poster.setImage(thumbnail.image, details: nil)
            }
            guard let loaded = try? await store.load(at: url, generation: cacheGeneration, access: access),
                !Task.isCancelled, let self, self.posterURL == url
            else { return }
            self.gallery.poster.setImage(loaded.image, details: loaded.details)
        }
    }

    /// The blurred background follows the viewer's image or the gallery's selection.
    private func updateBackdropImage() {
        let url = session.preferences.blurredBackground ? session.selectedURL : nil
        guard url != backdropURL else { return }
        backdropURL = url
        backdropTask?.cancel()
        guard let url, let access = grant(for: url) else {
            if session.preferences.blurredBackground { backdrop.show(nil, animated: true) }
            return
        }
        let loader = thumbnails
        let generation = thumbnailGeneration
        backdropTask = Task { [weak self] in
            let image = try? await loader.backdrop(at: url, access: access, generation: generation)
            guard !Task.isCancelled, let self, self.backdropURL == url else { return }
            self.backdrop.show(image, animated: true)
        }
    }

    private func applyBackground(animated: Bool) {
        let blurred = session.preferences.blurredBackground
        blurButton.state = blurred ? .on : .off
        backdrop.setBlurred(blurred, animated: animated)
        // Over the blur, secondary text would lose contrast, so status and gallery captions use primary text.
        status.textColor = blurred ? Theme.textPrimary : Theme.textSecondary
        zoomLabel.textColor = status.textColor
        gallery.emphasizesText = blurred
        updateBackdropImage()
    }

    private func navigate(_ delta: Int) {
        guard session.selectedURL != nil else { return }
        navigationDirection = delta < 0 ? -1 : 1
        session.navigate(delta)
        loadSelection()
        if galleryVisible { gallery.focusSelection() }
    }

    @objc func previousImage() { navigate(-1) }
    @objc func nextImage() { navigate(1) }

    @objc private func viewingModeChanged(_ sender: NSButton) {
        canvas.resetZoom(to: sender === actualSizeButton ? .actualSize : .fit)
    }

    private func updateSortControls() {
        for (index, button) in sortButtons.enumerated() {
            button.state = SortMethod.allCases[index] == session.preferences.sort ? .on : .off
        }
        directionButtons.first?.state = session.preferences.ascending ? .on : .off
        directionButtons.last?.state = session.preferences.ascending ? .off : .on
    }

    @objc private func sortChanged(_ sender: NSButton) {
        if let index = sortButtons.firstIndex(where: { $0 === sender }) {
            session.preferences.sort = SortMethod.allCases[index]
        } else {
            session.preferences.ascending = sender === directionButtons.first
        }
        session.preferences.save(to: .standard)
        updateSortControls()
        updateStatus()
        prefetchNeighbor()
    }

    @objc private func filtersChanged() {
        session.filter = ImageFilter(
            ratings: Set(ratingButtons.indices.filter { ratingButtons[$0].state == .on }),
            formats: Set(
                ImageFormat.allCases.enumerated().compactMap { index, format in
                    formatButtons[index].state == .on ? format : nil
                }))
        let previous = session.selectedURL
        session.reconcileSelection()
        if session.selectedURL != previous { loadSelection() }
        updateStatus()
        prefetchNeighbor()
    }

    @objc private func galleryLayoutChanged(_ sender: NSButton) {
        setGalleryLayout(sender === previewButton ? .preview : .rows)
    }

    @objc func showRows() { setGalleryLayout(.rows) }
    @objc func showPreview() { setGalleryLayout(.preview) }

    /// Choosing a layout from the image view also opens Gallery, like Finder's View menu.
    private func setGalleryLayout(_ layout: GalleryLayout) {
        browsePopover.performClose(nil)
        session.preferences.galleryLayout = layout
        session.preferences.save(to: .standard)
        applyGalleryLayout()
        if !galleryVisible { toggleGallery() }
        updateStatus()
    }

    @objc func largerThumbnails() { stepThumbnailSize(2) }
    @objc func smallerThumbnails() { stepThumbnailSize(-2) }

    private func stepThumbnailSize(_ steps: Int) {
        guard galleryVisible else { return }
        let layout = session.preferences.galleryLayout
        setThumbnailSize(layout.adjustedSize(session.preferences.thumbnailSize(for: layout), steps: steps))
    }

    @objc private func sizeSliderChanged() { setThumbnailSize(sizeSlider.doubleValue) }

    private func setThumbnailSize(_ size: Double) {
        let layout = session.preferences.galleryLayout
        session.preferences.setThumbnailSize(size, for: layout)
        session.preferences.save(to: .standard)
        applyGalleryLayout()
    }

    private func applyGalleryLayout() {
        let layout = session.preferences.galleryLayout
        let size = session.preferences.thumbnailSize(for: layout)
        rowsButton.state = layout == .rows ? .on : .off
        previewButton.state = layout == .preview ? .on : .off
        sizeSlider.layout = layout
        sizeSlider.minValue = layout.sizeRange.lowerBound
        sizeSlider.maxValue = layout.sizeRange.upperBound
        sizeSlider.doubleValue = size
        let sizeLabel = layout == .rows ? "Row height" : "Thumbnail size"
        sizeSlider.setAccessibilityLabel(sizeLabel)
        sizeSlider.toolTip = sizeLabel
        smallerButton.isEnabled = size > layout.sizeRange.lowerBound
        largerButton.isEnabled = size < layout.sizeRange.upperBound
        gallery.setLayout(layout, size: size)
        updatePoster()
    }

    @objc func toggleBlurredBackground() {
        session.preferences.blurredBackground.toggle()
        session.preferences.save(to: .standard)
        applyBackground(animated: true)
    }

    @objc func toggleSidebar() {
        guard !galleryVisible else { return }
        session.sidebarVisible.toggle()
        info.state = session.sidebarVisible ? .on : .off
        info.setLabel(session.sidebarVisible ? "Hide metadata" : "Show metadata")
        metadataPanel.isHidden = !session.sidebarVisible
    }

    @objc func toggleGallery() {
        guard let openedURL else { return }
        let parent = openedURL.deletingLastPathComponent().standardizedFileURL
        guard folderAccess?.url.standardizedFileURL == parent else {
            galleryButton.state = .off
            requestFolder(parent, generation: session.generation, showGallery: true)
            return
        }
        setGalleryVisible(!galleryVisible)
        if !galleryVisible { loadSelection() }
    }

    private func showSelectedImage() {
        guard galleryVisible, session.selectedURL != nil else { return }
        setGalleryVisible(false)
        loadSelection()
    }

    private func setGalleryVisible(_ visible: Bool) {
        galleryVisible = visible
        galleryButton.state = visible ? .on : .off
        galleryButton.setLabel(visible ? "Return to image" : "Show gallery")
        canvas.isHidden = visible
        gallery.isHidden = !visible
        metadataPanel.isHidden = visible || !session.sidebarVisible
        if visible {
            canvas.resetZoom()
            loadTask?.cancel()
            prefetchTask?.cancel()
            request += 1
        } else {
            gallery.clear()
        }
        updateStatus()
        if visible {
            gallery.focusSelection()
        } else {
            window?.makeFirstResponder(canvas)
        }
    }
}

extension ViewerController: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) { updateChrome() }

    /// Sheet completion handlers can run while `attachedSheet` is still set, leaving Refresh and Trash disabled.
    func windowDidEndSheet(_ notification: Notification) { updateStatus() }

    func windowWillClose(_ notification: Notification) {
        manualRefresh = false
        updateRefreshIndicator()
    }
}

extension NSToolbarItem.Identifier {
    static let breadcrumb = Self("Breadcrumb")
    static let library = Self("Library")
    static let navigation = Self("Navigation")
    static let display = Self("Display")
    static let inspect = Self("Inspect")
}

extension ViewerController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.breadcrumb, .flexibleSpace, .library, .navigation, .display, .inspect]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.visibilityPriority = .high
        defer { capsules[identifier] = item.view as? CapsuleView }
        switch identifier {
        case .breadcrumb:
            item.label = "Location"
            item.view = breadcrumb
            item.visibilityPriority = .low
        case .library:
            item.label = "Gallery, Open, Refresh"
            item.view = CapsuleView([galleryButton, openButton, refresh])
        case .navigation:
            item.label = "Previous and Next"
            item.view = CapsuleView([previous, next])
        case .display:
            item.label = "Display"
            item.view = CapsuleView([
                fitButton, actualSizeButton, rowsButton, previewButton, layoutDivider, smallerButton, sizeSlider,
                largerButton, backgroundDivider, blurButton,
            ])
        case .inspect:
            item.label = "Sort & Filter, Metadata, Trash"
            item.view = CapsuleView([browse, info, trash])
        default: return nil
        }
        return item
    }
}
