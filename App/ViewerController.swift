import AppKit
import LuloCore
import LuloImaging
import UniformTypeIdentifiers

@MainActor
final class ViewerController: NSWindowController {
    private var session = ViewingSession(preferences: Preferences(defaults: .standard))
    private let canvas = ImageCanvas()
    private let metadata = NSTextView()
    private let sidebar = NSScrollView()
    private let display = NSPopUpButton()
    private let sorting = NSPopUpButton()
    private let direction = NSPopUpButton()
    private let rating = NSPopUpButton()
    private let format = NSPopUpButton()
    private let info = NSButton()
    private let browse = NSButton()
    private let previous = NSButton()
    private let next = NSButton()
    private let browsePopover = NSPopover()
    private let filterSummary = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    typealias DiscoverImages = @Sendable (URL, @Sendable () -> Bool) throws -> [ImageEntry]
    private let discoverImages: DiscoverImages
    private let worker = OperationQueue()
    private var fileAccess: FileAccess?
    private var folderAccess: FileAccess?
    private var folderPanel: NSOpenPanel?
    private let imageStore = ImageStore()
    private var loadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var navigationDirection = 1
    private var request = 0
    private var openedURL: URL?

    init(discoverImages: @escaping DiscoverImages = { try ImageLoader.discover(in: $0, isCancelled: $1) }) {
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
        popup(
            rating, title: "Filter by exact star rating",
            values: ["All Ratings", "Unrated / 0 Stars", "1 Star", "2 Stars", "3 Stars", "4 Stars", "5 Stars"],
            action: #selector(filtersChanged))
        popup(
            format, title: "Filter by file type", values: ["All Types"] + ImageFormat.allCases.map(\.rawValue),
            action: #selector(filtersChanged))
        display.selectItem(withTitle: session.preferences.display.rawValue)
        sorting.selectItem(withTitle: session.preferences.sort.rawValue)
        direction.selectItem(at: session.preferences.ascending ? 0 : 1)
        configureButton(previous, title: "Previous image", symbol: "chevron.left", action: #selector(previousImage))
        configureButton(next, title: "Next image", symbol: "chevron.right", action: #selector(nextImage))
        configureButton(info, title: "Show metadata", symbol: "sidebar.right", action: #selector(toggleSidebar))
        info.setButtonType(.toggle)
        configureButton(browse, title: "Browse", symbol: "line.3.horizontal.decrease", action: #selector(showBrowse))
        browse.title = "Browse"
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
        let content = NSStackView(views: [canvas, sidebar])
        content.orientation = .horizontal
        content.alignment = .top
        content.distribution = .fill
        content.spacing = 0
        canvas.setContentHuggingPriority(.defaultLow, for: .horizontal)

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
            canvas.heightAnchor.constraint(equalTo: content.heightAnchor),
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
        canvas.displayDefault = session.preferences.display
        canvas.resetZoom()
        canvas.showMessage(
            "Open an image", detail: "View JPEG, PNG, and HEIF images. Your originals stay unchanged.",
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
        let heading = NSTextField(labelWithString: "Browse images")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let reset = NSButton(title: "Clear Filters", target: self, action: #selector(clearFilters))
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Sort by"), sorting],
            [NSTextField(labelWithString: "Direction"), direction],
            [NSTextField(labelWithString: "Rating"), rating],
            [NSTextField(labelWithString: "File type"), format],
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 68
        grid.column(at: 1).xPlacement = .fill
        let note = NSTextField(wrappingLabelWithString: "Rating and file type filters apply together.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, grid, note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
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
        browsePopover.contentSize = NSSize(width: 340, height: 300)
    }

    @objc private func showBrowse() {
        if browsePopover.isShown {
            browsePopover.performClose(nil)
        } else {
            browsePopover.show(relativeTo: browse.bounds, of: browse, preferredEdge: .minY)
        }
    }

    @objc private func clearFilters() {
        rating.selectItem(at: 0)
        format.selectItem(at: 0)
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
        window?.makeFirstResponder(canvas)
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
        rating.selectItem(at: 0)
        format.selectItem(at: 0)
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

    private func requestFolder(_ parent: URL, generation: Int) {
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
            guard self.session.generation == generation, response == .OK, let url = panel.url else { return }
            self.useAuthorizedFolder(FileAccess(url: url))
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
        let currentRequest = request
        metadata.string = ""
        guard let url = session.selectedURL else {
            canvas.image = nil
            canvas.showMessage(
                "No matching images", detail: "No images match the current filters.",
                actionTitle: "Clear Filters", action: { [weak self] in self?.clearFilters() })
            updateStatus()
            return
        }
        canvas.showLoading(filename: url.lastPathComponent)
        window?.title = url.lastPathComponent
        let access = url == openedURL ? fileAccess : folderAccess
        let generation = session.generation
        let store = imageStore
        loadTask = Task { [weak self] in
            do {
                let loaded = try await store.load(at: url, generation: generation, access: access)
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
        guard canvas.image != nil, !canvas.isLoading, session.visibleEntries.count > 1 else { return }
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
        if let index = entries.firstIndex(where: { $0.url == session.selectedURL }) {
            status.stringValue = "\(index + 1) of \(entries.count)"
        } else {
            status.stringValue = openedURL == nil ? "JPEG · PNG · HEIF" : "\(entries.count) images"
        }
        previous.isEnabled = !entries.isEmpty
        next.isEnabled = !entries.isEmpty
        var filters: [String] = []
        if let rating = session.filter.rating { filters.append(rating == 0 ? "Unrated / 0 Stars" : "\(rating) Stars") }
        if let format = session.filter.format { filters.append(format.rawValue) }
        filterSummary.stringValue = filters.isEmpty ? "" : "Filtered by " + filters.joined(separator: " · ")
        filterSummary.toolTip = filterSummary.stringValue
        browse.title = filters.isEmpty ? "Browse" : "Browse (\(filters.count))"
        browse.setAccessibilityLabel(
            filters.isEmpty ? "Browse images" : "Browse images, \(filters.count) active filters")
    }

    private func navigate(_ delta: Int) {
        guard session.selectedURL != nil else { return }
        navigationDirection = delta < 0 ? -1 : 1
        session.navigate(delta)
        loadSelection()
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
            rating: rating.indexOfSelectedItem == 0 ? nil : rating.indexOfSelectedItem - 1,
            format: format.indexOfSelectedItem == 0 ? nil : ImageFormat.allCases[format.indexOfSelectedItem - 1])
        let previous = session.selectedURL
        session.reconcileSelection()
        if session.selectedURL != previous { loadSelection() }
        updateStatus()
        prefetchNeighbor()
    }

    @objc func toggleSidebar() {
        session.sidebarVisible.toggle()
        info.state = session.sidebarVisible ? .on : .off
        info.setAccessibilityLabel(session.sidebarVisible ? "Hide metadata" : "Show metadata")
        sidebar.isHidden = !session.sidebarVisible
    }
}

extension ViewerController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .init("Open"), .init("Previous"), .init("Next"), .flexibleSpace, .init("Display"), .init("Browse"),
            .init("Metadata"),
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
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open image")
            item.target = self
            item.action = #selector(openPanel)
        case "Previous":
            item.label = "Previous Image"
            item.view = previous
        case "Next":
            item.label = "Next Image"
            item.view = next
        case "Display":
            item.label = "Default Zoom"
            item.view = display
        case "Browse":
            item.label = "Browse"
            item.view = browse
        case "Metadata":
            item.label = "Metadata"
            item.view = info
        default: return nil
        }
        return item
    }
}
