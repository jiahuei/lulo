import AppKit

/// D9 palette, type, and glyphs. Colours resolve per appearance at draw time, which AppKit may do off the main
/// thread, so nothing here is main-actor isolated.
enum Theme {
    static let wall = color(light: rgb(0xECEDEF), dark: rgb(0x101213))
    static let textPrimary = color(light: rgb(0x1D1D1F), dark: rgb(0xF0F3F1))
    static let textSecondary = color(light: rgb(0x6E6E73), dark: rgb(0x98A29E))
    static let textTertiary = color(light: rgb(0x9A9AA0), dark: rgb(0x6E7974))
    static let hairline = color(light: .black.withAlphaComponent(0.10), dark: rgb(0x2B3031))
    static let hoverFill = color(light: .black.withAlphaComponent(0.05), dark: .white.withAlphaComponent(0.05))
    // The system accent keeps selection consistent with the person's chosen highlight; dark text is lightened.
    static let accent = NSColor.controlAccentColor
    static let accentText = color(
        light: .controlAccentColor, dark: NSColor.controlAccentColor.blended(withFraction: 0.45, of: .white) ?? .white)
    static let star = color(light: rgb(0xD99A00), dark: rgb(0xFFD54A))
    static let pillStar = rgb(0xFFD54A)
    static let capsuleFill = color(light: .white.withAlphaComponent(0.78), dark: rgb(0x181B1C, alpha: 0.80))
    static let capsuleStroke = color(light: .black.withAlphaComponent(0.07), dark: rgb(0x2B3031))
    static let onFill = color(light: rgb(0x1D1D1F), dark: .white.withAlphaComponent(0.92))
    static let onText = color(light: .white, dark: rgb(0x111111))
    static let panelFill = color(light: .white.withAlphaComponent(0.66), dark: rgb(0x171A1B, alpha: 0.84))
    static let panelStroke = color(light: .black.withAlphaComponent(0.08), dark: rgb(0x2B3031))
    static let solidPanel = color(light: rgb(0xFAFAFB, alpha: 0.86), dark: rgb(0x202425, alpha: 0.95))
    static let tilePlaceholder = color(light: .black.withAlphaComponent(0.06), dark: rgb(0x202425))

    static func color(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    @MainActor static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// SF Pro Display is chosen automatically at these sizes; tracking is a fraction of the point size.
    /// An attributed string replaces a label's line-break mode, so single-line headings pass theirs explicitly.
    static func headline(
        _ text: String, size: CGFloat, weight: NSFont.Weight, tracking: CGFloat, color: NSColor = textPrimary,
        lineBreak: NSLineBreakMode = .byWordWrapping
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreak
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .kern: size * tracking,
                .foregroundColor: color, .paragraphStyle: paragraph,
            ])
    }

    static func symbol(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .medium) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
    }

    /// Draws a template image's shape in one colour, preserving its per-pixel opacity.
    static func drawTinted(_ image: NSImage, in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Eight round-capped spokes fading clockwise from 12 o'clock; each phase steps the pattern one spoke.
    /// There is no SF Symbol for this shape, and `arrow.clockwise` reads as rotating the image.
    static func refreshGlyph(phase: Int) -> NSImage {
        let opacities: [CGFloat] = [1.0, 0.88, 0.76, 0.64, 0.52, 0.42, 0.34, 0.26]
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            for spoke in 0..<8 {
                let angle = CGFloat.pi / 2 - CGFloat(spoke) * .pi / 4
                let path = NSBezierPath()
                path.lineWidth = 2.1
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: center.x + cos(angle) * 4.6, y: center.y + sin(angle) * 4.6))
                path.line(to: NSPoint(x: center.x + cos(angle) * 7.95, y: center.y + sin(angle) * 7.95))
                NSColor.black.withAlphaComponent(opacities[((spoke - phase) % 8 + 8) % 8]).setStroke()
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Wall-clock capture time; the date was decoded in UTC, so it is formatted in UTC too.
    static func captureText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyyjmm")
        return formatter.string(from: date)
    }

    /// The largest rect with the given aspect ratio centred in the bounds.
    static func fitted(_ size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        return NSRect(
            x: bounds.midX - size.width * scale / 2, y: bounds.midY - size.height * scale / 2,
            width: size.width * scale, height: size.height * scale)
    }

    static func ratingLabel(_ rating: Int) -> String { "\(rating) \(rating == 1 ? "star" : "stars")" }

    /// The "★ N" pill over thumbnails, drawn with its top-right corner at the given point.
    static func drawRatingPill(_ rating: Int, topRight: NSPoint, flipped: Bool) {
        let number = NSAttributedString(
            string: "\(rating)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
        let textSize = number.size()
        let size = NSSize(width: 5 + 9 + 3 + ceil(textSize.width) + 5, height: 16)
        let rect = NSRect(
            x: topRight.x - size.width, y: flipped ? topRight.y : topRight.y - size.height, width: size.width,
            height: size.height)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        NSColor(srgbRed: 8 / 255, green: 10 / 255, blue: 12 / 255, alpha: 0.52).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.16).setStroke()
        let stroke = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 4.75, yRadius: 4.75)
        stroke.lineWidth = 0.5
        stroke.stroke()
        if let star = symbol("star.fill", size: 8, weight: .bold) {
            drawTinted(
                star, in: fitted(star.size, in: NSRect(x: rect.minX + 5, y: rect.midY - 4.5, width: 9, height: 9)),
                color: pillStar)
        }
        number.draw(at: NSPoint(x: rect.minX + 17, y: rect.midY - textSize.height / 2))
    }
}
