import AppKit
import LuloCore

@MainActor
final class ImageCanvas: NSView {
    var image: CGImage? {
        didSet {
            offset = .zero
            messageStack.isHidden = image != nil
            setAccessibilityElement(image != nil)
            hideLoading()
            needsDisplay = true
        }
    }
    private let messageTitle = NSTextField(labelWithString: "")
    private let messageDetail = NSTextField(wrappingLabelWithString: "")
    private let messageButton = NSButton()
    private let progress = NSProgressIndicator()
    private let loadingBox = NSVisualEffectView()
    private let loadingFilename = NSTextField(labelWithString: "")
    private let messageStack = NSStackView()
    private var messageAction: (() -> Void)?
    var displayDefault = DisplayDefault.fit
    var zoom = ZoomState()
    var navigate: ((Int) -> Void)?
    private var offset = CGPoint.zero
    private var dragOrigin: CGPoint?
    private(set) var isLoading = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.image)
        messageTitle.font = .systemFont(ofSize: 24, weight: .semibold)
        messageTitle.alignment = .center
        messageDetail.font = .systemFont(ofSize: 13)
        messageDetail.textColor = .secondaryLabelColor
        messageDetail.alignment = .center
        messageButton.bezelStyle = .rounded
        messageButton.target = self
        messageButton.action = #selector(performMessageAction)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Loading image")
        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.spacing = 12
        for view in [messageTitle, messageDetail, messageButton] { messageStack.addArrangedSubview(view) }
        messageStack.setCustomSpacing(20, after: messageDetail)
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageStack)
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageStack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            messageDetail.widthAnchor.constraint(equalTo: messageStack.widthAnchor),
        ])

        loadingBox.material = .hudWindow
        loadingBox.blendingMode = .withinWindow
        loadingBox.state = .active
        loadingBox.wantsLayer = true
        loadingBox.layer?.cornerRadius = 12
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
        loadingFilename.stringValue = filename
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

    func resetZoom() {
        zoom.reset(to: displayDefault)
        offset = .zero
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private var scale: Double {
        guard let image else { return 1 }
        let backing = convertToBacking(bounds.size)
        return zoom.effectiveScale(
            pixelWidth: Double(image.width), pixelHeight: Double(image.height),
            viewportWidth: backing.width, viewportHeight: backing.height, backingScale: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }
        let size = convertFromBacking(NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
        offset.x = max(-max(0, (size.width - bounds.width) / 2), min(max(0, (size.width - bounds.width) / 2), offset.x))
        offset.y = max(
            -max(0, (size.height - bounds.height) / 2), min(max(0, (size.height - bounds.height) / 2), offset.y))
        let rect = NSRect(
            x: (bounds.width - size.width) / 2 + offset.x,
            y: (bounds.height - size.height) / 2 + offset.y, width: size.width, height: size.height)
        context.interpolationQuality = scale >= 1 ? .none : .high
        context.draw(image, in: rect)
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
            zoom.doubleClick(default: displayDefault)
            offset = .zero
            needsDisplay = true
        } else {
            dragOrigin = event.locationInWindow
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        offset.x += event.locationInWindow.x - origin.x
        offset.y += event.locationInWindow.y - origin.y
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
