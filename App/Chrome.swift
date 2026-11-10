import AppKit

/// `Pictures / [2025] Japan / DSCF2137-LR.jpg`. Only the authorized folder and its parent's name are shown;
/// the parent is display-only because Lulo cannot open folders it was not granted.
@MainActor
final class BreadcrumbView: NSStackView {
    private let icon = NSImageView()
    private let parent = NSTextField(labelWithString: "")
    private let parentSeparator = NSTextField(labelWithString: "/")
    private let folder = NSTextField(labelWithString: "")
    private let folderLink = NSButton()
    private let fileSeparator = NSTextField(labelWithString: "/")
    private let file = NSTextField(labelWithString: "")
    var showGallery: (() -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 7
        detachesHiddenViews = true
        icon.image = Theme.symbol("folder", size: 12, weight: .regular)
        icon.contentTintColor = Theme.textTertiary
        icon.setAccessibilityElement(false)
        for label in [parent, parentSeparator, folder, fileSeparator, file] {
            label.font = .systemFont(ofSize: 13)
            label.textColor = Theme.textSecondary
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for separator in [parentSeparator, fileSeparator] {
            separator.textColor = Theme.textTertiary.withAlphaComponent(0.7)
            separator.setContentCompressionResistancePriority(.required, for: .horizontal)
            separator.setAccessibilityElement(false)
        }
        parent.lineBreakMode = .byTruncatingTail
        folder.lineBreakMode = .byTruncatingTail
        file.lineBreakMode = .byTruncatingMiddle
        for label in [folder, file] {
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = Theme.textPrimary
        }
        folderLink.isBordered = false
        folderLink.font = .systemFont(ofSize: 13, weight: .medium)
        folderLink.contentTintColor = Theme.textSecondary
        folderLink.lineBreakMode = .byTruncatingTail
        folderLink.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderLink.toolTip = "Show gallery"
        folderLink.target = self
        folderLink.action = #selector(openGallery)
        for view in [icon, parent, parentSeparator, folder, folderLink, fileSeparator, file] {
            addArrangedSubview(view)
        }
        setHuggingPriority(.defaultLow, for: .horizontal)
        widthAnchor.constraint(lessThanOrEqualToConstant: 640).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Location")
        update(folderURL: nil, fileURL: nil, galleryVisible: false, compact: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// With no folder grant only the filename is shown; with nothing open the breadcrumb is empty.
    func update(folderURL: URL?, fileURL: URL?, galleryVisible: Bool, compact: Bool) {
        let hasFolder = folderURL != nil
        let showsFile = fileURL != nil && !(galleryVisible && hasFolder)
        icon.isHidden = !hasFolder
        parent.isHidden = !hasFolder || compact
        parentSeparator.isHidden = parent.isHidden
        folder.isHidden = !hasFolder || !galleryVisible
        folderLink.isHidden = !hasFolder || galleryVisible
        fileSeparator.isHidden = !hasFolder || !showsFile
        file.isHidden = !showsFile
        let parentName = folderURL?.deletingLastPathComponent().lastPathComponent ?? ""
        let folderName = folderURL?.lastPathComponent ?? ""
        parent.stringValue = parentName
        folder.stringValue = folderName
        folderLink.title = folderName
        file.stringValue = fileURL?.lastPathComponent ?? ""
        let path = (galleryVisible ? folderURL : fileURL ?? folderURL)?.path ?? ""
        toolTip = path.isEmpty ? nil : path
        setAccessibilityValue(path.isEmpty ? nil : path)
    }

    @objc private func openGallery() { showGallery?() }
}

/// The window background: the plain wall colour, or a blurred copy of the selected image under a veil.
@MainActor
final class BackdropView: NSView {
    private let blurLayer = NSView()
    private let images = [CoverImageView(), CoverImageView()]
    private let veil = VeilView()
    private var front = 0
    private(set) var image: CGImage?
    private(set) var isBlurred = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        blurLayer.alphaValue = 0
        images[1].alphaValue = 0
        pin(blurLayer, in: self)
        for view: NSView in images + [veil] { pin(view, in: blurLayer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Theme.wall.setFill()
        bounds.fill()
    }

    func setBlurred(_ blurred: Bool, animated: Bool) {
        guard blurred != isBlurred else { return }
        isBlurred = blurred
        animate(duration: animated ? 0.35 : 0) { blurLayer.animator().alphaValue = blurred ? 1 : 0 }
    }

    /// Crossfades to a new blurred image; an unchanged image is left alone so redundant updates do not flash.
    func show(_ image: CGImage?, animated: Bool) {
        guard image !== self.image else { return }
        self.image = image
        // The lower view stays opaque: the upper one fades in over it, or fades out to reveal the new image.
        front = 1 - front
        images[front].image = image
        animate(duration: animated ? 0.5 : 0) { images[1].animator().alphaValue = front == 1 ? 1 : 0 }
    }

    private func animate(duration: TimeInterval, _ changes: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.reduceMotion ? 0 : duration
            changes()
        }
    }
}

@MainActor
func pin(_ view: NSView, in container: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
        view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom),
    ])
}

/// Draws an image scaled to cover its bounds at 115%, like the background's oversized blur.
@MainActor
private final class CoverImageView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height)) * 1.15
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(
            image,
            in: NSRect(
                x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
                height: size.height))
    }
}

/// Light mode lifts the blur under a pale veil; dark mode darkens it (brightness 0.55) with a vignette and wash.
@MainActor
private final class VeilView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let veil = Theme.rgb(0xF0F1F3)
        if !Theme.isDark(effectiveAppearance) {
            NSGradient(starting: veil.withAlphaComponent(0.58), ending: veil.withAlphaComponent(0.70))?
                .draw(in: bounds, angle: -90)
            return
        }
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        // An elliptical vignette (120% by 90% radii, centred 40% from the top) darkening to 35% at its edge.
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.35).cgColor]
                as CFArray, locations: [0, 1])
        {
            context.saveGState()
            context.translateBy(x: bounds.midX, y: bounds.maxY - bounds.height * 0.4)
            context.scaleBy(x: max(1, bounds.width * 1.2), y: max(1, bounds.height * 0.9))
            context.drawRadialGradient(
                gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                options: [.drawsAfterEndLocation])
            context.restoreGState()
        }
        NSGradient(
            starting: NSColor.black.withAlphaComponent(0.18), ending: NSColor.black.withAlphaComponent(0.30))?
            .draw(in: bounds, angle: -90)
    }
}
