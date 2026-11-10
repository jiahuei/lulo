import AppKit
import LuloCore

@MainActor
final class ImageCanvas: NSView {
    var image: CGImage? {
        didSet {
            if image != nil { zoom.nextImage() }
            messageStack.isHidden = image != nil
            setAccessibilityElement(image != nil)
            hideLoading()
            needsDisplay = true
            zoomChanged?()
        }
    }
    private let messageTitle = NSTextField(wrappingLabelWithString: "")
    private let messageDetail = NSTextField(wrappingLabelWithString: "")
    private let messageButton = NSButton()
    private let progress = NSProgressIndicator()
    private let loadingBox = NSVisualEffectView()
    private let loadingFilename = NSTextField(labelWithString: "")
    private let messageStack = NSStackView()
    private var messageAction: (() -> Void)?
    var zoom = ZoomState() { didSet { zoomChanged?() } }
    var modeChanged: ((ViewingMode) -> Void)?
    var navigate: ((Int) -> Void)?
    var zoomChanged: (() -> Void)?
    private var dragOrigin: CGPoint?
    private(set) var isLoading = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.image)
        messageTitle.font = .systemFont(ofSize: 38, weight: .bold)
        messageTitle.alignment = .left
        messageDetail.font = .systemFont(ofSize: 14)
        messageDetail.textColor = .secondaryLabelColor
        messageDetail.alignment = .left
        messageButton.bezelStyle = .rounded
        messageButton.target = self
        messageButton.action = #selector(performMessageAction)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Loading image")
        messageStack.orientation = .vertical
        messageStack.alignment = .leading
        messageStack.spacing = 12
        for view in [messageTitle, messageDetail, messageButton] { messageStack.addArrangedSubview(view) }
        messageStack.setCustomSpacing(20, after: messageDetail)
        // Let the preferred measure expand wrapping labels beyond their intrinsic width.
        for view in [messageStack, messageTitle, messageDetail] {
            view.setContentHuggingPriority(.init(1), for: .horizontal)
        }
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageStack)
        let preferredMessageWidth = messageStack.widthAnchor.constraint(equalToConstant: 440)
        // A preferred text measure must not increase the window's minimum width when the panel is open.
        preferredMessageWidth.priority = .init(49)
        preferredMessageWidth.isActive = true
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageStack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            messageTitle.widthAnchor.constraint(equalTo: messageStack.widthAnchor),
            messageDetail.widthAnchor.constraint(equalTo: messageStack.widthAnchor),
        ])

        loadingBox.material = .hudWindow
        loadingBox.blendingMode = .withinWindow
        loadingBox.state = .active
        loadingBox.wantsLayer = true
        loadingBox.layer?.cornerRadius = 14
        loadingBox.layer?.backgroundColor = ViewerColors.solid.cgColor
        loadingBox.layer?.masksToBounds = true
        loadingBox.isHidden = true
        loadingFilename.font = .systemFont(ofSize: 13, weight: .medium)
        loadingFilename.lineBreakMode = .byTruncatingMiddle
        loadingFilename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let loadingRow = NSStackView(views: [progress, loadingFilename])
        loadingRow.orientation = .horizontal
        loadingRow.alignment = .centerY
        loadingRow.spacing = 12
        loadingBox.translatesAutoresizingMaskIntoConstraints = false
        loadingRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingBox)
        loadingBox.addSubview(loadingRow)
        NSLayoutConstraint.activate([
            loadingBox.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingBox.centerYAnchor.constraint(equalTo: centerYAnchor),
            loadingBox.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            loadingBox.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            loadingRow.leadingAnchor.constraint(equalTo: loadingBox.leadingAnchor, constant: 20),
            loadingRow.trailingAnchor.constraint(equalTo: loadingBox.trailingAnchor, constant: -20),
            loadingRow.topAnchor.constraint(equalTo: loadingBox.topAnchor, constant: 16),
            loadingRow.bottomAnchor.constraint(equalTo: loadingBox.bottomAnchor, constant: -16),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showMessage(
        _ title: String, detail: String, actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        hideLoading()
        messageTitle.stringValue = title
        messageDetail.stringValue = detail
        messageButton.title = actionTitle ?? ""
        messageButton.isHidden = actionTitle == nil
        messageAction = action
        messageStack.isHidden = false
        setAccessibilityElement(false)
    }

    func beginLoading() {
        hideLoading()
        isLoading = true
        messageStack.isHidden = true
        // A cache lookup is pending, but only a miss needs visible loading feedback.
        setAccessibilityElement(false)
    }

    func showLoading(filename: String) {
        beginLoading()
        loadingFilename.stringValue = "Loading " + filename
        loadingFilename.toolTip = filename
        loadingBox.isHidden = false
        progress.startAnimation(nil)
    }

    private func hideLoading() {
        isLoading = false
        progress.stopAnimation(nil)
        loadingBox.isHidden = true
    }

    @objc private func performMessageAction() { messageAction?() }

    func resetZoom(to mode: ViewingMode = .fit) {
        zoom.reset(to: mode)
        modeChanged?(zoom.mode)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            loadingBox.layer?.backgroundColor = ViewerColors.solid.cgColor
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
        zoomChanged?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        zoomChanged?()
    }

    private var scale: Double {
        guard let image else { return 1 }
        let backing = convertToBacking(NSSize(width: max(1, bounds.width - 16), height: max(1, bounds.height - 16)))
        return zoom.effectiveScale(
            pixelWidth: Double(image.width), pixelHeight: Double(image.height),
            viewportWidth: backing.width, viewportHeight: backing.height, backingScale: 1)
    }

    private var imageSize: NSSize {
        guard let image else { return .zero }
        return convertFromBacking(NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
    }

    var displayedImageRect: NSRect {
        zoom.imageRect(imageSize: imageSize, viewport: bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = displayedImageRect
        context.interpolationQuality = scale >= 1 ? .none : .high
        context.saveGState()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        context.clip()
        context.draw(image, in: rect)
        context.restoreGState()
    }

    var zoomDescription: String {
        let percent = Int((scale * 100).rounded())
        return zoom.scale == nil ? "Fit, \(percent)%" : "\(percent)%"
    }

    override func scrollWheel(with event: NSEvent) {
        guard image != nil, event.scrollingDeltaY != 0 else { return }
        // Normalize natural scrolling so a physical upward gesture always zooms in.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        zoom.scroll(up: delta > 0, currentScale: scale)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard image != nil else { return }
        if event.clickCount == 2 {
            let point = convert(event.locationInWindow, from: nil)
            let rect = displayedImageRect
            guard rect.width > 0, rect.height > 0 else { return }
            let imagePoint = CGPoint(
                x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
            zoom.doubleClick()
            if zoom.mode == .actualSize {
                zoom.anchor(imagePoint, at: point, imageSize: imageSize, viewport: bounds)
            }
            dragOrigin = nil
            modeChanged?(zoom.mode)
            needsDisplay = true
        } else {
            dragOrigin = event.locationInWindow
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let previous = convert(origin, from: nil)
        zoom.pan(
            by: NSSize(width: point.x - previous.x, height: point.y - previous.y),
            imageSize: imageSize, viewport: bounds)
        dragOrigin = event.locationInWindow
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: navigate?(-1)
        case 124: navigate?(1)
        default: super.keyDown(with: event)
        }
    }
}
