import AppKit

enum AddressAppearance {
    static let cornerRadius: CGFloat = 12
    static let textWeight: NSFont.Weight = .regular
    static let textSize: CGFloat = 13.5
    static let maximumSuggestions = 8
    static let headerHeight: CGFloat = 46
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 4
    static let inset: CGFloat = 7

    static func textColor(_ theme: RiseTheme) -> NSColor {
        theme == .dark ? NSColor(hex: 0xFFFFFF) : theme.text
    }
    static func background(_ theme: RiseTheme) -> NSColor {
        NSColor(hex: theme == .dark ? 0x2D2D2D : 0xF8F8F8)
    }
    static func selection(_ theme: RiseTheme) -> NSColor {
        NSColor(hex: theme == .dark ? 0x4B4B4A : 0xE5E5E5)
    }
}
