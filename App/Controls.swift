import AppKit

/// An icon or short-text button for toolbar capsules and segmented choices, using D9's inverted "on" state.
/// Radio-type buttons are announced as radio choices with their selected state.
@MainActor
final class CapsuleButton: NSButton {
    var glyph: NSImage? {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }
    // Logical radio/toggle values remain accessible even when their buttons use momentary styling.
    var showsSelection = false { didSet { needsDisplay = true } }
    var isVisuallySelected: Bool { showsSelection && state == .on }
    var minimumWidth: CGFloat = 32 { didSet { invalidateIntrinsicContentSize() } }
    var badgeCount = 0 { didSet { needsDisplay = true } }
    private var hoverTracking: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }
    private var kind = NSButton.ButtonType.momentaryPushIn

    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    convenience init(
        symbol: String? = nil, title: String = "", label: String, type: NSButton.ButtonType = .momentaryPushIn,
        target: AnyObject?, action: Selector?
    ) {
        self.init(frame: .zero)
        kind = type
        setButtonType(type)
        isBordered = false
        self.title = title
        glyph = symbol.flatMap { Theme.symbol($0) }
        setLabel(label)
        self.target = target
        self.action = action
    }

    override func setButtonType(_ type: NSButton.ButtonType) {
        kind = type
        super.setButtonType(type)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    func setLabel(_ label: String) {
        toolTip = label
        setAccessibilityLabel(label)
    }

    // A borderless, custom-drawn button reports an unknown role, so the role and on/off value are explicit:
    // segments are radio choices and toggles are toggle buttons, as with the native controls they replace.
    override func accessibilityRole() -> NSAccessibility.Role? {
        switch kind {
        case .radio: return .radioButton
        case .pushOnPushOff, .toggle: return .checkBox
        default: return .button
        }
    }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? {
        kind == .pushOnPushOff || kind == .toggle ? .toggle : super.accessibilitySubrole()
    }

    override func accessibilityValue() -> Any? {
        kind == .momentaryPushIn ? super.accessibilityValue() : NSNumber(value: state == .on)
    }

    override var intrinsicContentSize: NSSize {
        let content = glyph?.size.width ?? attributedTitleForDrawing.size().width
        return NSSize(width: max(minimumWidth, ceil(content) + 14), height: 28)
    }

    private var attributedTitleForDrawing: NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: isVisuallySelected ? .semibold : .medium),
                .foregroundColor: contentColor,
            ])
    }

    private var contentColor: NSColor {
        isVisuallySelected ? Theme.onText : hovering && isEnabled ? Theme.textPrimary : Theme.textSecondary
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(isEnabled ? (isHighlighted ? 0.7 : 1) : 0.32)
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        if isVisuallySelected {
            Theme.onFill.setFill()
            shape.fill()
        } else if (hovering || isHighlighted) && isEnabled {
            Theme.hoverFill.setFill()
            shape.fill()
        }
        if let glyph {
            let rect = NSRect(
                x: (bounds.width - glyph.size.width) / 2, y: (bounds.height - glyph.size.height) / 2,
                width: glyph.size.width, height: glyph.size.height)
            Theme.drawTinted(glyph, in: rect.integral, color: contentColor)
        } else {
            let text = attributedTitleForDrawing
            let size = text.size()
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
        drawBadge()
    }

    private func drawBadge() {
        guard badgeCount > 0 else { return }
        let rect = NSRect(x: bounds.maxX - 14, y: isFlipped ? 1 : bounds.maxY - 14, width: 13, height: 13)
        Theme.star.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let text = NSAttributedString(
            string: String(badgeCount),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .heavy), .foregroundColor: NSColor.black,
            ])
        text.draw(at: NSPoint(x: rect.midX - text.size().width / 2, y: rect.midY - text.size().height / 2))
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTracking == nil else { return }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self,
            userInfo: nil)
        hoverTracking = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// A rounded translucent group of toolbar controls; it never overlaps the image, so a plain fill matches a blur.
@MainActor
final class CapsuleView: NSView {
    let stack: NSStackView

    init(_ views: [NSView]) {
        stack = NSStackView(views: views)
        super.init(frame: .zero)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 12, yRadius: 12)
        Theme.capsuleFill.setFill()
        shape.fill()
        shape.lineWidth = 0.5
        Theme.capsuleStroke.setStroke()
        shape.stroke()
    }
}

/// The 1 by 16 point hairline between groups inside a capsule.
@MainActor
final class HairlineDivider: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        Theme.hairline.setFill()
        NSRect(x: 3, y: (bounds.height - 16) / 2, width: 1, height: 16).fill()
    }
}

/// A rounded panel surface with a hairline stroke, used for the metadata panel and solid overlays.
@MainActor
final class PanelView: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }
    var strokes = true { didSet { needsDisplay = true } }

    init(fill: NSColor, radius: CGFloat) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        fill.setFill()
        shape.fill()
        guard strokes else { return }
        shape.lineWidth = 0.5
        Theme.panelStroke.setStroke()
        shape.stroke()
    }
}

/// D9's primary button: a dark (light in Dark Mode) rounded fill with semibold text.
@MainActor
final class ProminentButton: NSButton {
    private var text: NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: Theme.onText])
    }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        setAccessibilityRole(.button)
        isBordered = false
        self.title = title
        self.target = target
        self.action = action
    }

    override var title: String { didSet { invalidateIntrinsicContentSize() } }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(text.size().width) + 32, height: 34) }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        (isHighlighted ? Theme.onFill.withAlphaComponent(0.8) : Theme.onFill).setFill()
        shape.fill()
        let text = text
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}

/// The empty, error, and no-match message: a large headline, one supporting line, and one action.
@MainActor
final class MessageView: NSView {
    private let title = NSTextField(wrappingLabelWithString: "")
    let detail = NSTextField(wrappingLabelWithString: "")
    let button = ProminentButton(title: "", target: nil, action: nil)
    private let stack = NSStackView()
    private var action: (() -> Void)?

    var headline: String { title.stringValue }

    override init(frame: NSRect) {
        super.init(frame: frame)
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = Theme.textSecondary
        title.textColor = Theme.textPrimary
        button.target = self
        button.action = #selector(performAction)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [title, detail, button] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(22, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ headline: String, detail: String, actionTitle: String?, action: (() -> Void)?) {
        title.stringValue = headline
        self.detail.stringValue = detail
        self.detail.isHidden = detail.isEmpty
        button.title = actionTitle ?? ""
        button.isHidden = actionTitle == nil
        self.action = action
        updateHeadlineSize()
    }

    /// The headline scales with the available width between 34 and 48 points. The block takes its text's width,
    /// wrapping at 520 points (or the available width), so it can be centred while its lines stay left-aligned.
    func updateHeadlineSize() {
        let available = superview?.bounds.width ?? 0
        let width = max(200, min(520, available - 64))
        title.preferredMaxLayoutWidth = width
        detail.preferredMaxLayoutWidth = min(width, 420)
        let size = min(48, max(34, available * 0.04))
        title.attributedStringValue = Theme.headline(title.stringValue, size: size, weight: .bold, tracking: -0.03)
    }

    @objc private func performAction() { action?() }
}

/// A single-choice group made from the same native buttons as the toolbar.
@MainActor
final class ButtonChoices: NSControl {
    private let row = NSStackView()
    private(set) var buttons: [CapsuleButton] = []
    var selectedIndex = 0 { didSet { updateSelection() } }
    override var isEnabled: Bool { didSet { for button in buttons { button.isEnabled = isEnabled } } }

    init(labels: [String], symbols: [String?] = [], track: Bool = false) {
        super.init(frame: .zero)
        cell = NSActionCell()
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        row.spacing = track ? 0 : 2
        row.distribution = .fillEqually
        for (index, label) in labels.enumerated() {
            let button = CapsuleButton(
                symbol: symbols.indices.contains(index) ? symbols[index] : nil,
                title: label, label: label, type: .radio, target: self, action: #selector(choose))
            button.tag = index
            button.minimumWidth = 0
            buttons.append(button)
            row.addArrangedSubview(button)
        }
        if track {
            let surface = PanelView(fill: Theme.hoverFill, radius: 10)
            surface.strokes = false
            pin(surface, in: self)
            pin(row, in: surface, insets: NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3))
        } else {
            pin(row, in: self)
        }
        heightAnchor.constraint(equalToConstant: track ? 34 : 28).isActive = true
        updateSelection()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateSelection() {
        for (index, button) in buttons.enumerated() { button.state = index == selectedIndex ? .on : .off }
    }

    @objc private func choose(_ sender: NSButton) {
        selectedIndex = sender.tag
        sendAction(action, to: target)
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
