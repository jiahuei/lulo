import AppKit
import LuloCore
import LuloImaging
import UniformTypeIdentifiers

@MainActor
final class ViewerController: NSWindowController, NSWindowDelegate {
    private var session = ViewingSession(preferences: Preferences(defaults: .standard))
    private let canvas = ImageCanvas()
    private let thumbnailLoader = ThumbnailLoader()
    private lazy var gallery = GalleryView(loader: thumbnailLoader)
    private let galleryButton = CapsuleButton()
    private var galleryVisible = false
    private let metadata = MetadataTextView()
    private let sidebar = NSScrollView()
    private let display = CapsuleSegments()
    private let sorting = CapsuleSegments()
    private let direction = CapsuleSegments()
    private var ratingButtons: [NSButton] = []
    private var formatButtons: [NSButton] = []
    private let info = CapsuleButton()
    private let browse = CapsuleButton()
    private let previous = CapsuleButton()
    private let next = CapsuleButton()
    private let trash = CapsuleButton()
    private let refresh = CapsuleButton()
    private let browsePopover = NSPopover()
    private let filterSummary = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let rating = RatingChip()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let metadataPanel = NSView()
    private let breadcrumb = BreadcrumbView()
    private let background = ViewerBackground()
    private let backgroundRenderer = BackgroundRenderer()
    private let blurred = CapsuleButton()
    private let galleryLayout = CapsuleSegments()
    private let sizeSlider = ThumbnailSizeSlider()
    private let smaller = CapsuleButton()
    private let larger = CapsuleButton()
    private let refreshSpinner = NSProgressIndicator()
    private let refreshGlyph = refreshWheel()
    private var sliderWidth: NSLayoutConstraint?
    private var breadcrumbWidth: NSLayoutConstraint?
    private var thumbnailTask: Task<Void, Never>?
    private var posterTask: Task<Void, Never>?
    private var presentationKey = ""
    private var manualRefresh = false
    private var refreshingFolder = false
    private var refreshRequest = 0
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
    private var navigationDirection = 1
    private var request = 0
    private var cacheGeneration = 0
    private var thumbnailGeneration = 0
    private var openedURL: URL?
    private let automaticallyRefresh: Bool
    private var changeMonitor: ImageChangeMonitor?
    private var automaticRefreshTask: Task<Void, Never>?

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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        window.title = "Lulo"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 400)
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ViewerColors.wall
        super.init(window: window)
        window.delegate = self
        worker.maxConcurrentOperationCount = 1
        worker.qualityOfService = .userInitiated
        buildInterface()
        if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible == false { canvas.resetZoom() }
        super.showWindow(sender)
    }

    private func segments(_ control: NSSegmentedControl, title: String, values: [String], action: Selector) {
        control.segmentCount = values.count
        control.trackingMode = .selectOne
        for (index, value) in values.enumerated() {
            control.setLabel(value, forSegment: index)
            control.setToolTip(value, forSegment: index)
        }
        control.setAccessibilityLabel(title)
        control.target = self
        control.action = action
        control.heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    private func buildInterface() {
        guard let window else { return }
        for control in [display, galleryLayout, sorting, direction] { control.segmentDistribution = .fillEqually }
        display.identifier = .init("Display")
        galleryLayout.identifier = .init("GalleryLayout")
        sizeSlider.identifier = .init("ThumbnailSize")
        display.segmentCount = 2
        display.trackingMode = .selectOne
        display.segmentStyle = .texturedRounded
        display.setImage(
            NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Fit to Window"),
            forSegment: 0)
        display.setLabel("100%", forSegment: 1)
        display.setToolTip("Fit to Window", forSegment: 0)
        display.setToolTip("100%", forSegment: 1)
        display.setAccessibilityLabel("Viewing mode")
        display.target = self
        display.action = #selector(viewingModeChanged)
        segments(
            sorting, title: "Sort images by", values: SortMethod.allCases.map(\.rawValue),
            action: #selector(preferencesChanged))
        segments(
            direction, title: "Sort direction", values: ["Ascending", "Descending"],
            action: #selector(preferencesChanged))
        ratingButtons = ["Unrated / 0 Stars", "1 Star", "2 Stars", "3 Stars", "4 Stars", "5 Stars"].map {
            NSButton(checkboxWithTitle: $0, target: self, action: #selector(filtersChanged))
        }
        formatButtons = ImageFormat.allCases.map {
            NSButton(checkboxWithTitle: $0.rawValue, target: self, action: #selector(filtersChanged))
        }
        display.selectedSegment = 0
        sorting.selectedSegment = SortMethod.allCases.firstIndex(of: session.preferences.sort) ?? 0
        direction.selectedSegment = session.preferences.ascending ? 0 : 1
        configureButton(previous, title: "Previous image", symbol: "chevron.left", action: #selector(previousImage))
        configureButton(next, title: "Next image", symbol: "chevron.right", action: #selector(nextImage))
        configureButton(info, title: "Show metadata", symbol: "sidebar.right", action: #selector(toggleSidebar))
        info.setButtonType(.toggle)
        configureButton(trash, title: "Move to Trash", symbol: "trash", action: #selector(trashCurrentImage))
        configureButton(
            refresh, title: "Refresh (⌘R)", symbol: "arrow.clockwise", action: #selector(refreshImages))
        configureButton(
            galleryButton, title: "Show gallery", symbol: "square.grid.2x2", action: #selector(toggleGallery))
        galleryButton.setButtonType(.toggle)
        configureButton(
            browse, title: "Sort & Filter", symbol: "line.3.horizontal.decrease.circle", action: #selector(showBrowse))
        refresh.image = refreshGlyph
        configureButton(
            blurred, title: "Blurred Background", symbol: "drop.halffull", action: #selector(toggleBlurredBackground))
        blurred.setButtonType(.toggle)
        configureButton(
            smaller, title: "Smaller thumbnails", symbol: "square.grid.3x3", action: #selector(smallerThumbnails))
        configureButton(larger, title: "Larger thumbnails", symbol: "square", action: #selector(largerThumbnails))
        galleryLayout.segmentCount = 2
        galleryLayout.trackingMode = .selectOne
        galleryLayout.setImage(
            NSImage(systemSymbolName: "rectangle.grid.1x2", accessibilityDescription: "Rows"), forSegment: 0)
        galleryLayout.setImage(
            NSImage(systemSymbolName: "sidebar.squares.left", accessibilityDescription: "Preview"), forSegment: 1)
        galleryLayout.setToolTip("Rows (⌘1)", forSegment: 0)
        galleryLayout.setToolTip("Preview (⌘2)", forSegment: 1)
        galleryLayout.setAccessibilityLabel("Gallery layout")
        galleryLayout.target = self
        galleryLayout.action = #selector(layoutChanged)
        sizeSlider.isContinuous = true
        sizeSlider.target = self
        sizeSlider.action = #selector(thumbnailSizeChanged)
        breadcrumb.showGallery = { [weak self] in self?.setGalleryVisible(true) }
        refreshSpinner.style = .spinning
        refreshSpinner.controlSize = .small
        refreshSpinner.isDisplayedWhenStopped = false
        refreshSpinner.setAccessibilityLabel("Refreshing images")
        makeBrowsePopover()
        let toolbar = NSToolbar(identifier: "Viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        metadata.isEditable = false
        metadata.isSelectable = true
        metadata.isVerticallyResizable = true
        metadata.isHorizontallyResizable = false
        metadata.textContainerInset = NSSize(width: 20, height: 20)
        metadata.drawsBackground = false
        metadata.autoresizingMask = [.width]
        metadata.textContainer?.widthTracksTextView = true
        metadata.setAccessibilityLabel("Image metadata")
        sidebar.documentView = metadata
        sidebar.hasVerticalScroller = true
        sidebar.drawsBackground = false
        let panel = MaterialPanel(cornerRadius: 18)
        metadataPanel.addSubview(panel)
        panel.addSubview(sidebar)
        panel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        metadataPanel.widthAnchor.constraint(equalToConstant: 314).isActive = true
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: metadataPanel.leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: metadataPanel.trailingAnchor, constant: -14),
            panel.topAnchor.constraint(equalTo: metadataPanel.topAnchor, constant: 10),
            panel.bottomAnchor.constraint(equalTo: metadataPanel.bottomAnchor, constant: -14),
            sidebar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: panel.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        metadataPanel.isHidden = true
        gallery.isHidden = true
        let workspace = NSView()
        for view in [canvas, gallery] {
            view.translatesAutoresizingMaskIntoConstraints = false
            workspace.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: workspace.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: workspace.trailingAnchor),
                view.topAnchor.constraint(equalTo: workspace.topAnchor),
                view.bottomAnchor.constraint(equalTo: workspace.bottomAnchor),
            ])
        }
        let content = NSStackView(views: [workspace, metadataPanel])
        content.orientation = .horizontal
        content.alignment = .top
        content.distribution = .fill
        content.spacing = 0
        workspace.setContentHuggingPriority(.defaultLow, for: .horizontal)

        status.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        status.textColor = .secondaryLabelColor
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        zoomLabel.textColor = ViewerColors.secondary
        zoomLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        filterSummary.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        filterSummary.textColor = ViewerColors.accentText
        filterSummary.lineBreakMode = .byTruncatingTail
        filterSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSView()
        for label in [status, rating, filterSummary, zoomLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(label)
        }
        let root = NSView()
        window.contentView = root
        background.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for view in [content, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 56),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor),
            workspace.heightAnchor.constraint(equalTo: content.heightAnchor),
            metadataPanel.heightAnchor.constraint(equalTo: content.heightAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 34),
            status.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            rating.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 12),
            rating.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            filterSummary.leadingAnchor.constraint(equalTo: rating.trailingAnchor, constant: 12),
            filterSummary.trailingAnchor.constraint(lessThanOrEqualTo: zoomLabel.leadingAnchor, constant: -12),
            zoomLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            zoomLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            filterSummary.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        canvas.zoomChanged = { [weak self] in self?.updateZoomStatus() }
        canvas.navigate = { [weak self] delta in self?.navigate(delta) }
        canvas.modeChanged = { [weak self] mode in self?.display.selectedSegment = mode == .fit ? 0 : 1 }
        gallery.selectionChanged = { [weak self] url in
            guard let self else { return }
            self.session.select(url)
            self.updateStatus()
        }
        gallery.openSelection = { [weak self] in self?.showSelectedImage() }
        gallery.clearFilters = { [weak self] in self?.clearFilters() }
        canvas.resetZoom()
        canvas.showMessage(
            "Open an image.", detail: "View JPEG, PNG, and HEIF images.",
            actionTitle: "Open Image…", action: { [weak self] in self?.openPanel() })
        updateStatus()
        window.makeFirstResponder(canvas)
    }

    private func configureButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        let identifiers = [
            "Show gallery": "Gallery", "Previous image": "Previous", "Next image": "Next",
            "Show metadata": "Metadata", "Move to Trash": "Trash", "Refresh (⌘R)": "Refresh", "Sort & Filter": "Browse",
        ]
        button.identifier = .init(identifiers[title] ?? title)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
    }

    private func makeBrowsePopover() {
        let heading = NSTextField(labelWithString: "Sort & Filter")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let reset = NSButton(title: "Clear Filters", target: self, action: #selector(clearFilters))
        let ratings = NSGridView(views: [
            [ratingButtons[0], ratingButtons[3]],
            [ratingButtons[1], ratingButtons[4]],
            [ratingButtons[2], ratingButtons[5]],
        ])
        ratings.rowSpacing = 8
        ratings.columnSpacing = 12
        ratings.xPlacement = .fill
        ratingButtons[0].widthAnchor.constraint(equalTo: ratingButtons[3].widthAnchor).isActive = true
        let formats = NSStackView(views: formatButtons)
        formats.spacing = 8
        let grid = NSStackView(views: [
            NSTextField(labelWithString: "Sort by"), sorting,
            NSTextField(labelWithString: "Direction"), direction,
            NSTextField(labelWithString: "Rating"), ratings,
            NSTextField(labelWithString: "File type"), formats,
        ])
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 8
        for control in [sorting, direction] {
            control.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        ratings.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        let note = NSTextField(
            wrappingLabelWithString:
                "Select any matching values in each group. No checkmarks means all values. Rating and file type apply together."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, grid, note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 430))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let controller = NSViewController()
        controller.view = container
        browsePopover.contentViewController = controller
        browsePopover.behavior = .transient
        browsePopover.contentSize = NSSize(width: 330, height: 430)
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

    private func showMetadata(_ details: ImageDetails) {
        metadata.dividerLocations = []
        let text = NSMutableAttributedString(
            string: details.entry.url.lastPathComponent + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .bold), .foregroundColor: ViewerColors.primary,
            ])
        if let captured = details.entry.capturedAt {
            text.append(
                NSAttributedString(
                    string: captured.formatted(date: .abbreviated, time: .shortened) + "\n",
                    attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: ViewerColors.secondary]))
        }
        if let stars = details.entry.rating, (1...5).contains(stars) {
            let chip = NSMutableAttributedString(
                string: "★ \(stars)\n",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: ViewerColors.primary,
                ])
            chip.addAttribute(.foregroundColor, value: ViewerColors.star, range: NSRange(location: 0, length: 1))
            text.append(chip)
        }
        for group in details.groups where !group.fields.isEmpty {
            metadata.dividerLocations.append(text.length)
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = text.length == 0 ? 0 : 18
            heading.paragraphSpacing = 8
            text.append(
                NSAttributedString(
                    string: group.name + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                        .foregroundColor: NSColor.labelColor, .paragraphStyle: heading,
                    ]))
            for field in group.fields {
                text.append(
                    NSAttributedString(
                        string: field.name + "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: ViewerColors.tertiary,
                        ]))
                let value = NSMutableParagraphStyle()
                value.paragraphSpacing = 10
                value.lineBreakMode = .byCharWrapping
                text.append(
                    NSAttributedString(
                        string: field.value + "\n",
                        attributes: [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
                            .foregroundColor: ViewerColors.primary,
                            .paragraphStyle: value,
                        ]))
            }
        }
        metadata.textStorage?.setAttributedString(text)
        metadata.scrollToBeginningOfDocument(nil)
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
                alert.messageText = "Could not move “\(url.lastPathComponent)” to Trash"
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
        manualRefresh = false
        refreshingFolder = false
        refreshRequest += 1
        presentationKey = ""
        background.setImages(nil)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        browsePopover.performClose(nil)
        setGalleryVisible(false)
        folderPanel?.cancel(nil)
        folderPanel = nil
        worker.cancelAllOperations()
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
        info.setAccessibilityLabel("Show metadata")
        metadataPanel.isHidden = true
        canvas.resetZoom()
        metadata.string = ""
        rating.stringValue = ""
        status.stringValue = ""
        let parent = url.deletingLastPathComponent().standardizedFileURL
        if folderAccess?.url.standardizedFileURL != parent { folderAccess = nil }
        do { _ = try ImageLoader.validateFormat(url) } catch {
            canvas.image = nil
            canvas.showMessage(
                "Can’t open this file.", detail: error.localizedDescription,
                actionTitle: "Open Another Image…", action: { [weak self] in self?.openPanel() })
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
        refreshRequest += 1
        refreshingFolder = folderAccess != nil
        cacheGeneration += 1
        thumbnailGeneration += 1
        // A single authorized image can become visible again after its embedded rating changes.
        loadSelection(reloadingOpenedImage: folderAccess == nil && !session.entries.isEmpty)
        discoverFolder()
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
        guard let access = folderAccess else { return }
        let generation = session.generation
        let currentRefresh = refreshRequest
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
                guard !operation.isCancelled else { return }
                _ = Task { @MainActor [weak self] in
                    guard let self, self.session.generation == generation, !operation.isCancelled else { return }
                    if self.refreshRequest == currentRefresh { self.refreshingFolder = false }
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
        metadata.string = ""
        rating.stringValue = ""
        guard let url = session.selectedURL ?? (reloadingOpenedImage ? openedURL : nil) else {
            canvas.image = nil
            window?.title = "Lulo"
            if session.entries.isEmpty {
                canvas.showMessage(
                    "No images remaining", detail: "Open another image to continue.",
                    actionTitle: "Open Image…", action: { [weak self] in self?.openPanel() })
            } else {
                canvas.showMessage(
                    "No images match the current filters.", detail: filterSummary.stringValue,
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
                self.showMetadata(loaded.details)
                self.rating.setRating(loaded.details.entry.rating)
                self.updateStatus()
                self.prefetchNeighbor()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.request == currentRequest else { return }
                self.canvas.image = nil
                self.canvas.showMessage(
                    "Can’t open this file.", detail: error.localizedDescription,
                    actionTitle: "Open Another Image…", action: { [weak self] in self?.openPanel() })
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

    private func updateStatus() {
        let entries = session.visibleEntries
        galleryButton.isEnabled = openedURL != nil
        display.isEnabled = !galleryVisible
        info.isEnabled = !galleryVisible
        refresh.isEnabled = canRefresh
        rating.isHidden = galleryVisible || canvas.image == nil || canvas.isLoading || rating.stringValue.isEmpty
        if galleryVisible, let folderAccess {
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
        var filters: [String] = []
        let ratings = ratingButtons.filter { $0.state == .on }.map(\.title)
        let formats = formatButtons.filter { $0.state == .on }.map(\.title)
        if !ratings.isEmpty { filters.append(ratings.joined(separator: ", ")) }
        if !formats.isEmpty { filters.append(formats.joined(separator: ", ")) }
        filterSummary.stringValue = filters.isEmpty ? "" : "Filtered by " + filters.joined(separator: " · ")
        filterSummary.toolTip = filterSummary.stringValue
        let count = session.filter.activeCount
        let browseLabel =
            count == 0 ? "Sort & Filter" : "Sort & Filter, \(count) active \(count == 1 ? "filter" : "filters")"
        browse.badgeCount = count
        browse.toolTip = browseLabel
        browse.setAccessibilityLabel(browseLabel)
        if galleryVisible, let folderAccess {
            gallery.update(
                entries: entries, selectedURL: session.selectedURL, folderAccess: folderAccess,
                fileAccess: fileAccess, generation: thumbnailGeneration, preferences: session.preferences,
                totalCount: session.entries.count, filterSummary: filterSummary.stringValue)
        }
        updatePresentationControls()
        updateSelectedPresentation()
        if manualRefresh && !refreshingFolder && (galleryVisible || !canvas.isLoading) { manualRefresh = false }
        let spinning = manualRefresh && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        refresh.image = spinning ? nil : refreshGlyph
        if spinning { refreshSpinner.startAnimation(nil) } else { refreshSpinner.stopAnimation(nil) }
        updateZoomStatus()
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

    @objc private func viewingModeChanged() {
        canvas.resetZoom(to: display.selectedSegment == 0 ? .fit : .actualSize)
    }

    @objc private func preferencesChanged() {
        session.preferences.sort = SortMethod.allCases[sorting.selectedSegment]
        session.preferences.ascending = direction.selectedSegment == 0
        session.preferences.save(to: .standard)
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
        updateStatus()
        if session.selectedURL != previous || (session.selectedURL == nil && !session.entries.isEmpty) {
            loadSelection()
        }
        prefetchNeighbor()
    }

    @objc func toggleSidebar() {
        guard !galleryVisible else { return }
        session.sidebarVisible.toggle()
        info.state = session.sidebarVisible ? .on : .off
        info.setAccessibilityLabel(session.sidebarVisible ? "Hide metadata" : "Show metadata")
        info.toolTip = session.sidebarVisible ? "Hide metadata" : "Show metadata"
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
        galleryButton.toolTip = visible ? "Return to image" : "Show gallery"
        galleryButton.setAccessibilityLabel(visible ? "Return to image" : "Show gallery")
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

extension ViewerController {
    var isGalleryVisible: Bool { galleryVisible }
    var selectedGalleryLayout: GalleryLayout { session.preferences.galleryLayout }
    var isBlurredBackground: Bool { session.preferences.blurredBackground }

    @objc func showRows() { chooseLayout(.rows) }
    @objc func showPreview() { chooseLayout(.preview) }
    @objc private func layoutChanged() { chooseLayout(galleryLayout.selectedSegment == 0 ? .rows : .preview) }
    private func chooseLayout(_ layout: GalleryLayout) {
        browsePopover.performClose(nil)
        session.preferences.galleryLayout = layout
        session.preferences.save(to: .standard)
        if !galleryVisible {
            toggleGallery()
        } else {
            updateStatus()
            gallery.focusSelection()
        }
    }
    @objc func largerThumbnails() { changeThumbnailSize(2) }
    @objc func smallerThumbnails() { changeThumbnailSize(-2) }
    private func changeThumbnailSize(_ steps: Double) {
        guard galleryVisible else { return }
        let mode = session.preferences.galleryLayout
        saveThumbnailSize(mode.clampedSize(sizeSlider.doubleValue + steps * mode.sizeStep))
    }
    @objc private func thumbnailSizeChanged() {
        let mode = session.preferences.galleryLayout
        let value =
            sizeSlider.keyboardAdjustment
            ? sizeSlider.doubleValue
            : mode.defaultSize + ((sizeSlider.doubleValue - mode.defaultSize) / mode.sizeStep).rounded() * mode.sizeStep
        saveThumbnailSize(mode.clampedSize(value))
    }
    private func saveThumbnailSize(_ value: Double) {
        if session.preferences.galleryLayout == .rows {
            session.preferences.rowsTargetHeight = value
        } else {
            session.preferences.previewTileSize = value
        }
        session.preferences.save(to: .standard)
        updateStatus()
    }
    @objc func toggleBlurredBackground() {
        session.preferences.blurredBackground.toggle()
        session.preferences.save(to: .standard)
        updateStatus()
    }

    private func updatePresentationControls() {
        display.isHidden = galleryVisible
        galleryLayout.isHidden = !galleryVisible
        sizeSlider.isHidden = !galleryVisible
        let width = window?.frame.width ?? 1000
        smaller.isHidden = !galleryVisible || width < 900
        larger.isHidden = smaller.isHidden
        sliderWidth?.constant = width < 900 ? 64 : 92
        let mode = session.preferences.galleryLayout
        galleryLayout.selectedSegment = mode == .rows ? 0 : 1
        sizeSlider.step = mode.sizeStep
        sizeSlider.minValue = mode.sizeRange.lowerBound
        sizeSlider.maxValue = mode.sizeRange.upperBound
        sizeSlider.doubleValue =
            mode == .rows ? session.preferences.rowsTargetHeight : session.preferences.previewTileSize
        sizeSlider.setAccessibilityLabel(mode == .rows ? "Row height" : "Thumbnail size")
        sizeSlider.toolTip = mode == .rows ? "Row height" : "Thumbnail size"
        smaller.isEnabled = sizeSlider.doubleValue > sizeSlider.minValue
        larger.isEnabled = sizeSlider.doubleValue < sizeSlider.maxValue
        blurred.state = session.preferences.blurredBackground ? .on : .off
        background.enabled = session.preferences.blurredBackground
        status.textColor = session.preferences.blurredBackground ? ViewerColors.primary : ViewerColors.secondary
        zoomLabel.textColor = status.textColor
        breadcrumb.update(
            file: session.selectedURL ?? openedURL, authorizedFolder: folderAccess?.url,
            gallery: galleryVisible, windowWidth: width)
        // Leave a compressible title region; all four capsules stay reachable at 720 pt.
        let controlsWidth: CGFloat = galleryVisible ? (width < 900 ? 530 : 622) : 450
        breadcrumbWidth?.constant = max(40, width - controlsWidth - 120)
    }

    private func updateZoomStatus() {
        zoomLabel.isHidden = galleryVisible || canvas.image == nil
        zoomLabel.stringValue = canvas.zoomDescription
    }

    private func updateSelectedPresentation() {
        let preview = galleryVisible && session.preferences.galleryLayout == .preview
        let blur = session.preferences.blurredBackground
        let url = session.selectedURL
        let key = "\(url?.absoluteString ?? "")|\(thumbnailGeneration)|\(cacheGeneration)|\(preview)|\(blur)"
        guard key != presentationKey else { return }
        presentationKey = key
        thumbnailTask?.cancel()
        posterTask?.cancel()
        guard preview || blur, let url, let access = url == openedURL ? fileAccess : folderAccess else {
            if url == nil { background.setImages(nil) }
            return
        }
        let loader = thumbnailLoader
        let renderer = backgroundRenderer
        let generation = thumbnailGeneration
        thumbnailTask = Task { [weak self] in
            do {
                let thumbnail = try await loader.load(at: url, access: access, generation: generation)
                guard !Task.isCancelled, let self, self.presentationKey == key else { return }
                if preview { self.gallery.showPreview(thumbnail.image) }
                if blur {
                    let images = await renderer.render(thumbnail)
                    guard !Task.isCancelled, self.presentationKey == key else { return }
                    self.background.setImages(images)
                }
            } catch {
                guard !Task.isCancelled, let self, self.presentationKey == key else { return }
                if preview { self.gallery.previewFailed() }
                if blur { self.background.setImages(nil) }
            }
        }
        if preview {
            let store = imageStore
            let generation = cacheGeneration
            posterTask = Task { [weak self] in
                do {
                    let loaded = try await store.load(at: url, generation: generation, access: access)
                    guard !Task.isCancelled, let self, self.presentationKey == key else { return }
                    self.gallery.showPreview(loaded.image, details: loaded.details)
                } catch {
                    guard !Task.isCancelled, let self, self.presentationKey == key else { return }
                    self.gallery.previewFailed()
                }
            }
        }
    }

    func windowDidResize(_ notification: Notification) { updatePresentationControls() }
}

extension ViewerController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("Breadcrumb"), .flexibleSpace, .init("Files"), .init("Navigation"), .init("Display"), .init("Actions")]
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
        if identifier.rawValue == "Breadcrumb" {
            breadcrumb.translatesAutoresizingMaskIntoConstraints = false
            breadcrumbWidth = breadcrumb.widthAnchor.constraint(equalToConstant: 200)
            breadcrumbWidth?.isActive = true
            breadcrumb.heightAnchor.constraint(equalToConstant: 34).isActive = true
            item.view = breadcrumb
            item.label = "Current folder and image"
            return item
        }
        let views: [NSView]
        switch identifier.rawValue {
        case "Files":
            let open = CapsuleButton()
            configureButton(open, title: "Open image", symbol: "photo", action: #selector(openPanel))
            views = [galleryButton, open, refresh]
            refreshSpinner.translatesAutoresizingMaskIntoConstraints = false
            refresh.addSubview(refreshSpinner)
            NSLayoutConstraint.activate([
                refreshSpinner.centerXAnchor.constraint(equalTo: refresh.centerXAnchor),
                refreshSpinner.centerYAnchor.constraint(equalTo: refresh.centerYAnchor),
                refreshSpinner.widthAnchor.constraint(equalToConstant: 18),
                refreshSpinner.heightAnchor.constraint(equalToConstant: 18),
            ])
            item.label = "Gallery, Open and Refresh"
        case "Navigation":
            views = [previous, next]
            item.label = "Previous and Next"
        case "Display":
            for control in [display, galleryLayout] {
                control.translatesAutoresizingMaskIntoConstraints = false
                control.widthAnchor.constraint(equalToConstant: 72).isActive = true
                control.heightAnchor.constraint(equalToConstant: 28).isActive = true
            }
            sizeSlider.translatesAutoresizingMaskIntoConstraints = false
            sliderWidth = sizeSlider.widthAnchor.constraint(equalToConstant: 92)
            sliderWidth?.isActive = true
            let sizeDivider = NSBox()
            sizeDivider.boxType = .separator
            sizeDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
            sizeDivider.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let sizeControls = NSStackView(views: [galleryLayout, smaller, sizeSlider, larger])
            sizeControls.spacing = 2
            sizeControls.alignment = .centerY
            views = [display, sizeControls, sizeDivider, blurred]
            // Hiding every child also collapses the gallery-only stack in image mode.
            item.label = "Display"
        case "Actions":
            views = [browse, info, trash]
            item.label = "Sort and Filter, Metadata and Trash"
        default: return nil
        }
        let capsule = MaterialPanel()
        let row = NSStackView(views: views)
        row.spacing = 2
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        capsule.addSubview(row)
        NSLayoutConstraint.activate([
            capsule.heightAnchor.constraint(equalToConstant: 34),
            row.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 3),
            row.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -3),
            row.centerYAnchor.constraint(equalTo: capsule.centerYAnchor),
        ])
        item.view = capsule
        return item
    }
}
