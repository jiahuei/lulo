import AppKit
import LuloCore
import LuloImaging

@MainActor
final class GalleryView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let collection = GalleryCollectionView()
    private let scroll = NSScrollView()
    private let emptyState = NSStackView()
    private let loader = ThumbnailLoader()
    private var entries: [ImageEntry] = []
    private var folderAccess: FileAccess?
    private var fileAccess: FileAccess?
    var selectionChanged: ((URL) -> Void)?
    var openSelection: (() -> Void)?
    var clearFilters: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 160, height: 156)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        collection.collectionViewLayout = layout
        collection.register(GalleryItem.self, forItemWithIdentifier: .init("Thumbnail"))
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.allowsEmptySelection = false
        collection.backgroundColors = [.windowBackgroundColor]
        collection.autoresizingMask = [.width]
        collection.setAccessibilityLabel("Folder gallery")
        collection.openSelection = { [weak self] in self?.openSelection?() }
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let title = NSTextField(labelWithString: "No matching images")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let clear = NSButton(title: "Clear Filters", target: self, action: #selector(resetFilters))
        emptyState.orientation = .vertical
        emptyState.spacing = 20
        emptyState.addArrangedSubview(title)
        emptyState.addArrangedSubview(clear)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(entries: [ImageEntry], selectedURL: URL?, folderAccess: FileAccess, fileAccess: FileAccess?) {
        self.folderAccess = folderAccess
        self.fileAccess = fileAccess
        if self.entries != entries {
            cancelVisibleThumbnails()
            self.entries = entries
            collection.reloadData()
        }
        scroll.isHidden = entries.isEmpty
        emptyState.isHidden = !entries.isEmpty
        let selection = entries.firstIndex(where: { $0.url == selectedURL }).map { IndexPath(item: $0, section: 0) }
        let paths: Set<IndexPath> = selection.map { [$0] } ?? []
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
    }

    func focusSelection() {
        window?.makeFirstResponder(collection)
        if !collection.selectionIndexPaths.isEmpty {
            collection.scrollToItems(
                at: collection.selectionIndexPaths, scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge])
        }
    }

    func clear() {
        cancelVisibleThumbnails()
        entries = []
        collection.reloadData()
        folderAccess = nil
        fileAccess = nil
    }

    private func cancelVisibleThumbnails() {
        for item in collection.visibleItems() { (item as? GalleryItem)?.cancelThumbnail() }
    }

    @objc private func resetFilters() { clearFilters?() }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("Thumbnail"), for: indexPath)
        (item as? GalleryItem)?.configure(url: entries[indexPath.item].url)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        let url = entries[indexPath.item].url
        guard let access = fileAccess?.url == url ? fileAccess : folderAccess else { return }
        (item as? GalleryItem)?.loadThumbnail(loader: loader, access: access)
    }

    func collectionView(
        _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        (item as? GalleryItem)?.cancelThumbnail()
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let path = indexPaths.first, entries.indices.contains(path.item) else { return }
        selectionChanged?(entries[path.item].url)
    }
}

@MainActor
private final class GalleryCollectionView: NSCollectionView {
    var openSelection: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            openSelection?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) {
            openSelection?()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class GalleryItem: NSCollectionViewItem {
    private let preview = NSImageView()
    private let filename = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private var url: URL?
    private var task: Task<Void, Never>?

    override var isSelected: Bool { didSet { updateSelection() } }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        preview.imageScaling = .scaleProportionallyUpOrDown
        filename.font = .systemFont(ofSize: 12)
        filename.lineBreakMode = .byTruncatingMiddle
        filename.alignment = .center
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        for child in [preview, filename, detail] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            preview.heightAnchor.constraint(equalToConstant: 108),
            filename.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 6),
            filename.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            filename.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
            detail.topAnchor.constraint(equalTo: filename.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: preview.trailingAnchor),
        ])
        imageView = preview
        textField = filename
    }

    func configure(url: URL) {
        _ = view
        cancelThumbnail()
        self.url = url
        filename.stringValue = url.lastPathComponent
        preview.setAccessibilityLabel(url.lastPathComponent)
        view.toolTip = url.lastPathComponent
        updateSelection()
    }

    func loadThumbnail(loader: ThumbnailLoader, access: FileAccess) {
        cancelThumbnail()
        guard let url else { return }
        detail.stringValue = "Loading…"
        task = Task { [weak self] in
            do {
                let loaded = try await loader.load(at: url, access: access)
                guard !Task.isCancelled, let self, self.url == url else { return }
                self.preview.image = NSImage(cgImage: loaded.image, size: .zero)
                self.detail.stringValue = ""
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.url == url else { return }
                self.detail.stringValue = "Preview unavailable"
                self.view.toolTip = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func cancelThumbnail() {
        task?.cancel()
        task = nil
        preview.image = nil
        detail.stringValue = ""
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        url = nil
    }

    private func updateSelection() {
        view.layer?.borderWidth = isSelected ? 2 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
}
