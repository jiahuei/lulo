import AppKit
import CoreImage
import LuloCore
import LuloImaging
import QuartzCore

@MainActor
final class RatingChip: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        textColor = Theme.textPrimary
    }
    func setRating(_ value: Int?) {
        guard let value, (1...5).contains(value) else {
            stringValue = ""
            isHidden = true
            return
        }
        let text = NSMutableAttributedString(
            string: "★ \(value)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Theme.textPrimary,
            ])
        text.addAttribute(.foregroundColor, value: Theme.star, range: NSRange(location: 0, length: 1))
        attributedStringValue = text
        invalidateIntrinsicContentSize()
        let label = "\(value) \(value == 1 ? "star" : "stars")"
        setAccessibilityLabel(label)
        toolTip = label
        isHidden = false
    }
    override var intrinsicContentSize: NSSize {
        let size = attributedStringValue.size()
        return NSSize(width: size.width + 10, height: size.height + 6)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard !stringValue.isEmpty else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        path.fill()
        Theme.hairline.setStroke()
        path.lineWidth = 0.5
        path.stroke()
        let size = attributedStringValue.size()
        attributedStringValue.draw(
            in: NSRect(
                x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                width: size.width, height: size.height))
    }
}

@MainActor
final class BreadcrumbView: NSView {
    private let symbol = NSImageView()
    private let parent = NSTextField(labelWithString: "")
    private let parentSlash = NSTextField(labelWithString: "/")
    private let folder = NSButton()
    private let folderLabel = NSTextField(labelWithString: "")
    private let fileSlash = NSTextField(labelWithString: "/")
    private let filename = NSTextField(labelWithString: "")
    private let row = NSStackView()
    private var folderWidth: NSLayoutConstraint?
    var showGallery: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Current location")
        symbol.image = Theme.symbol("folder", size: 12, weight: .regular)
        symbol.contentTintColor = Theme.textTertiary
        symbol.setAccessibilityElement(false)
        folder.isBordered = false
        folder.font = .systemFont(ofSize: 13, weight: .medium)
        folderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        folderLabel.textColor = Theme.textPrimary
        folderLabel.lineBreakMode = .byTruncatingTail
        folder.lineBreakMode = .byTruncatingTail
        folder.target = self
        folder.action = #selector(openGallery)
        folder.toolTip = "Show gallery"
        filename.font = .systemFont(ofSize: 13, weight: .semibold)
        filename.lineBreakMode = .byTruncatingMiddle
        filename.textColor = Theme.textPrimary
        parent.font = .systemFont(ofSize: 13)
        parent.lineBreakMode = .byTruncatingTail
        parent.textColor = Theme.textSecondary
        parentSlash.textColor = Theme.textTertiary
        fileSlash.textColor = Theme.textTertiary
        for child in [symbol, parent, parentSlash, folder, folderLabel, fileSlash, filename] {
            row.addArrangedSubview(child)
        }
        row.spacing = 7
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor), symbol.widthAnchor.constraint(equalToConstant: 14),
            symbol.heightAnchor.constraint(equalToConstant: 14),
        ])
        parent.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        parent.widthAnchor.constraint(lessThanOrEqualToConstant: 96).isActive = true
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filename.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        folderWidth = folder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.5)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(file: URL?, authorizedFolder: URL?, gallery: Bool, windowWidth: CGFloat) {
        let hasFolder = authorizedFolder != nil
        let narrow = windowWidth < 1000
        folderWidth?.isActive = hasFolder && !gallery && file != nil
        symbol.isHidden = !hasFolder
        parent.isHidden = !hasFolder || narrow
        parentSlash.isHidden = parent.isHidden
        parent.stringValue = authorizedFolder?.deletingLastPathComponent().lastPathComponent ?? ""
        folder.isHidden = !hasFolder || gallery
        folderLabel.isHidden = !hasFolder || !gallery
        folder.title = authorizedFolder?.lastPathComponent ?? ""
        folderLabel.stringValue = folder.title
        folder.contentTintColor = Theme.textSecondary
        folder.setAccessibilityLabel("Show gallery, \(folder.title)")
        fileSlash.isHidden = !hasFolder || gallery || file == nil
        filename.isHidden = gallery || file == nil
        filename.stringValue = file?.lastPathComponent ?? ""
        toolTip = (gallery ? authorizedFolder : file)?.path
        setAccessibilityValue(toolTip)
    }
    @objc private func openGallery() { showGallery?() }
}

struct BackgroundImages: @unchecked Sendable {
    let light: CGImage
    let dark: CGImage
}

// Only the current thumbnail variants are retained. Core Image work has its own actor
// so it cannot delay full-resolution decoding or gallery thumbnails.
actor BackgroundRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    func render(_ thumbnail: LoadedThumbnail) -> BackgroundImages? {
        let source = CIImage(cgImage: thumbnail.image)
        let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 24])
        func variant(saturation: Double, brightness: Double) -> CGImage? {
            let colored = blurred.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: saturation])
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: brightness, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: brightness, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: brightness, w: 0),
                    ])
            return context.createCGImage(colored, from: source.extent)
        }
        guard let light = variant(saturation: 1.5, brightness: 1.06),
            let dark = variant(saturation: 1.6, brightness: 0.55)
        else { return nil }
        return BackgroundImages(light: light, dark: dark)
    }
}

@MainActor
final class ViewerBackground: NSView {
    private let imageLayer = CALayer()
    private let veil = CAGradientLayer()
    private let vignette = CAGradientLayer()
    private let blurLayer = CALayer()
    private var images: BackgroundImages?
    var enabled = false {
        didSet {
            guard oldValue != enabled else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.35)
            blurLayer.opacity = enabled ? 1 : 0
            CATransaction.commit()
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(blurLayer)
        blurLayer.opacity = 0
        blurLayer.addSublayer(imageLayer)
        blurLayer.addSublayer(vignette)
        blurLayer.addSublayer(veil)
        imageLayer.contentsGravity = .resizeAspectFill
        vignette.type = .radial
        vignette.startPoint = CGPoint(x: 0.5, y: 0.5)
        vignette.endPoint = CGPoint(x: 1, y: 1)
        veil.startPoint = CGPoint(x: 0.5, y: 1)
        veil.endPoint = CGPoint(x: 0.5, y: 0)
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blurLayer.frame = bounds
        imageLayer.frame = bounds.insetBy(dx: -bounds.width * 0.075, dy: -bounds.height * 0.075)
        veil.frame = bounds
        vignette.frame = bounds
        CATransaction.commit()
    }
    func setImages(_ images: BackgroundImages?) {
        self.images = images
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.5
            imageLayer.add(fade, forKey: "image")
        }
        updateAppearance()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }
    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Theme.wall.cgColor }
        imageLayer.contents = dark ? images?.dark : images?.light
        let wash = dark ? NSColor.black : NSColor(srgbRed: 0.941, green: 0.945, blue: 0.953, alpha: 1)
        veil.colors = [
            wash.withAlphaComponent(dark ? 0.18 : 0.58).cgColor,
            wash.withAlphaComponent(dark ? 0.30 : 0.70).cgColor,
        ]
        vignette.colors = [NSColor.clear.cgColor, NSColor.black.withAlphaComponent(dark ? 0.35 : 0).cgColor]
    }
}

@MainActor
final class ThumbnailSizeSlider: NSSlider {
    var galleryLayout = GalleryLayout.rows
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 125: adjust(-1)
        case 124, 126: adjust(1)
        default: super.keyDown(with: event)
        }
    }
    override func accessibilityPerformIncrement() -> Bool { adjust(1) }
    override func accessibilityPerformDecrement() -> Bool { adjust(-1) }
    @discardableResult
    private func adjust(_ steps: Int) -> Bool {
        guard isEnabled else { return false }
        doubleValue = galleryLayout.adjustedSize(doubleValue, steps: steps)
        sendAction(action, to: target)
        return true
    }
}
