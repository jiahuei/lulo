import AppKit
import LuloCore
import LuloImaging
import UniformTypeIdentifiers

@MainActor
final class ViewerController: NSWindowController {
    private var session = ViewingSession(preferences: Preferences(defaults: .standard))
    private let canvas = ImageCanvas()
    private let gallery = GalleryView()
    private let galleryButton = NSButton()
    private var galleryVisible = false
    private let metadata = NSTextView()
    private let sidebar = NSScrollView()
    private let display = NSPopUpButton()
    private let sorting = NSPopUpButton()
    private let direction = NSPopUpButton()
    private var ratingButtons: [NSButton] = []
    private var formatButtons: [NSButton] = []
    private let info = NSButton()
    private let browse = NSButton()
    private let previous = NSButton()
    private let next = NSButton()
    private let trash = NSButton()
    private let browsePopover = NSPopover()
    private let filterSummary = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
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
    private var openedURL: URL?

    init(
        imageStore: ImageStore = ImageStore(),
        discoverImages: @escaping DiscoverImages = { try ImageLoader.discover(in: $0, isCancelled: $1) },
        moveToTrash: @escaping MoveToTrash = { _ = try await ImageTrash().move(at: $0, access: $1) }
    ) {
        self.imageStore = imageStore
        self.moveToTrash = moveToTrash
        self.discoverImages = discoverImages
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Lulo"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 400)
        window.toolbarStyle = .unified
        super.init(window: window)
        worker.maxConcurrentOperationCount = 1
        worker.qualityOfService = .userInitiated
        buildInterface()
        if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func popup(_ popup: NSPopUpButton, title: String, values: [String], action: Selector) {
        popup.addItems(withTitles: values)
        popup.setAccessibilityLabel(title)
        popup.toolTip = title
        popup.target = self
        popup.action = action
    }

    private func buildInterface() {
        guard let window else { return }
        popup(
            display, title: "Default image zoom", values: DisplayDefault.allCases.map(\.rawValue),
            action: #selector(preferencesChanged))
        popup(
            sorting, title: "Sort images by", values: SortMethod.allCases.map(\.rawValue),
            action: #selector(preferencesChanged))
        popup(
            direction, title: "Sort direction", values: ["Ascending", "Descending"],
            action: #selector(preferencesChanged))
        ratingButtons = ["Unrated / 0 Stars", "1 Star", "2 Stars", "3 Stars", "4 Stars", "5 Stars"].map {
            NSButton(checkboxWithTitle: $0, target: self, action: #selector(filtersChanged))
        }
        formatButtons = ImageFormat.allCases.map {
            NSButton(checkboxWithTitle: $0.rawValue, target: self, action: #selector(filtersChanged))
        }
        display.selectItem(withTitle: session.preferences.display.rawValue)
        sorting.selectItem(withTitle: session.preferences.sort.rawValue)
        direction.selectItem(at: session.preferences.ascending ? 0 : 1)
        configureButton(previous, title: "Previous image", symbol: "chevron.left", action: #selector(previousImage))
        configureButton(next, title: "Next image", symbol: "chevron.right", action: #selector(nextImage))
        configureButton(info, title: "Show metadata", symbol: "sidebar.right", action: #selector(toggleSidebar))
        info.setButtonType(.toggle)
        configureButton(trash, title: "Move to Trash", symbol: "trash", action: #selector(trashCurrentImage))
        configureButton(
            galleryButton, title: "Show gallery", symbol: "square.grid.2x2", action: #selector(toggleGallery))
        galleryButton.title = "Gallery"
        galleryButton.imagePosition = .imageLeading
        galleryButton.setButtonType(.toggle)
        configureButton(
            browse, title: "Sort & Filter", symbol: "line.3.horizontal.decrease", action: #selector(showBrowse))
        browse.title = "Sort & Filter"
        browse.imagePosition = .imageLeading
        makeBrowsePopover()
        let toolbar = NSToolbar(identifier: "Viewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        metadata.isEditable = false
        metadata.isSelectable = true
        metadata.isVerticallyResizable = true
        metadata.isHorizontallyResizable = false
        metadata.textContainerInset = NSSize(width: 16, height: 20)
        metadata.autoresizingMask = [.width]
        metadata.textContainer?.widthTracksTextView = true
        metadata.setAccessibilityLabel("Image metadata")
        sidebar.documentView = metadata
        sidebar.hasVerticalScroller = true
        sidebar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        sidebar.isHidden = true
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
        let content = NSStackView(views: [workspace, sidebar])
        content.orientation = .horizontal
        content.alignment = .top
        content.distribution = .fill
        content.spacing = 0
        workspace.setContentHuggingPriority(.defaultLow, for: .horizontal)

        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        filterSummary.font = .systemFont(ofSize: 11)
        filterSummary.textColor = .secondaryLabelColor
        filterSummary.lineBreakMode = .byTruncatingTail
        filterSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSView()
        for label in [status, filterSummary] {
            label.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(label)
        }
        let root = NSView()
        window.contentView = root
        for view in [content, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: footer.topAnchor),
            workspace.heightAnchor.constraint(equalTo: content.heightAnchor),
            sidebar.heightAnchor.constraint(equalTo: content.heightAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 30),
            status.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            status.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            filterSummary.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 20),
            filterSummary.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
            filterSummary.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        ])
        canvas.navigate = { [weak self] delta in self?.navigate(delta) }
        gallery.selectionChanged = { [weak self] url in
            guard let self else { return }
            self.session.select(url)
            self.updateStatus()
        }
        gallery.openSelection = { [weak self] in self?.showSelectedImage() }
        gallery.clearFilters = { [weak self] in self?.clearFilters() }
        canvas.displayDefault = session.preferences.display
        canvas.resetZoom()
        canvas.showMessage(
            "Open an image", detail: "View JPEG, PNG, and HEIF images.",
            actionTitle: "Open Image…", action: { [weak self] in self?.openPanel() })
        updateStatus()
        window.makeFirstResponder(canvas)
    }

    private func configureButton(_ button: NSButton, title: String, symbol: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
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
            [ratingButtons[0], ratingButtons[1]],
            [ratingButtons[2], ratingButtons[3]],
            [ratingButtons[4], ratingButtons[5]],
        ])
        ratings.rowSpacing = 8
        ratings.columnSpacing = 12
        let formats = NSStackView(views: formatButtons)
        formats.spacing = 8
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Sort by"), sorting],
            [NSTextField(labelWithString: "Direction"), direction],
            [NSTextField(labelWithString: "Rating"), ratings],
            [NSTextField(labelWithString: "File type"), formats],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 68
        grid.column(at: 1).xPlacement = .fill
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 320))
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let controller = NSViewController()
        controller.view = container
        browsePopover.contentViewController = controller
        browsePopover.behavior = .transient
        browsePopover.contentSize = NSSize(width: 380, height: 320)
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
        let text = NSMutableAttributedString(string: "")
        for group in details.groups where !group.fields.isEmpty {
            let heading = NSMutableParagraphStyle()
            heading.paragraphSpacingBefore = text.length == 0 ? 0 : 18
            heading.paragraphSpacing = 8
            text.append(
                NSAttributedString(
                    string: group.name + "\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: NSColor.labelColor, .paragraphStyle: heading,
                    ]))
            for field in group.fields {
                text.append(
                    NSAttributedString(
                        string: field.name + "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                        ]))
                let value = NSMutableParagraphStyle()
                value.paragraphSpacing = 10
                value.lineBreakMode = .byCharWrapping
                text.append(
                    NSAttributedString(
                        string: field.value + "\n",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
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
        alert.messageText = "Move “\(url.lastPathComponent)” to Trash?"
        alert.informativeText = "You can recover this image from the Trash in Finder."
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
        openedURL = url
        fileAccess = FileAccess(url: url)
        let entry = ImageFormat(url: url).map { ImageEntry(url: url, format: $0) }
        session.open(entry)
        for button in ratingButtons + formatButtons { button.state = .off }
        info.state = .off
        info.setAccessibilityLabel("Show metadata")
        sidebar.isHidden = true
        canvas.displayDefault = session.preferences.display
        metadata.string = ""
        status.stringValue = ""
        do { _ = try ImageLoader.validateFormat(url) } catch {
            canvas.image = nil
            canvas.showMessage(
                "Cannot open this image", detail: error.localizedDescription,
                actionTitle: "Open Another Image…", action: { [weak self] in self?.openPanel() })
            updateStatus()
            return
        }
        loadSelection()
        let parent = url.deletingLastPathComponent().standardizedFileURL
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
        discoverFolder()
    }

    @objc func allowFolderNavigation() {
        guard let openedURL else { return }
        requestFolder(openedURL.deletingLastPathComponent().standardizedFileURL, generation: session.generation)
    }

    private func discoverFolder() {
        guard let access = folderAccess else { return }
        let generation = session.generation
        let discover = discoverImages
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation else { return }
            let result = Result { try discover(access.url, { operation.isCancelled }) }
            withExtendedLifetime(access) {
                guard !operation.isCancelled else { return }
                _ = Task { @MainActor [weak self] in
                    guard let self, self.session.generation == generation, !operation.isCancelled else { return }
                    switch result {
                    case .success(var entries):
                        if let opened = self.session.entries.first(where: { $0.url == self.openedURL }),
                            !entries.contains(where: { $0.url == opened.url })
                        {
                            entries.append(opened)
                        }
                        let selected = self.session.selectedURL
                        self.session.replaceEntries(entries)
                        if self.session.selectedURL != selected { self.loadSelection() }
                        self.updateStatus()
                        self.prefetchNeighbor()
                    case .failure:
                        self.status.stringValue = "Folder could not be read. The opened image is still available."
                    }
                }
            }
        }
        worker.addOperation(operation)
    }

    private func loadSelection() {
        loadTask?.cancel()
        prefetchTask?.cancel()
        request += 1
        guard !galleryVisible else {
            updateStatus()
            return
        }
        let currentRequest = request
        metadata.string = ""
        guard let url = session.selectedURL else {
            canvas.image = nil
            window?.title = "Lulo"
            if session.entries.isEmpty {
                canvas.showMessage(
                    "No images remaining", detail: "Open another image to continue.",
                    actionTitle: "Open Image…", action: { [weak self] in self?.openPanel() })
            } else {
                canvas.showMessage(
                    "No matching images", detail: "No images match the current filters.",
                    actionTitle: "Clear Filters", action: { [weak self] in self?.clearFilters() })
            }
            updateStatus()
            return
        }
        canvas.beginLoading()
        window?.title = url.lastPathComponent
        let access = url == openedURL ? fileAccess : folderAccess
        let generation = session.generation
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
                self.canvas.resetZoom()
                self.canvas.setAccessibilityLabel(url.lastPathComponent)
                self.showMetadata(loaded.details)
                self.updateStatus()
                self.prefetchNeighbor()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.request == currentRequest else { return }
                self.canvas.image = nil
                self.canvas.showMessage(
                    "Cannot display this image", detail: error.localizedDescription,
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
        let generation = session.generation
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
        if galleryVisible, let folderAccess {
            gallery.update(
                entries: entries, selectedURL: session.selectedURL, folderAccess: folderAccess, fileAccess: fileAccess)
            window?.title = folderAccess.url.lastPathComponent
        }
        if let index = entries.firstIndex(where: { $0.url == session.selectedURL }) {
            status.stringValue = "\(index + 1) of \(entries.count)"
        } else {
            status.stringValue = openedURL == nil ? "JPEG · PNG · HEIF" : "\(entries.count) images"
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
        browse.title = filters.isEmpty ? "Sort & Filter" : "Sort & Filter (\(filters.count))"
        browse.setAccessibilityLabel(
            filters.isEmpty ? "Sort & Filter" : "Sort & Filter, \(filters.count) active filters")
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

    @objc private func preferencesChanged() {
        let oldDisplay = session.preferences.display
        session.preferences = Preferences(
            display: DisplayDefault.allCases[display.indexOfSelectedItem],
            sort: SortMethod.allCases[sorting.indexOfSelectedItem],
            ascending: direction.indexOfSelectedItem == 0)
        session.preferences.save(to: .standard)
        canvas.displayDefault = session.preferences.display
        if oldDisplay != session.preferences.display { canvas.resetZoom() }
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

    @objc func toggleSidebar() {
        guard !galleryVisible else { return }
        session.sidebarVisible.toggle()
        info.state = session.sidebarVisible ? .on : .off
        info.setAccessibilityLabel(session.sidebarVisible ? "Hide metadata" : "Show metadata")
        sidebar.isHidden = !session.sidebarVisible
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
        sidebar.isHidden = visible || !session.sidebarVisible
        if visible {
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

extension ViewerController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .init("Open"), .init("Gallery"), .init("Previous"), .init("Next"), .flexibleSpace, .init("Display"),
            .init("Browse"), .init("Metadata"), .init("Trash"),
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "Open":
            item.label = "Open Image"
            let button = NSButton(title: "Open", target: self, action: #selector(openPanel))
            button.bezelStyle = .texturedRounded
            button.toolTip = "Open image"
            item.view = button
        case "Previous":
            item.label = "Previous Image"
            item.view = previous
        case "Gallery":
            item.label = "Gallery"
            item.view = galleryButton
            item.visibilityPriority = .high
        case "Next":
            item.label = "Next Image"
            item.view = next
        case "Display":
            item.label = "Default Zoom"
            item.view = display
        case "Browse":
            item.label = "Sort & Filter"
            item.view = browse
            item.visibilityPriority = .high
        case "Trash":
            item.label = "Move to Trash"
            item.view = trash
        case "Metadata":
            item.label = "Metadata"
            item.view = info
        default: return nil
        }
        return item
    }
}
