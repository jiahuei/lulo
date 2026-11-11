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
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
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

}
