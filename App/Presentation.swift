import AppKit
import CoreImage
import LuloCore
import LuloImaging
import QuartzCore

@MainActor
enum ViewerColors {
    static func color(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((value >> 16) & 255) / 255,
                green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
        }
    }
    static let wall = color(0xECEDEF, 0x101213)
    static let primary = color(0x1D1D1F, 0xF0F3F1)
    static let secondary = color(0x6E6E73, 0x98A29E)
    static let tertiary = color(0x9A9AA0, 0x6E7974)
    static let accent = color(0x0064D2, 0x4C94FF)
    static let accentText = color(0x0064D2, 0x9CC5FF)
    static let star = color(0xD99A00, 0xFFD54A)
    static let stroke = color(0xD4D5D7, 0x2B3031)
    static let placeholder = color(0xDEDFE1, 0x202425)
    static let solid = color(0xFAFAFB, 0x202425)
}

@MainActor
final class MaterialPanel: NSVisualEffectView {
    private let tint = NSView()
    private let panelRadius: CGFloat
    init(cornerRadius: CGFloat = 12) {
        panelRadius = cornerRadius
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        tint.wantsLayer = true
        tint.frame = bounds
        tint.autoresizingMask = [.width, .height]
        tint.setAccessibilityElement(false)
        addSubview(tint)
        updateSurface()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }
    private func updateSurface() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = ViewerColors.stroke.cgColor }
        tint.layer?.backgroundColor =
            (dark
            ? NSColor(srgbRed: 0.094, green: 0.106, blue: 0.11, alpha: 0.8)
            : NSColor.white.withAlphaComponent(panelRadius == 18 ? 0.66 : 0.78)).cgColor
    }
}

@MainActor
class CapsuleButton: NSButton {
    var badgeCount = 0 { didSet { needsDisplay = true } }
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
                owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let selected = state == .on
        let fill =
            selected
            ? (dark ? NSColor.white.withAlphaComponent(0.92) : ViewerColors.primary)
            : NSColor.labelColor.withAlphaComponent(hovered ? 0.05 : 0)
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 0), xRadius: 9, yRadius: 9).fill()
        let tint = selected ? (dark ? NSColor(calibratedWhite: 0.067, alpha: 1) : .white) : ViewerColors.secondary
        if let image = image?.copy() as? NSImage {
            image.lockFocus()
            tint.setFill()
            NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
            image.unlockFocus()
            image.isTemplate = false
            image.draw(
                in: NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18),
                from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.32)
        }
        if badgeCount > 0 {
            let badge = NSRect(
                x: bounds.maxX - 14, y: isFlipped ? bounds.minY + 1 : bounds.maxY - 14, width: 13, height: 13)
            ViewerColors.star.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let number = NSAttributedString(
                string: String(badgeCount),
                attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.black,
                ])
            number.draw(at: NSPoint(x: badge.midX - number.size().width / 2, y: badge.midY - number.size().height / 2))
        }
        if window?.firstResponder === self {
            ViewerColors.accent.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}

@MainActor
final class CapsuleSegments: NSSegmentedControl {
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let width = bounds.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let rect = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height).insetBy(
                dx: 1, dy: 0)
            let selected = selectedSegment == index
            if selected {
                (dark ? NSColor.white.withAlphaComponent(0.92) : ViewerColors.primary).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
            }
            let color: NSColor =
                selected ? (dark ? NSColor(calibratedWhite: 0.067, alpha: 1) : .white) : ViewerColors.secondary
            if let image = image(forSegment: index)?.copy() as? NSImage {
                image.lockFocus()
                color.setFill()
                NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
                image.unlockFocus()
                image.isTemplate = false
                image.draw(
                    in: NSRect(x: rect.midX - 8, y: rect.midY - 8, width: 16, height: 16),
                    from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.32)
            } else {
                let text = NSAttributedString(
                    string: label(forSegment: index) ?? "",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color,
                    ])
                text.draw(at: NSPoint(x: rect.midX - text.size().width / 2, y: rect.midY - text.size().height / 2))
            }
        }
        if window?.firstResponder === self {
            ViewerColors.accent.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9)
            ring.lineWidth = 2
            ring.stroke()
        }
    }
}

@MainActor
final class RatingChip: NSTextField {
    convenience init() {
        self.init(labelWithString: "")
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        textColor = ViewerColors.primary
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
                .foregroundColor: ViewerColors.primary,
            ])
        text.addAttribute(.foregroundColor, value: ViewerColors.star, range: NSRange(location: 0, length: 1))
        attributedStringValue = text
        let label = "\(value) \(value == 1 ? "star" : "stars")"
        setAccessibilityLabel(label)
        toolTip = label
        isHidden = false
    }
    override func draw(_ dirtyRect: NSRect) {
        if !stringValue.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
            path.fill()
            ViewerColors.stroke.setStroke()
            path.lineWidth = 0.5
            path.stroke()
        }
        super.draw(dirtyRect)
    }
}

@MainActor
final class BreadcrumbView: NSView {
    private let symbol = NSImageView()
    private let parent = NSTextField(labelWithString: "")
    private let parentSlash = NSTextField(labelWithString: "/")
    private let folder = NSButton()
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
        symbol.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        symbol.contentTintColor = ViewerColors.tertiary
        symbol.setAccessibilityElement(false)
        folder.isBordered = false
        folder.font = .systemFont(ofSize: 13, weight: .semibold)
        folder.lineBreakMode = .byTruncatingTail
        folder.target = self
        folder.action = #selector(openGallery)
        folder.toolTip = "Show gallery"
        filename.font = .systemFont(ofSize: 13, weight: .semibold)
        filename.lineBreakMode = .byTruncatingMiddle
        filename.textColor = ViewerColors.primary
        parent.font = .systemFont(ofSize: 13)
        parent.lineBreakMode = .byTruncatingTail
        parent.textColor = ViewerColors.secondary
        parentSlash.textColor = ViewerColors.tertiary
        fileSlash.textColor = ViewerColors.tertiary
        for child in [symbol, parent, parentSlash, folder, fileSlash, filename] { row.addArrangedSubview(child) }
        row.spacing = 5
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
        folder.isHidden = !hasFolder
        folder.title = authorizedFolder?.lastPathComponent ?? ""
        folder.isEnabled = !gallery
        folder.contentTintColor = gallery ? ViewerColors.primary : ViewerColors.secondary
        folder.setAccessibilityLabel(gallery ? folder.title : "Show gallery, \(folder.title)")
        fileSlash.isHidden = !hasFolder || gallery || file == nil
        filename.isHidden = gallery || file == nil
        filename.stringValue = file?.lastPathComponent ?? ""
        toolTip = (gallery ? authorizedFolder : file)?.path
        setAccessibilityValue(toolTip)
    }
    @objc private func openGallery() { showGallery?() }
}

@MainActor
func refreshWheel() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let alphas: [Double] = [1, 0.88, 0.76, 0.64, 0.52, 0.42, 0.34, 0.26]
        for index in 0..<8 {
            let angle = .pi / 2 - Double(index) * .pi / 4
            NSColor.black.withAlphaComponent(alphas[index]).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2.1
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: 9 + cos(angle) * 4.6, y: 9 + sin(angle) * 4.6))
            path.line(to: NSPoint(x: 9 + cos(angle) * 9, y: 9 + sin(angle) * 9))
            path.stroke()
        }
        return true
    }
    image.isTemplate = true
    return image
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
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = ViewerColors.wall.cgColor }
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
    var step = 10.0
    var keyboardAdjustment = false
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 123 || event.keyCode == 124 else {
            super.keyDown(with: event)
            return
        }
        keyboardAdjustment = true
        doubleValue = min(maxValue, max(minValue, doubleValue + (event.keyCode == 124 ? step : -step)))
        sendAction(action, to: target)
        keyboardAdjustment = false
    }
}

@MainActor
final class MetadataTextView: NSTextView {
    var dividerLocations: [Int] = []
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer else { return }
        ViewerColors.stroke.setStroke()
        for location in dividerLocations where location < (string as NSString).length {
            let glyphs = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            let y = rect.minY + textContainerOrigin.y - 8
            let rule = NSBezierPath()
            rule.lineWidth = 0.5
            rule.move(to: NSPoint(x: textContainerInset.width, y: y))
            rule.line(to: NSPoint(x: bounds.width - textContainerInset.width, y: y))
            rule.stroke()
        }
    }
}
