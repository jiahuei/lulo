import AppKit
import LuloCore

@MainActor
final class ImageCanvas: NSView {
    var image: CGImage? {
        didSet {
            offset = .zero
            messageStack.isHidden = image != nil
            setAccessibilityElement(image != nil)
            if image != nil { progress.stopAnimation(nil) }
            needsDisplay = true
        }
    }
    private let messageTitle = NSTextField(labelWithString: "")
    private let messageDetail = NSTextField(wrappingLabelWithString: "")
    private let messageButton = NSButton()
    private let progress = NSProgressIndicator()
    private let messageStack = NSStackView()
    private var messageAction: (() -> Void)?
    var displayDefault = DisplayDefault.fit
    var zoom = ZoomState()
    var navigate: ((Int) -> Void)?
    private var offset = CGPoint.zero
    private var dragOrigin: CGPoint?

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
        messageStack.orientation = .vertical
        messageStack.alignment = .centerX
        messageStack.spacing = 12
        for view in [progress, messageTitle, messageDetail, messageButton] { messageStack.addArrangedSubview(view) }
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showMessage(
        _ title: String, detail: String, actionTitle: String? = nil,
        action: (() -> Void)? = nil, loading: Bool = false
    ) {
        messageTitle.stringValue = title
        messageDetail.stringValue = detail
        messageButton.title = actionTitle ?? ""
        messageButton.isHidden = actionTitle == nil
        messageAction = action
        progress.isHidden = !loading
        if loading { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        messageStack.isHidden = false
        setAccessibilityElement(false)
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
