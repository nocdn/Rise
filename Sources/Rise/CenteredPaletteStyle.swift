import AppKit

/// The address palette's look, for a new tab (⌘T) and the current page's address (⌘L) alike,
/// after Kero's command palette (github.com/egoist/kero, palette.go,
/// theme.go and elevation.go): centred over a dim veil across the window, on white, with the
/// system font, a blue tint for the chosen row, and each row's address beside its title.
@MainActor enum CenteredPaletteStyle {
    static let width: CGFloat = 600
    /// The tallest it gets; the palette is placed so that, this tall, it's centred.
    static let maximumHeight: CGFloat = 460
    static let cornerRadius: CGFloat = 14
    static let fieldHeight: CGFloat = 50
    static let fieldPadding: CGFloat = 16
    static let fieldIconSize: CGFloat = 16
    static let gap: CGFloat = 10
    static let fieldFont = NSFont.systemFont(ofSize: 15)
    /// "Search Hacker News": the field's size, a weight heavier than what's typed, at 500 on SF's
    /// weight axis ('wght'), Medium.
    static let siteSearchFont: NSFont = {
        let variation = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: [NSNumber(value: 0x7767_6874): 500]] as CFDictionary)
        return CTFontCreateCopyWithAttributes(fieldFont as CTFont, fieldFont.pointSize, nil, variation) as NSFont
    }()
    /// Around the rows.
    static let listPadding: CGFloat = 6
    static let rowHeight: CGFloat = 38
    static let rowPadding: CGFloat = 10
    static let rowRadius: CGFloat = 8
    static let rowIconSize: CGFloat = 14
    static let titleFont = NSFont.systemFont(ofSize: 13.5)
    static let detailFont = NSFont.systemFont(ofSize: 12.5)
    static let titleMaximumWidth: CGFloat = 300

    /// The most rows the tallest palette shows; a longer list scrolls, a whole row at a time.
    static let visibleRows = Int((maximumHeight-fieldHeight-2*listPadding)/rowHeight)
    static func height(rows: Int) -> CGFloat {
        rows == 0 ? fieldHeight : fieldHeight + 2*listPadding + CGFloat(min(rows, visibleRows))*rowHeight
    }

    private static func dark(_ theme: RiseTheme) -> Bool { theme == .dark }
    static func background(_ theme: RiseTheme) -> NSColor { NSColor(hex: dark(theme) ? 0x232327 : 0xFFFFFF) }
    /// Over the whole window, behind the palette.
    static func veil(_ theme: RiseTheme) -> NSColor {
        dark(theme) ? NSColor.black.withAlphaComponent(0.35) : NSColor(srgbRed: 10/255, green: 10/255, blue: 30/255, alpha: 0.12)
    }
    static func accent(_ theme: RiseTheme) -> NSColor { NSColor(hex: dark(theme) ? 0x6B93FF : 0x3B6CF6) }
    static func selection(_ theme: RiseTheme) -> NSColor { accent(theme).withAlphaComponent(0.12) }
    static func hover(_ theme: RiseTheme) -> NSColor { (dark(theme) ? NSColor.white : .black).withAlphaComponent(dark(theme) ? 0.05 : 0.04) }
    /// What's typed.
    static func fieldText(_ theme: RiseTheme) -> NSColor { NSColor(hex: dark(theme) ? 0xF4F4F5 : 0x18181B) }
    static func placeholder(_ theme: RiseTheme) -> NSColor { NSColor(hex: dark(theme) ? 0xA1A1AA : 0x71717A) }
    static func fieldIcon(_ theme: RiseTheme) -> NSColor { NSColor(hex: dark(theme) ? 0xA9A9B4 : 0x6E6E78) }
    static func title(_ theme: RiseTheme) -> NSColor { NSColor(hex: dark(theme) ? 0xECECF0 : 0x1D1D1F) }
    /// Rows' addresses and symbols.
    static func detail(_ theme: RiseTheme) -> NSColor { NSColor(hex: dark(theme) ? 0x83838F : 0xA3A3AD) }
    /// In the dark, a hairline lit edge, as shadows hardly show there.
    static func border(_ theme: RiseTheme) -> (color: NSColor, width: CGFloat) {
        dark(theme) ? (NSColor(hex: 0xECECF0).withAlphaComponent(0.12), 1) : (.clear, 0)
    }
    /// The two shadows, CSS-like (offset y, blur, colour): a tight one at the edge and a wide
    /// soft one below.
    static func shadows(_ theme: RiseTheme) -> (tight: (CGFloat, CGFloat, NSColor), wide: (CGFloat, CGFloat, NSColor)) {
        dark(theme)
            ? ((4, 6, NSColor.black.withAlphaComponent(0.24)), (16, 40, NSColor.black.withAlphaComponent(0.45)))
            : ((1, 3, NSColor.black.withAlphaComponent(0.07)), (16, 40, NSColor(srgbRed: 20/255, green: 20/255, blue: 40/255, alpha: 0.14)))
    }

    /// Kero's search glyph: Framework7 Icons' `search` (MIT, © Vladimir Kharlampidi).
    static let searchIcon: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 56 56"><path fill="#000" d="M23.957 41.77a18.02 18.02 0 0 0 10.477-3.376l11.109 11.11a2.66 2.66 0 0 0 1.898.773c1.524 0 2.625-1.172 2.625-2.672c0-.703-.234-1.359-.75-1.874L38.277 34.668c2.32-3.047 3.703-6.820 3.703-10.922c0-9.914-8.109-18.023-18.023-18.023c-9.937 0-18.023 8.109-18.023 18.023S14.02 41.770 23.957 41.770m0-3.891c-7.758 0-14.133-6.398-14.133-14.133S16.2 9.613 23.957 9.613c7.734 0 14.133 6.399 14.133 14.133c0 7.735-6.399 14.133-14.133 14.133"/></svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? AddressAppearance.searchIcon
        image.size = NSSize(width: 16, height: 16); image.isTemplate = true; image.accessibilityDescription = "Search"
        return image
    }()
}
