import AppKit
import LuloCore
import LuloImaging
import UniformTypeIdentifiers

// CGImage is immutable. Only the main actor installs it in the view.
private struct LoadedImage: @unchecked Sendable {
    let image: CGImage
    let details: ImageDetails
}

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
    private let info = NSButton(checkboxWithTitle: "Metadata", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let worker = OperationQueue()
    private var fileAccess: FileAccess?
    private var folderAccess: FileAccess?
    private var folderPanel: NSOpenPanel?
    private var loadOperation: Operation?
    private var request = 0
    private var openedURL: URL?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Lulo"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 400)
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
        info.target = self
        info.action = #selector(toggleSidebar)
        let open = NSButton(title: "Open…", target: self, action: #selector(openPanel))
        let previous = NSButton(title: "Previous", target: self, action: #selector(previousImage))
        let next = NSButton(title: "Next", target: self, action: #selector(nextImage))
        let controls = NSStackView(views: [open, previous, next, display, sorting, direction, info])
        controls.spacing = 8
        let filters = NSStackView(views: [rating, format, status])
        filters.spacing = 8
        metadata.isEditable = false
        metadata.isSelectable = true
        metadata.isVerticallyResizable = true
        metadata.isHorizontallyResizable = false
        metadata.font = .systemFont(ofSize: 13)
        metadata.textContainerInset = NSSize(width: 12, height: 12)
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
        let root = NSView()
        window.contentView = root
        for view in [controls, filters, content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            controls.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            filters.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            filters.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            filters.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 10),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvas.heightAnchor.constraint(equalTo: content.heightAnchor),
            sidebar.heightAnchor.constraint(equalTo: content.heightAnchor),
        ])
        canvas.navigate = { [weak self] delta in self?.navigate(delta) }
        canvas.displayDefault = session.preferences.display
        canvas.resetZoom()
        window.makeFirstResponder(canvas)
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
        folderPanel?.cancel(nil)
        folderPanel = nil
        worker.cancelAllOperations()
        request += 1
        openedURL = url
        fileAccess = FileAccess(url: url)
        let entry = ImageFormat(url: url).map { ImageEntry(url: url, format: $0) }
        session.open(entry)
        rating.selectItem(at: 0)
        format.selectItem(at: 0)
        info.state = .off
        sidebar.isHidden = true
        canvas.displayDefault = session.preferences.display
        canvas.resetZoom()
        metadata.string = ""
        status.stringValue = ""
        do { _ = try ImageLoader.validateFormat(url) } catch {
            canvas.image = nil
            canvas.message = error.localizedDescription
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
            guard url.standardizedFileURL == parent else {
                self.status.stringValue = "Choose the containing folder to enable navigation."
                return
            }
            self.folderAccess = FileAccess(url: url)
            self.discoverFolder()
        }
    }

    @objc func allowFolderNavigation() {
        guard let openedURL else { return }
        requestFolder(openedURL.deletingLastPathComponent().standardizedFileURL, generation: session.generation)
    }

    private func discoverFolder() {
        guard let access = folderAccess else { return }
        let generation = session.generation
        worker.addOperation { [weak self] in
            let result = Result { try ImageLoader.discover(in: access.url) }
            withExtendedLifetime(access) {
                Task { @MainActor [weak self] in
                    guard let self, self.session.generation == generation else { return }
                    switch result {
                    case .success(var entries):
                        if let opened = self.session.entries.first, !entries.contains(where: { $0.url == opened.url }) {
                            entries.append(opened)
                        }
                        let selected = self.session.selectedURL
                        self.session.replaceEntries(entries)
                        if self.session.selectedURL != selected { self.loadSelection() }
                        self.updateStatus()
                    case .failure:
                        self.status.stringValue = "Folder could not be read. The opened image is still available."
                    }
                }
            }
        }
    }

    private func loadSelection() {
        loadOperation?.cancel()
        request += 1
        let currentRequest = request
        canvas.image = nil
        metadata.string = ""
        canvas.resetZoom()
        guard let url = session.selectedURL else {
            canvas.message = "No images match the current filters."
            updateStatus()
            return
        }
        canvas.message = "Loading image…"
        window?.title = "\(url.lastPathComponent) — Lulo"
        let access = url == openedURL ? fileAccess : folderAccess
        let operation = BlockOperation { [weak self] in
            let result = Result {
                try LoadedImage(image: ImageLoader.decode(at: url), details: ImageLoader.details(at: url))
            }
            withExtendedLifetime(access) {
                Task { @MainActor [weak self] in
                    guard let self, self.request == currentRequest else { return }
                    switch result {
                    case .success(let loaded):
                        let entries = self.session.entries.map { $0.url == url ? loaded.details.entry : $0 }
                        self.session.replaceEntries(entries)
                        guard self.session.selectedURL == url else {
                            self.loadSelection()
                            return
                        }
                        self.canvas.image = loaded.image
                        self.canvas.setAccessibilityLabel(url.lastPathComponent)
                        self.metadata.string = loaded.details.groups.filter { !$0.fields.isEmpty }.map { group in
                            group.name + "\n" + group.fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
                        }.joined(separator: "\n\n")
                    case .failure(let error): self.canvas.message = error.localizedDescription
                    }
                    self.updateStatus()
                }
            }
        }
        loadOperation = operation
        worker.addOperation(operation)
        updateStatus()
    }

    private func updateStatus() {
        let entries = session.visibleEntries
        if let index = entries.firstIndex(where: { $0.url == session.selectedURL }) {
            status.stringValue = "\(index + 1) of \(entries.count)"
        } else {
            status.stringValue = "\(entries.count) images"
        }
    }

    private func navigate(_ delta: Int) {
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
    }

    @objc private func filtersChanged() {
        session.filter = ImageFilter(
            rating: rating.indexOfSelectedItem == 0 ? nil : rating.indexOfSelectedItem - 1,
            format: format.indexOfSelectedItem == 0 ? nil : ImageFormat.allCases[format.indexOfSelectedItem - 1])
        let previous = session.selectedURL
        session.reconcileSelection()
        if session.selectedURL != previous { loadSelection() }
        updateStatus()
    }

    @objc func toggleSidebar() {
        session.sidebarVisible.toggle()
        info.state = session.sidebarVisible ? .on : .off
        sidebar.isHidden = !session.sidebarVisible
    }
}
