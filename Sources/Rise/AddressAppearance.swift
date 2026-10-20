import AppKit

enum AddressAppearance {
    /// Every value below, Rise's own unless the palette lab changes them.
    nonisolated(unsafe) static var tuning = AddressTuning()
    static var cornerRadius: CGFloat { tuning.cornerRadius }
    static let textWeight: NSFont.Weight = .regular
    /// "Search or Enter URL…", a weight above the text typed over it.
    static let placeholderWeight: NSFont.Weight = .medium
    static var textSize: CGFloat { tuning.textSize }
    /// The palette's text, its suggestions and their addresses: Inter at 450. Its placeholder a
    /// touch heavier, and a site's search offer heavier again, to read apart from what's typed.
    @MainActor static var textFont: NSFont { tuning.font(size: tuning.textSize, weight: tuning.textWeight) }
    @MainActor static var placeholderFont: NSFont { tuning.font(size: tuning.placeholderSize, weight: tuning.placeholderWeight) }
    @MainActor static var siteSearchFont: NSFont { tuning.font(size: tuning.siteSearchSize, weight: tuning.siteSearchWeight) }
    @MainActor static var rowFont: NSFont { tuning.font(size: tuning.rowSize, weight: tuning.rowWeight) }
    @MainActor static var addressFont: NSFont { tuning.font(size: tuning.addressSize, weight: tuning.addressWeight) }
    /// Suggestion rows' letters, spaced a little apart.
    static var rowKern: CGFloat { tuning.rowKern }
    static let maximumSuggestions = 8
    static var headerHeight: CGFloat { tuning.headerHeight }
    static var newTabHeaderHeight: CGFloat { tuning.newTabHeaderHeight }
    static var rowHeight: CGFloat { tuning.rowHeight }
    static var rowSpacing: CGFloat { tuning.rowSpacing }
    static var inset: CGFloat { tuning.inset }

    static func textColor(_ theme: RiseTheme) -> NSColor {
        tuning.color(.text) ?? themeColor(.text, theme)
    }
    static func background(_ theme: RiseTheme) -> NSColor {
        tuning.color(.background) ?? themeColor(.background, theme)
    }
    /// Selected text in the address, an autofilled address among it: a light gray, not blue.
    static func textSelection(_ theme: RiseTheme) -> NSColor {
        tuning.color(.textSelection) ?? themeColor(.textSelection, theme)
    }
    static func selection(_ theme: RiseTheme) -> NSColor {
        tuning.color(.rowSelection) ?? themeColor(.rowSelection, theme)
    }
    /// The placeholder, and rows' addresses.
    static func secondary(_ theme: RiseTheme) -> NSColor { tuning.color(.secondary) ?? themeColor(.secondary, theme) }
    /// The field's search glyph and rows' symbols.
    static func iconColor(_ theme: RiseTheme) -> NSColor { tuning.color(.icon) ?? themeColor(.icon, theme) }
    static func border(_ theme: RiseTheme) -> NSColor { tuning.color(.border) ?? themeColor(.border, theme) }
    static func shadow(_ theme: RiseTheme) -> NSShadow {
        chromeShadow(opacity: tuning.shadowOpacity ?? defaultShadowOpacity(theme), blur: tuning.shadowBlur, offset: -tuning.shadowOffset,
                     color: tuning.color(.shadow) ?? themeColor(.shadow, theme))
    }
    static func defaultShadowOpacity(_ theme: RiseTheme) -> CGFloat { theme == .dark ? 0.4 : 0.22 }
    /// Each colour as the theme has it.
    static func themeColor(_ role: AddressTuning.ColorRole, _ theme: RiseTheme) -> NSColor {
        switch role {
        case .background: NSColor(hex: theme == .dark ? 0x2D2D2D : 0xF8F8F8)
        case .border: theme.border
        case .text: theme == .dark ? NSColor(hex: 0xFFFFFF) : theme.text
        case .secondary, .icon: theme.muted
        case .rowSelection: NSColor(hex: theme == .dark ? 0x4B4B4A : 0xE5E5E5)
        case .textSelection: NSColor(hex: theme == .dark ? 0x4B4B4A : 0xDCDCDC)
        case .shadow: .black
        }
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
