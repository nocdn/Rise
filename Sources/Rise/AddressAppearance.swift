import AppKit

enum AddressAppearance {
    static let cornerRadius: CGFloat = 12
    static let textWeight: NSFont.Weight = .regular
    /// "Search or Enter URL…", a weight above the text typed over it.
    static let placeholderWeight: NSFont.Weight = .medium
    static let textSize: CGFloat = 13.5
    static let maximumSuggestions = 8
    static let headerHeight: CGFloat = 46
    static let newTabHeaderHeight: CGFloat = 50
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 4
    static let inset: CGFloat = 7

    static func textColor(_ theme: RiseTheme) -> NSColor {
        theme == .dark ? NSColor(hex: 0xFFFFFF) : theme.text
    }
    static func background(_ theme: RiseTheme) -> NSColor {
        NSColor(hex: theme == .dark ? 0x2D2D2D : 0xF8F8F8)
    }
    /// Selected text in the address, an autofilled address among it: a light gray, not blue.
    static func textSelection(_ theme: RiseTheme) -> NSColor {
        NSColor(hex: theme == .dark ? 0x4B4B4A : 0xDCDCDC)
    }
    static func selection(_ theme: RiseTheme) -> NSColor {
        NSColor(hex: theme == .dark ? 0x4B4B4A : 0xE5E5E5)
    }
    /// The iOS app's search glyph (`SearchPanel.searchIcon`): the system's bold magnifying glass,
    /// redrawn with its handle as thick as its ring and about as long. Here it's drawn at 4/5 of
    /// its 16 points, centred in them, with a lighter 1.8-point stroke beside smaller text.
    static let searchIcon: NSImage = {
        let scale: CGFloat = 0.8, inset = 8*(1-scale)
        let line: CGFloat = 1.8, outerRadius = 7.33*scale
        let centre = CGPoint(x: inset+7.4*scale, y: inset+7.4*scale), radius = outerRadius-line/2
        // The handle's tip, round cap included, from the ring's centre; the symbol's reaches 11.8.
        let tip = 11.9*scale, diagonal = 1/CGFloat(2).squareRoot()
        let point = { (distance: CGFloat) in CGPoint(x: centre.x+distance*diagonal, y: centre.y+distance*diagonal) }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: centre.x-radius, y: centre.y-radius, width: 2*radius, height: 2*radius))
            ring.lineWidth = line; ring.stroke()
            let handle = NSBezierPath()
            handle.move(to: point(radius)); handle.line(to: point(tip-line/2))
            handle.lineWidth = line; handle.lineCapStyle = .round; handle.stroke()
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = "Search"
        return image
    }()
}
