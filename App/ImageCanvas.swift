import AppKit
import LuloCore

@MainActor
final class ImageCanvas: NSView {
    var image: CGImage? {
        didSet {
            if image != nil { zoom.nextImage() }
            message.isHidden = image != nil
            setAccessibilityElement(image != nil)
            hideLoading()
            needsDisplay = true
            zoomChanged?()
        }
    }
    let message = MessageView()
    private let progress = NSProgressIndicator()
    /// Solid rather than translucent so the filename reads over bright images.
    let loadingBox = PanelView(fill: Theme.solidPanel, radius: 14)
    private let loadingFilename = NSTextField(labelWithString: "")
    var zoom = ZoomState()
    /// Called whenever the mode or effective scale may have changed, including resizing.
    var zoomChanged: (() -> Void)?
    var navigate: ((Int) -> Void)?
    private var dragOrigin: CGPoint?
    private(set) var isLoading = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.image)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Loading image")
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        // A left-aligned block, centred as a whole in the content area.
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
        ])

        loadingBox.isHidden = true
        loadingFilename.font = .systemFont(ofSize: 13, weight: .medium)
        loadingFilename.textColor = Theme.textPrimary
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
            loadingBox.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            loadingBox.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            loadingRow.leadingAnchor.constraint(equalTo: loadingBox.leadingAnchor, constant: 18),
            loadingRow.trailingAnchor.constraint(equalTo: loadingBox.trailingAnchor, constant: -18),
            loadingRow.topAnchor.constraint(equalTo: loadingBox.topAnchor, constant: 12),
            loadingRow.bottomAnchor.constraint(equalTo: loadingBox.bottomAnchor, constant: -12),
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
        message.show(title, detail: detail, actionTitle: actionTitle, action: action)
        message.isHidden = false
        setAccessibilityElement(false)
    }

    func beginLoading() {
        hideLoading()
        isLoading = true
        message.isHidden = true
        // A cache lookup is pending, but only a miss needs visible loading feedback.
        setAccessibilityElement(false)
    }

    func showLoading(filename: String) {
        beginLoading()
        loadingFilename.stringValue = "Loading \(filename)"
        loadingFilename.toolTip = filename
        loadingBox.isHidden = false
        progress.startAnimation(nil)
    }

    private func hideLoading() {
        isLoading = false
        progress.stopAnimation(nil)
        loadingBox.isHidden = true
    }

    func resetZoom(to mode: ViewingMode = .fit) {
        zoom.reset(to: mode)
        zoomChanged?()
        needsDisplay = true
    }

    /// "Fit, 12%" while fitted, otherwise the current percentage; 100% is one source pixel per backing pixel.
    var zoomDescription: String {
        guard image != nil else { return "" }
        let percent = Int((scale * 100).rounded())
        return zoom.scale == nil ? "Fit, \(percent)%" : "\(percent)%"
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        message.updateHeadlineSize()
        needsDisplay = true
        zoomChanged?()
    }

    private var scale: Double {
        guard let image else { return 1 }
        // Fit leaves a 30-point margin; actual size and panning still use the whole viewport.
        let fitArea = NSSize(width: max(1, bounds.width - 60), height: max(1, bounds.height - 60))
        let backing = convertToBacking(fitArea)
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
        // Shadows only matter when the whole image is visible; skipping them keeps panning large images cheap.
        if bounds.contains(rect) { drawShadow(around: rect, in: context) }
        context.saveGState()
        context.addPath(imageShape(rect))
        context.clip()
        context.interpolationQuality = scale >= 1 ? .none : .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// CGPath requires corner radii no larger than half the rect, which tiny zoomed-out images can violate.
    private func imageShape(_ rect: CGRect) -> CGPath {
        let radius = min(3, rect.width / 2, rect.height / 2)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Two soft shadows, clipped to outside the image so transparent pixels never reveal a backing fill.
    private func drawShadow(around rect: CGRect, in context: CGContext) {
        let dark = Theme.isDark(effectiveAppearance)
        let tint = dark ? CGColor(gray: 0, alpha: 1) : CGColor(red: 20 / 255, green: 22 / 255, blue: 30 / 255, alpha: 1)
        // (y offset, blur, opacity, negative spread) per layer, matching the D9 photo shadow.
        let layers: [(CGFloat, CGFloat, CGFloat, CGFloat)] =
            dark ? [(2, 8, 0.5, 0), (40, 120, 0.85, 20)] : [(1, 3, 0.14, 0), (30, 80, 0.42, 26)]
        context.saveGState()
        let outside = CGMutablePath()
        outside.addRect(bounds)
        outside.addPath(imageShape(rect))
        context.addPath(outside)
        context.clip(using: .evenOdd)
        for (offset, blur, opacity, spread) in layers {
            context.setShadow(
                offset: CGSize(width: 0, height: -offset), blur: blur, color: tint.copy(alpha: opacity) ?? tint)
            context.setFillColor(tint)
            context.fill(rect.insetBy(dx: min(spread, rect.width / 2), dy: min(spread, rect.height / 2)))
        }
        context.restoreGState()
    }

    override func scrollWheel(with event: NSEvent) {
        guard image != nil, event.scrollingDeltaY != 0 else { return }
        // Normalize natural scrolling so a physical upward gesture always zooms in.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        zoom.scroll(up: delta > 0, currentScale: scale)
        zoomChanged?()
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
            zoomChanged?()
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
