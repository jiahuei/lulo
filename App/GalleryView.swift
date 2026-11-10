import AppKit
import LuloCore
import LuloImaging

@MainActor
final class GalleryView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let collection = GalleryCollectionView()
    private let scroll = NSScrollView()
    private let tileLayout = GalleryTileLayout()
    private let header = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    let poster = PosterView()
    let emptyState = MessageView()
    private let loader: ThumbnailLoader
    private var entries: [ImageEntry] = []
    private var folderAccess: FileAccess?
    private var fileAccess: FileAccess?
    private var generation = 0
    private var rowsConstraints: [NSLayoutConstraint] = []
    private var previewConstraints: [NSLayoutConstraint] = []
    private var headerInsets: [NSLayoutConstraint] = []
    private var posterWidth: NSLayoutConstraint?
    var selectionChanged: ((URL) -> Void)?
    var openSelection: (() -> Void)?
    var navigate: ((Int) -> Void)?

    private(set) var layoutMode = GalleryLayout.rows
    private(set) var thumbnailSize = GalleryLayout.rows.defaultSize
    /// Below 900 points the Rows margins narrow and the Preview poster column becomes 300 points.
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            applyLayout()
        }
    }
    /// Over the blurred background, secondary text switches to primary for readability.
    var emphasizesText = false {
        didSet {
            countLabel.textColor = emphasizesText ? Theme.textPrimary : Theme.textSecondary
            poster.emphasizesText = emphasizesText
        }
    }

    init(loader: ThumbnailLoader) {
        self.loader = loader
        super.init(frame: .zero)
        collection.collectionViewLayout = tileLayout
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
        collection.navigate = { [weak self] in self?.navigate?($0) }
        collection.moveVertically = { [weak self] in self?.moveVertically($0) }
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        countLabel.textColor = Theme.textSecondary
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 20
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(countLabel)

        for view in [header, scroll, poster, emptyState] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let rowsLeading = header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28)
        let rowsTrailing = header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28)
        headerInsets = [rowsLeading, rowsTrailing]
        let posterWidth = poster.widthAnchor.constraint(equalToConstant: 340)
        self.posterWidth = posterWidth
        rowsConstraints = [
            header.topAnchor.constraint(equalTo: topAnchor, constant: 18), rowsLeading, rowsTrailing,
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
        ]
        previewConstraints = [
            poster.leadingAnchor.constraint(equalTo: leadingAnchor), poster.topAnchor.constraint(equalTo: topAnchor),
            poster.bottomAnchor.constraint(equalTo: bottomAnchor), posterWidth,
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: poster.trailingAnchor),
        ]
        NSLayoutConstraint.activate([
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 32),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: scroll.trailingAnchor, constant: -32),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        emptyState.isHidden = true
        poster.openImage = { [weak self] in self?.openSelection?() }
        applyLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(
        entries: [ImageEntry], selectedURL: URL?, totalCount: Int, sort: SortMethod, folderAccess: FileAccess,
        fileAccess: FileAccess?, generation: Int
    ) {
        self.folderAccess = folderAccess
        self.fileAccess = fileAccess
        if self.entries != entries || self.generation != generation {
            cancelVisibleThumbnails()
            self.entries = entries
            self.generation = generation
            tileLayout.aspectRatios = entries.map(\.aspectRatio)
            collection.reloadData()
        }
        let folderName = folderAccess.url.lastPathComponent
        titleLabel.attributedStringValue = Theme.headline(folderName, size: 34, weight: .semibold, tracking: -0.035)
        let shown = entries.count == totalCount ? "" : "\(entries.count) of "
        let images = "\(shown)\(totalCount) \(totalCount == 1 ? "image" : "images")"
        countLabel.stringValue = images
        poster.update(
            folderName: folderName,
            count: "\(images)\(shown.isEmpty ? "" : " shown"), sorted by \(sort.rawValue.lowercased())",
            entry: entries.first(where: { $0.url == selectedURL }))
        scroll.isHidden = entries.isEmpty
        emptyState.isHidden = !entries.isEmpty
        let selection = entries.firstIndex(where: { $0.url == selectedURL }).map { IndexPath(item: $0, section: 0) }
        let paths: Set<IndexPath> = selection.map { [$0] } ?? []
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
    }

    /// Applies a layout and its size immediately, keeping the selection in view.
    func setLayout(_ layout: GalleryLayout, size: Double) {
        guard layout != layoutMode || size != thumbnailSize else { return }
        let modeChanged = layout != layoutMode
        layoutMode = layout
        thumbnailSize = size
        if modeChanged {
            applyLayout()
        } else {
            tileLayout.size = size
            tileLayout.invalidateLayout()
        }
        layoutSubtreeIfNeeded()
        scrollSelectionIntoView()
    }

    private func applyLayout() {
        NSLayoutConstraint.deactivate(rowsConstraints + previewConstraints)
        NSLayoutConstraint.activate(layoutMode == .rows ? rowsConstraints : previewConstraints)
        header.isHidden = layoutMode != .rows
        poster.isHidden = layoutMode != .preview
        poster.isCompact = isCompact
        let inset: CGFloat = isCompact ? 18 : 28
        headerInsets[0].constant = inset
        headerInsets[1].constant = -inset
        tileLayout.mode = layoutMode
        tileLayout.size = thumbnailSize
        tileLayout.horizontalPadding = inset
        tileLayout.invalidateLayout()
        for item in collection.visibleItems() { (item as? GalleryItem)?.mode = layoutMode }
        needsLayout = true
    }

    override func layout() {
        posterWidth?.constant = isCompact ? 300 : max(340, bounds.width * 0.4)
        super.layout()
        emptyState.updateHeadlineSize()
        let width = scroll.contentView.bounds.width
        if tileLayout.width != width {
            tileLayout.width = width
            tileLayout.invalidateLayout()
        }
    }

    func focusSelection() {
        window?.makeFirstResponder(collection)
        scrollSelectionIntoView()
    }

    func scrollSelectionIntoView() {
        guard !collection.selectionIndexPaths.isEmpty else { return }
        collection.scrollToItems(
            at: collection.selectionIndexPaths, scrollPosition: [.nearestHorizontalEdge, .nearestVerticalEdge])
    }

    func clear() {
        cancelVisibleThumbnails()
        entries = []
        tileLayout.aspectRatios = []
        collection.reloadData()
        folderAccess = nil
        fileAccess = nil
        poster.update(folderName: "", count: "", entry: nil)
    }

    private func moveVertically(_ direction: Int) {
        guard let index = collection.selectionIndexPaths.first?.item,
            let target = GalleryGeometry.verticalNeighbor(of: index, in: tileLayout.tileFrames, direction: direction),
            entries.indices.contains(target)
        else { return }
        selectionChanged?(entries[target].url)
        scrollSelectionIntoView()
    }

    private func cancelVisibleThumbnails() {
        for item in collection.visibleItems() { (item as? GalleryItem)?.cancelThumbnail() }
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        entries.count
    }

    func collectionView(
        _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: .init("Thumbnail"), for: indexPath)
        (item as? GalleryItem)?.configure(entry: entries[indexPath.item], mode: layoutMode)
        return item
    }

    func collectionView(
        _ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
        forRepresentedObjectAt indexPath: IndexPath
    ) {
        let url = entries[indexPath.item].url
        guard let access = fileAccess?.url == url ? fileAccess : folderAccess else { return }
        (item as? GalleryItem)?.loadThumbnail(loader: loader, access: access, generation: generation)
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

/// Justified rows or a square grid from `GalleryGeometry`. The gallery pushes the visible width in, so the layout
/// never reads view state during layout passes.
final class GalleryTileLayout: NSCollectionViewLayout {
    /// Preview tiles leave room around them for a selection outline with a 2-point gap.
    static let previewOutset: CGFloat = 4
    var mode = GalleryLayout.rows
    var size = GalleryLayout.rows.defaultSize
    var aspectRatios: [Double] = []
    var horizontalPadding: CGFloat = 28
    var width: CGFloat = 0
    private(set) var tileFrames: [CGRect] = []
    private var itemFrames: [CGRect] = []
    private var contentSize = NSSize.zero

    override func prepare() {
        super.prepare()
        let insets =
            mode == .rows
            ? NSEdgeInsets(top: 0, left: horizontalPadding, bottom: 28, right: horizontalPadding)
            : NSEdgeInsets(top: 10, left: 8, bottom: 30, right: 22)
        let available = max(1, width - insets.left - insets.right)
        let frames =
            mode == .rows
            ? GalleryGeometry.justifiedRows(
                aspectRatios: aspectRatios, width: available, targetHeight: size, spacing: 6)
            : GalleryGeometry.squareGrid(count: aspectRatios.count, width: available, minimumTile: size, spacing: 10)
        tileFrames = frames
        let outset = mode == .preview ? Self.previewOutset : 0
        itemFrames = frames.map { $0.offsetBy(dx: insets.left, dy: insets.top).insetBy(dx: -outset, dy: -outset) }
        contentSize = NSSize(width: width, height: (itemFrames.map(\.maxY).max() ?? 0) + insets.bottom)
    }

    override var collectionViewContentSize: NSSize { contentSize }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        itemFrames.indices.filter { itemFrames[$0].intersects(rect) }.map { attributes($0) }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        itemFrames.indices.contains(indexPath.item) ? attributes(indexPath.item) : nil
    }

    private func attributes(_ index: Int) -> NSCollectionViewLayoutAttributes {
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
        attributes.frame = itemFrames[index]
        return attributes
    }
}

@MainActor
private final class GalleryCollectionView: NSCollectionView {
    var openSelection: (() -> Void)?
    var navigate: ((Int) -> Void)?
    var moveVertically: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            openSelection?()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: openSelection?()
        // Left and right follow the viewer's wrapping order; up and down use the visual rows.
        case 123: navigate?(-1)
        case 124: navigate?(1)
        case 125: moveVertically?(1)
        case 126: moveVertically?(-1)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class GalleryItem: NSCollectionViewItem {
    private let tile = GalleryThumbnailView()
    private let filename = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "Preview unavailable")
    private var labelInsets: [NSLayoutConstraint] = []
    private var url: URL?
    private var task: Task<Void, Never>?
    private var failed = false { didSet { updateState() } }

    var mode = GalleryLayout.rows {
        didSet {
            tile.mode = mode
            let inset = mode == .preview ? GalleryTileLayout.previewOutset : 0
            labelInsets[0].constant = inset + 10
            labelInsets[1].constant = -inset - 10
            labelInsets[2].constant = -inset - 9
            updateState()
        }
    }

    override var isSelected: Bool { didSet { updateState() } }

    override func loadView() {
        view = NSView()
        filename.font = .systemFont(ofSize: 11, weight: .medium)
        filename.lineBreakMode = .byTruncatingMiddle
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = Theme.textSecondary
        pin(tile, in: view)
        let labels = NSStackView(views: [filename, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.detachesHiddenViews = true
        labels.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(labels)
        labelInsets = [
            labels.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
            labels.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -9),
        ]
        NSLayoutConstraint.activate(labelInsets)
        tile.hoverChanged = { [weak self] in self?.updateState() }
        imageView = tile
        textField = filename
    }

    func configure(entry: ImageEntry, mode: GalleryLayout) {
        _ = view
        cancelThumbnail()
        let url = entry.url
        self.url = url
        self.mode = mode
        tile.rating = entry.rating
        filename.stringValue = url.lastPathComponent
        let ratingDescription = entry.rating.flatMap { (1...5).contains($0) ? ", \($0) of 5 stars" : nil } ?? ""
        tile.setAccessibilityLabel(url.lastPathComponent + ratingDescription)
        view.toolTip = url.lastPathComponent
        updateState()
    }

    func loadThumbnail(loader: ThumbnailLoader, access: FileAccess, generation: Int) {
        cancelThumbnail()
        guard let url else { return }
        task = Task { [weak self] in
            do {
                let loaded = try await loader.load(at: url, access: access, generation: generation)
                guard !Task.isCancelled, let self, self.url == url else { return }
                self.tile.image = NSImage(cgImage: loaded.image, size: .zero)
                self.updateState()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self, self.url == url else { return }
                self.failed = true
                self.view.toolTip = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func cancelThumbnail() {
        task?.cancel()
        task = nil
        tile.image = nil
        failed = false
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelThumbnail()
        url = nil
        tile.rating = nil
    }

    /// Rows show the filename on hover and selection; Preview shows none. A failed preview always names its file.
    private func updateState() {
        guard isViewLoaded else { return }
        tile.isSelected = isSelected
        let caption = mode == .rows && (tile.isHovered || isSelected) && tile.image != nil
        tile.showsCaption = caption
        filename.isHidden = !(caption || failed)
        filename.textColor = failed ? Theme.textPrimary : .white
        detail.isHidden = !failed
    }
}

/// One tile, drawn in a single pass so captures match the screen: placeholder, cropped image, hover, caption
/// gradient, rating pill, and selection.
@MainActor
final class GalleryThumbnailView: NSImageView {
    var rating: Int? { didSet { needsDisplay = true } }
    var mode = GalleryLayout.rows { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var showsCaption = false { didSet { needsDisplay = true } }
    private(set) var isHovered = false
    var hoverChanged: (() -> Void)?

    override var image: NSImage? { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { false }

    /// The tile itself, inside the outline margin that Preview reserves around it.
    var tileRect: NSRect {
        mode == .preview
            ? bounds.insetBy(dx: GalleryTileLayout.previewOutset, dy: GalleryTileLayout.previewOutset) : bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self,
                userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ hovered: Bool) {
        isHovered = hovered
        needsDisplay = true
        hoverChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = tileRect
        let radius: CGFloat = mode == .rows ? 3 : 10
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        Theme.tilePlaceholder.setFill()
        rect.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            // Rows tiles already match the image aspect; Preview crops to a square for display only.
            let zoom: CGFloat = mode == .preview && isHovered && !Theme.reduceMotion ? 1.04 : 1
            let scale = max(rect.width / image.size.width, rect.height / image.size.height) * zoom
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let target = NSRect(
                x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
            image.draw(
                in: target, from: .zero, operation: .sourceOver, fraction: mode == .rows && isHovered ? 0.88 : 1)
        }
        if showsCaption {
            let shade = NSColor(srgbRed: 5 / 255, green: 9 / 255, blue: 7 / 255, alpha: 0.82)
            NSGradient(starting: shade, ending: shade.withAlphaComponent(0))?
                .draw(
                    in: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, 42)), angle: 90)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let rating, (1...5).contains(rating) {
            Theme.drawRatingPill(rating, topRight: NSPoint(x: rect.maxX - 7, y: rect.maxY - 7), flipped: false)
        }
        guard isSelected else { return }
        if mode == .rows {
            let inner = NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 1, yRadius: 1)
            inner.lineWidth = 2
            NSColor.black.withAlphaComponent(0.55).setStroke()
            inner.stroke()
            let outer = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2)
            outer.lineWidth = 2
            Theme.accent.setStroke()
            outer.stroke()
        } else {
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
            outline.lineWidth = 2
            Theme.accent.setStroke()
            outline.stroke()
        }
    }
}

/// The Preview layout's left column: folder name, count, a large preview of the selection, and its caption.
@MainActor
final class PosterView: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    let count = NSTextField(labelWithString: "")
    let preview = PosterImageView()
    private let filename = NSTextField(labelWithString: "")
    private let chip = RatingChip()
    let caption = NSTextField(labelWithString: "")
    private let viewButton = ProminentButton(title: "View", target: nil, action: nil)
    private var leadingInset: NSLayoutConstraint?
    private var folderName = ""
    private(set) var entry: ImageEntry?
    var openImage: (() -> Void)?
    var isCompact = false { didSet { leadingInset?.constant = isCompact ? 22 : 32 } }
    var emphasizesText = false {
        didSet {
            let color = emphasizesText ? Theme.textPrimary : Theme.textSecondary
            count.textColor = color
            caption.textColor = color
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.maximumNumberOfLines = 3
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        count.font = .systemFont(ofSize: 14)
        count.textColor = Theme.textSecondary
        count.lineBreakMode = .byTruncatingTail
        filename.font = .systemFont(ofSize: 16, weight: .semibold)
        filename.textColor = Theme.textPrimary
        filename.lineBreakMode = .byTruncatingMiddle
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        caption.textColor = Theme.textSecondary
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        viewButton.target = self
        viewButton.action = #selector(openSelection)
        viewButton.setAccessibilityLabel("View image")
        let nameRow = NSStackView(views: [filename, chip])
        nameRow.spacing = 8
        nameRow.detachesHiddenViews = true
        let text = NSStackView(views: [nameRow, caption])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let captionRow = NSStackView(views: [text, viewButton])
        captionRow.alignment = .bottom
        captionRow.spacing = 16
        let headline = NSStackView(views: [title, count])
        headline.orientation = .vertical
        headline.alignment = .leading
        headline.spacing = 8
        let stack = NSStackView(views: [headline, preview, captionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let leading = stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32)
        leadingInset = leading
        preview.setContentHuggingPriority(.init(1), for: .vertical)
        preview.setContentCompressionResistancePriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            leading, stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            headline.widthAnchor.constraint(equalTo: stack.widthAnchor),
            title.widthAnchor.constraint(equalTo: headline.widthAnchor),
            count.widthAnchor.constraint(lessThanOrEqualTo: headline.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            captionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(folderName: String, count: String, entry: ImageEntry?) {
        self.folderName = folderName
        self.count.stringValue = count
        if entry?.url != self.entry?.url {
            preview.image = nil
            caption.stringValue = ""
        }
        self.entry = entry
        filename.stringValue = entry?.url.lastPathComponent ?? ""
        chip.rating = entry?.rating
        viewButton.isHidden = entry == nil
        updateTitle()
    }

    /// Shows the thumbnail first and then the full image; details arrive with the full image.
    func setImage(_ image: CGImage?, details: ImageDetails?) {
        preview.image = image
        guard let details else { return }
        caption.stringValue = [details.captureWallClock.map(Theme.captureText), details.exposureSummary]
            .compactMap { $0 }.joined(separator: ", ")
    }

    override func layout() {
        super.layout()
        updateTitle()
    }

    /// The folder name scales with the window between 30 and 44 points.
    private func updateTitle() {
        let size = min(44, max(30, (window?.frame.width ?? 1000) * 0.031))
        let text = Theme.headline(folderName, size: size, weight: .bold, tracking: -0.022)
        if title.attributedStringValue != text { title.attributedStringValue = text }
    }

    @objc private func openSelection() { openImage?() }
}

/// The poster's preview: fitted, left-aligned, with a soft drop shadow that follows any transparency.
@MainActor
final class PosterImageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let area = bounds.insetBy(dx: 0, dy: 20)
        let fitted = Theme.fitted(NSSize(width: image.width, height: image.height), in: area)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -18), blur: 30, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        context.interpolationQuality = .high
        context.draw(image, in: NSRect(x: area.minX, y: fitted.minY, width: fitted.width, height: fitted.height))
        context.restoreGState()
    }
}
