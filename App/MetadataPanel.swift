import AppKit
import LuloImaging

/// The floating metadata panel. It sits beside the image rather than over it, so the image area still shrinks.
@MainActor
final class MetadataPanel: NSView {
    /// TextKit 1 because TextKit 2 does not draw the text-block borders used as group hairlines.
    let text = NSTextView(usingTextLayoutManager: false)
    private let name = NSTextField(wrappingLabelWithString: "")
    private let captured = NSTextField(labelWithString: "")
    private let chip = RatingChip()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let surface = PanelView(fill: Theme.panelFill, radius: 18)
        pin(surface, in: self, insets: NSEdgeInsets(top: 0, left: 0, bottom: 14, right: 14))
        name.isSelectable = true
        name.textColor = Theme.textPrimary
        name.lineBreakMode = .byCharWrapping
        captured.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        captured.textColor = Theme.textSecondary
        let subtitle = NSStackView(views: [captured, chip])
        subtitle.spacing = 8
        subtitle.detachesHiddenViews = true
        let header = NSStackView(views: [name, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(header)

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.textContainerInset = NSSize(width: 15, height: 0)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.setAccessibilityLabel("Image metadata")
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(scroll)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 314),
            header.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -20),
            name.widthAnchor.constraint(equalTo: header.widthAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 0),
            scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 5),
            scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -5),
            scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -12),
        ])
        clear()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Cleared while loading so old values cannot be mistaken for the incoming file.
    func clear() {
        name.stringValue = ""
        captured.stringValue = ""
        chip.rating = nil
        text.string = ""
    }

    func show(_ details: ImageDetails) {
        name.attributedStringValue = Theme.headline(
            details.entry.url.lastPathComponent, size: 20, weight: .bold, tracking: -0.02)
        captured.stringValue = details.captureWallClock.map(Theme.captureText) ?? ""
        captured.isHidden = captured.stringValue.isEmpty
        chip.rating = details.entry.rating
        let content = NSMutableAttributedString()
        for group in details.groups where !group.fields.isEmpty {
            // Each group is one text block whose top border is the hairline separating it from the previous one.
            let block = NSTextBlock()
            block.setValue(100, type: .percentageValueType, for: .width)
            block.setWidth(0.5, type: .absoluteValueType, for: .border, edge: .minY)
            block.setBorderColor(Theme.panelStroke, for: .minY)
            block.setWidth(12, type: .absoluteValueType, for: .margin, edge: .minY)
            block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minY)
            func append(_ string: String, font: NSFont, color: NSColor, spacingAfter: CGFloat) {
                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.paragraphSpacing = spacingAfter
                paragraph.lineBreakMode = .byCharWrapping
                content.append(
                    NSAttributedString(
                        string: string + "\n",
                        attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]))
            }
            append(group.name, font: .systemFont(ofSize: 12, weight: .bold), color: Theme.textPrimary, spacingAfter: 8)
            for field in group.fields {
                append(field.name, font: .systemFont(ofSize: 11), color: Theme.textTertiary, spacingAfter: 1)
                append(
                    field.value, font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular),
                    color: Theme.textPrimary, spacingAfter: 7)
            }
        }
        text.textStorage?.setAttributedString(content)
        text.scrollToBeginningOfDocument(nil)
    }
}
