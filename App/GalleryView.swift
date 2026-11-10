import AppKit
import LuloCore
import LuloImaging

@MainActor
final class GalleryView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let collection = GalleryCollectionView()
    private let scroll = NSScrollView()
    private let emptyState = MessageView()
    private let heading = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let poster = NSView()
    private let posterImage = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let exposure = NSTextField(wrappingLabelWithString: "")
    private let posterRating = RatingChip()
    private let viewButton = ProminentButton(title: "View", target: nil, action: nil)
    private let collectionLayout = GalleryCollectionLayout()
    private let loader: ThumbnailLoader
    private var entries: [ImageEntry] = []
    private var folderAccess: FileAccess?
    private var fileAccess: FileAccess?
    private var generation = 0
    private var selectedURL: URL?
    private var lastSize = NSSize.zero
    private var presentation = GalleryLayout.rows
    private var targetSize = 200.0
    private var fullPreview = false
    var selectionChanged: ((URL) -> Void)?
    var openSelection: (() -> Void)?
    var clearFilters: (() -> Void)?

    init(loader: ThumbnailLoader = ThumbnailLoader()) {
        self.loader = loader
        super.init(frame: .zero)
        collection.collectionViewLayout = collectionLayout
        collection.register(GalleryItem.self, forItemWithIdentifier: .init("Thumbnail"))
        collection.dataSource = self
        collection.delegate = self
        collection.isSelectable = true
        collection.allowsMultipleSelection = false
        collection.allowsEmptySelection = false
        collection.backgroundColors = [.clear]
        collection.autoresizingMask = [.width]
        collection.setAccessibilityLabel("Folder gallery")
        collection.openSelection = { [weak self] in self?.openSelection?() }
        collection.navigate = { [weak self] key in self?.navigate(key) }
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        heading.font = .systemFont(ofSize: 34, weight: .semibold)
        heading.textColor = Theme.textPrimary
        heading.lineBreakMode = .byTruncatingTail
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.lineBreakMode = .byTruncatingTail
        addSubview(heading)
        addSubview(count)
        addSubview(poster)
        posterImage.imageScaling = .scaleProportionallyUpOrDown
        posterImage.imageAlignment = .alignLeft
        posterImage.wantsLayer = true
        posterImage.shadow = NSShadow()
        posterImage.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.3)
        posterImage.shadow?.shadowBlurRadius = 16
        posterImage.shadow?.shadowOffset = NSSize(width: 0, height: -8)
        caption.font = .systemFont(ofSize: 16, weight: .semibold)
        caption.textColor = Theme.textPrimary
        caption.lineBreakMode = .byTruncatingMiddle
        exposure.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        viewButton.setAccessibilityLabel("View image")
        viewButton.target = self
        viewButton.action = #selector(openPoster)
        for view in [posterImage, caption, exposure, posterRating, viewButton] { poster.addSubview(view) }
        emptyState.show("No images match the current filters.", detail: "", actionTitle: "Clear Filters") {
            [weak self] in self?.clearFilters?()
        }
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -56),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let compact = (window?.frame.width ?? bounds.width) < 900
        let side: CGFloat = compact ? 18 : 28
        emptyState.updateHeadlineSize()
        let titleSize = presentation == .rows ? 34 : min(44, max(30, bounds.width * 0.031))
        heading.font = .systemFont(ofSize: titleSize, weight: presentation == .rows ? .semibold : .bold)
        let headline = Theme.headline(
            heading.stringValue, size: titleSize, weight: presentation == .rows ? .semibold : .bold,
            tracking: presentation == .rows ? -0.035 : -0.022,
            lineBreak: presentation == .rows ? .byTruncatingTail : .byWordWrapping)
        if heading.attributedStringValue != headline { heading.attributedStringValue = headline }
        count.font =
            presentation == .rows
            ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 14)
        if presentation == .rows {
            heading.frame = NSRect(
                x: side, y: bounds.height - 68, width: max(1, bounds.width - side * 2 - 160), height: 46)
            count.frame = NSRect(x: bounds.width - side - 160, y: bounds.height - 56, width: 160, height: 20)
            count.alignment = .right
            scroll.frame = NSRect(
                x: side, y: 0, width: max(1, bounds.width - side * 2), height: max(1, bounds.height - 82))
        } else {
            let posterWidth: CGFloat = compact ? 300 : max(340, bounds.width * 0.4)
            let leftInset: CGFloat = compact ? 22 : 32
            let titleWidth = posterWidth - leftInset - 28
            let titleHeight = min(
                140,
                max(
                    44,
                    heading.cell?.cellSize(
                        forBounds:
                            NSRect(x: 0, y: 0, width: titleWidth, height: 140)
                    ).height ?? 44))
            heading.frame = NSRect(
                x: leftInset, y: bounds.height - titleHeight - 10, width: titleWidth, height: titleHeight)
            count.frame = NSRect(x: leftInset, y: heading.frame.minY - 30, width: titleWidth, height: 22)
            count.alignment = .left
            poster.frame = NSRect(x: leftInset, y: 10, width: titleWidth, height: max(1, count.frame.minY - 20))
            let buttonSize = viewButton.intrinsicContentSize
            let exposureWidth = max(1, poster.bounds.width - buttonSize.width - 16)
            let exposureHeight = ceil(
                exposure.cell?.cellSize(
                    forBounds: NSRect(x: 0, y: 0, width: exposureWidth, height: .greatestFiniteMagnitude)
                ).height ?? 16)
            let metadataHeight = max(buttonSize.height, exposureHeight)
            exposure.frame = NSRect(
                x: 0, y: (metadataHeight - exposureHeight) / 2, width: exposureWidth, height: exposureHeight)
            viewButton.frame = NSRect(
                x: poster.bounds.width - buttonSize.width, y: (metadataHeight - buttonSize.height) / 2,
                width: buttonSize.width, height: buttonSize.height)
            let ratingSize = posterRating.intrinsicContentSize
            let ratingWidth = posterRating.isHidden ? 0 : ratingSize.width + 8
            caption.frame = NSRect(
                x: 0, y: metadataHeight + 4, width: max(1, poster.bounds.width - ratingWidth), height: 24)
            posterRating.frame = NSRect(
                x: poster.bounds.width - ratingSize.width, y: caption.frame.midY - ratingSize.height / 2,
                width: ratingSize.width, height: ratingSize.height)
            let imageBottom = caption.frame.maxY + 16
            let availableHeight = max(1, poster.bounds.height - imageBottom)
            let sourceSize = posterImage.image?.size ?? NSSize(width: 3, height: 2)
            let imageHeight = min(availableHeight, poster.bounds.width * sourceSize.height / max(1, sourceSize.width))
            posterImage.frame = NSRect(
                x: 0, y: imageBottom + (availableHeight - imageHeight) / 2,
                width: poster.bounds.width, height: imageHeight)
            scroll.frame = NSRect(
                x: posterWidth + 8, y: 0, width: max(1, bounds.width - posterWidth - 30),
                height: max(1, bounds.height - 10))
        }
        if lastSize != scroll.contentSize {
            lastSize = scroll.contentSize
            collectionLayout.invalidateLayout()
            collection.layoutSubtreeIfNeeded()
            scrollSelectionIntoView()
        }
    }

    func update(
        entries: [ImageEntry], selectedURL: URL?, folderAccess: FileAccess, fileAccess: FileAccess?, generation: Int,
        preferences: Preferences, totalCount: Int, filterSummary: String
    ) {
        self.folderAccess = folderAccess
        self.fileAccess = fileAccess
        let mode = preferences.galleryLayout
        let size = mode == .rows ? preferences.rowsTargetHeight : preferences.previewTileSize
        let changed = self.entries != entries || self.generation != generation
        let layoutChanged = mode != presentation || size != targetSize
        presentation = mode
        targetSize = size
        collectionLayout.presentation = mode
        collectionLayout.targetSize = size
        collectionLayout.aspectRatios = entries.map { entry in
            guard let size = entry.pixelSize, size.height > 0 else { return 1.5 }
            return Double(size.width / size.height)
        }
        if changed || layoutChanged {
            self.entries = entries
            self.generation = generation
            if changed {
                cancelVisibleThumbnails()
                collection.reloadData()
            } else {
                // A layout change reuses cells and their already decoded thumbnails.
                for item in collection.visibleItems() { (item as? GalleryItem)?.presentation = mode }
            }
            collectionLayout.invalidateLayout()
        }
        heading.stringValue = folderAccess.url.lastPathComponent
        heading.maximumNumberOfLines = mode == .rows ? 1 : 3
        heading.lineBreakMode = mode == .rows ? .byTruncatingTail : .byWordWrapping
        let number = entries.count == totalCount ? "\(totalCount) images" : "\(entries.count) of \(totalCount) images"
        count.stringValue =
            mode == .rows
            ? number
            : number + (entries.count == totalCount ? "" : " shown") + ", sorted by "
                + preferences.sort.rawValue.lowercased()
        count.textColor = preferences.blurredBackground ? Theme.textPrimary : Theme.textSecondary
        exposure.textColor = count.textColor
        emptyState.detail.stringValue = filterSummary
        scroll.isHidden = entries.isEmpty
        emptyState.isHidden = !entries.isEmpty
        poster.isHidden = mode != .preview || entries.isEmpty
        heading.isHidden = entries.isEmpty
        count.isHidden = entries.isEmpty
        if self.selectedURL != selectedURL || changed {
            self.selectedURL = selectedURL
            fullPreview = false
            posterImage.image = nil
            caption.stringValue = selectedURL?.lastPathComponent ?? ""
            exposure.stringValue = ""
            posterRating.setRating(entries.first(where: { $0.url == selectedURL })?.rating)
        }
        let selection = entries.firstIndex(where: { $0.url == selectedURL }).map { IndexPath(item: $0, section: 0) }
        let paths: Set<IndexPath> = selection.map { [$0] } ?? []
        let selectionChanged = collection.selectionIndexPaths != paths
        if selectionChanged { collection.selectionIndexPaths = paths }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if changed || layoutChanged || selectionChanged { scrollSelectionIntoView() }
    }

    func showPreview(_ image: CGImage, details: ImageDetails? = nil) {
        guard !fullPreview || details != nil else { return }
        fullPreview = details != nil
        posterImage.image = NSImage(cgImage: image, size: .zero)
        posterImage.setAccessibilityLabel(caption.stringValue)
        needsLayout = true
        if let details {
            let fields = details.groups.first(where: { $0.name == "Exposure" })?.fields ?? []
            let captured = details.entry.capturedAt.map(Theme.captureText)
            exposure.stringValue = [
                captured, fields.first(where: { $0.name == "Exposure" })?.value,
                fields.first(where: { $0.name == "ISO Speed Rating" }).map { "ISO \($0.value)" },
            ]
            .compactMap { $0 }.joined(separator: ", ")
        }
    }

    func previewFailed() {
        if posterImage.image == nil {
            exposure.stringValue = "Preview unavailable"
            needsLayout = true
        }
    }

    func focusSelection() {
        window?.makeFirstResponder(collection)
        scrollSelectionIntoView()
    }

    private func scrollSelectionIntoView() {
        if !collection.selectionIndexPaths.isEmpty {
            collection.scrollToItems(
                at: collection.selectionIndexPaths, scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge])
        }
    }

    func clear() {
        cancelVisibleThumbnails()
        entries = []
        collectionLayout.aspectRatios = []
        collectionLayout.invalidateLayout()
        selectedURL = nil
        posterImage.image = nil
        collection.reloadData()
        folderAccess = nil
        fileAccess = nil
    }

    private func cancelVisibleThumbnails() {
        for item in collection.visibleItems() { (item as? GalleryItem)?.cancelThumbnail() }
    }

    private func navigate(_ key: UInt16) {
        guard let index = entries.firstIndex(where: { $0.url == selectedURL }), !entries.isEmpty else { return }
        let next: Int?
        switch key {
        case 123: next = (index + entries.count - 1) % entries.count
        case 124: next = (index + 1) % entries.count
        case 125: next = collectionLayout.geometry.verticalNeighbor(of: index, direction: 1)
        case 126: next = collectionLayout.geometry.verticalNeighbor(of: index, direction: -1)
        default: next = nil
        }
        if let next { selectionChanged?(entries[next].url) }
    }

    @objc private func openPoster() { openSelection?() }
    @objc private func resetFilters() { clearFilters?() }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: .init("Thumbnail"), for: indexPath)
        (item as? GalleryItem)?.configure(entry: entries[indexPath.item], presentation: presentation)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        let url = entries[indexPath.item].url
        guard let access = fileAccess?.url == url ? fileAccess : folderAccess else { return }
        (item as? GalleryItem)?.presentation = presentation
        (item as? GalleryItem)?.loadThumbnail(loader: loader, access: access, generation: generation)
    }

    func collectionView(
        _ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) { (item as? GalleryItem)?.cancelThumbnail() }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let path = indexPaths.first, entries.indices.contains(path.item) else { return }
        selectionChanged?(entries[path.item].url)
    }
}

@MainActor
private final class GalleryCollectionLayout: NSCollectionViewLayout {
    var aspectRatios: [Double] = []
    var presentation = GalleryLayout.rows
    var targetSize = 200.0
    private(set) var geometry = GalleryGeometry(aspectRatios: [], width: 1, targetSize: 200, layout: .rows)
    private var attributes: [NSCollectionViewLayoutAttributes] = []
    override func prepare() {
        super.prepare()
        geometry = GalleryGeometry(
            aspectRatios: aspectRatios,
            width: Double(collectionView?.enclosingScrollView?.contentSize.width ?? 1), targetSize: targetSize,
            layout: presentation)
        attributes = geometry.frames.enumerated().map { index, frame in
            let value = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            value.frame = frame.offsetBy(dx: 0, dy: 3)
            return value
        }
    }
    override var collectionViewContentSize: NSSize {
        NSSize(width: collectionView?.enclosingScrollView?.contentSize.width ?? 1, height: geometry.height + 30)
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.frame.intersects(rect) }
    }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}

@MainActor
private final class GalleryCollectionView: NSCollectionView {
    var openSelection: (() -> Void)?
    var navigate: ((UInt16) -> Void)?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            openSelection?()
        }
    }
    override func keyDown(with event: NSEvent) {
        if [36, 76].contains(event.keyCode) {
            openSelection?()
        } else if (123...126).contains(event.keyCode) {
            navigate?(event.keyCode)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class GalleryItem: NSCollectionViewItem {
    private let preview = GalleryThumbnailView()
    private let filename = NSTextField(labelWithString: "")
    private var url: URL?
    private var task: Task<Void, Never>?
    var presentation = GalleryLayout.rows { didSet { preview.presentation = presentation } }
    override var isSelected: Bool { didSet { preview.selected = isSelected } }
    override func loadView() {
        view = preview
        preview.imageScaling = .scaleProportionallyUpOrDown
        imageView = preview
        textField = filename
    }
    func configure(entry: ImageEntry, presentation: GalleryLayout) {
        _ = view
        cancelThumbnail()
        url = entry.url
        self.presentation = presentation
        preview.rating = entry.rating
        preview.filename = entry.url.lastPathComponent
        filename.stringValue = preview.filename
        let ratingDescription = entry.rating.flatMap { (1...5).contains($0) ? ", \($0) of 5 stars" : nil } ?? ""
        preview.setAccessibilityLabel(preview.filename + ratingDescription)
        view.toolTip = preview.filename
        preview.selected = isSelected
    }
    func loadThumbnail(loader: ThumbnailLoader, access: FileAccess, generation: Int) {
        cancelThumbnail()
        guard let url else { return }
        task = Task { [weak self] in
            do {
                let loaded = try await loader.load(at: url, access: access, generation: generation)
                guard !Task.isCancelled, let self, self.url == url else { return }
                self.preview.image = NSImage(cgImage: loaded.image, size: .zero)
            } catch is CancellationError { return } catch {
                guard !Task.isCancelled, let self, self.url == url else { return }
                self.preview.failed = true
                self.view.toolTip = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
    func cancelThumbnail() {
        task?.cancel()
        task = nil
        preview.image = nil
        preview.failed = false
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        url = nil
        preview.rating = nil
        preview.resetHover()
    }
}

@MainActor
final class GalleryThumbnailView: NSImageView {
    var rating: Int? { didSet { needsDisplay = true } }
    var filename = "" { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    var presentation = GalleryLayout.rows { didSet { needsDisplay = true } }
    var selected = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverTrackingArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if hoverTrackingArea == nil {
            let area = NSTrackingArea(
                rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self,
                userInfo: nil)
            hoverTrackingArea = area
            addTrackingArea(area)
        }
    }
    func resetHover() {
        hovered = false
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }
    var displayedImageRect: NSRect {
        guard let image else { return .zero }
        let widthScale = bounds.width / image.size.width
        let heightScale = bounds.height / image.size.height
        let scale = presentation == .preview ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let hoverScale =
            hovered && presentation == .preview && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1.04 : 1
        let size = NSSize(width: image.size.width * scale * hoverScale, height: image.size.height * scale * hoverScale)
        return NSRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = presentation == .preview ? 1 : 0
        let tile = bounds.insetBy(dx: inset, dy: inset)
        let corner: CGFloat = presentation == .preview ? 10 : 3
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner).addClip()
        Theme.tilePlaceholder.setFill()
        tile.fill()
        image?.draw(
            in: displayedImageRect, from: .zero, operation: .sourceOver,
            fraction: hovered && presentation == .rows ? 0.88 : 1, respectFlipped: true, hints: nil)
        if failed || (presentation == .rows && (hovered || selected) && image != nil) {
            let captionHeight: CGFloat = failed ? 42 : 32
            let bottom = NSRect(
                x: tile.minX, y: isFlipped ? tile.maxY - captionHeight : tile.minY, width: tile.width,
                height: captionHeight)
            if !failed {
                NSGradient(starting: .black.withAlphaComponent(0.82), ending: .clear)?.draw(
                    in: bottom, angle: isFlipped ? 90 : -90)
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle
            let caption = NSMutableAttributedString(
                string: filename,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: failed ? Theme.textPrimary : NSColor.white,
                    .paragraphStyle: paragraph,
                ])
            if failed {
                caption.append(
                    NSAttributedString(
                        string: "\nPreview unavailable",
                        attributes: [
                            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: Theme.textSecondary,
                            .paragraphStyle: paragraph,
                        ]))
            }
            caption.draw(in: bottom.insetBy(dx: 10, dy: 9))
        }
        if image != nil, let rating, (1...5).contains(rating) {
            let text = NSMutableAttributedString(
                string: "★ \(rating)",
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ])
            text.addAttribute(
                .foregroundColor, value: NSColor(srgbRed: 1, green: 0.835, blue: 0.29, alpha: 1),
                range: NSRange(location: 0, length: 1))
            let size = text.size()
            let pill = NSRect(
                x: tile.maxX - size.width - 17, y: isFlipped ? tile.minY + 7 : tile.maxY - size.height - 13,
                width: size.width + 10, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.52).setFill()
            let path = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
            path.fill()
            NSColor.white.withAlphaComponent(0.16).setStroke()
            path.lineWidth = 0.5
            path.stroke()
            text.draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 3))
        }
        if selected && presentation == .rows {
            NSColor.black.withAlphaComponent(0.55).setStroke()
            let inner = NSBezierPath(roundedRect: tile.insetBy(dx: 3, dy: 3), xRadius: corner, yRadius: corner)
            inner.lineWidth = 2
            inner.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        if selected {
            Theme.accent.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: corner, yRadius: corner)
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}
