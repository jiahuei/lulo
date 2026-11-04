import AppKit
import LuloCore

@MainActor
final class ImageCanvas: NSView {
    var image: CGImage? {
        didSet {
            offset = .zero
            needsDisplay = true
        }
    }
    var message = "Open a JPEG, PNG, or HEIF image to begin." {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(message)
        }
    }
    var displayDefault = DisplayDefault.fit
    var zoom = ZoomState()
    var navigate: ((Int) -> Void)?
    private var offset = CGPoint.zero
    private var dragOrigin: CGPoint?

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(message)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        guard let image, let context = NSGraphicsContext.current?.cgContext else {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            (message as NSString).draw(
                in: bounds.insetBy(dx: 32, dy: max(20, bounds.height / 2 - 30)),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: style,
                ])
            return
        }
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
