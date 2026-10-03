import AppKit

/// Geometry measured at 2× from the Dia references. Opacities are verified
/// against Dia's TabUI color assets; selected fill is the rendered reference.
@MainActor enum TabAppearance {
    static let height: CGFloat = 34
    static let developerHeight: CGFloat = 37
    static let splitDeveloperHeight: CGFloat = 44
    static let spacing: CGFloat = 3
    static let inset: CGFloat = 6
    static let radius: CGFloat = 11
    static func selectedFill(_ theme: RiseTheme) -> NSColor {
        theme == .neutral ? NSColor(hex: 0xFAFAFA) : theme.selectedTab
    }
    static func hoverFill(_ theme: RiseTheme) -> NSColor {
        theme == .rose ? theme.hoveredTab : .white.withAlphaComponent(theme == .dark ? 0.16 : 0.55)
    }
    static func text(_ theme: RiseTheme, selected: Bool) -> NSColor {
        if theme == .rose { return selected ? theme.selectedText : theme.text }
        return (theme == .dark ? NSColor.white : .black).withAlphaComponent(selected ? 1 : theme == .dark ? 0.78 : 0.68)
    }
    static func shadow(_ theme: RiseTheme) -> NSShadow {
        chromeShadow(opacity: theme == .dark ? 0.15 : 0.12, blur: 16, offset: 0, color: theme == .dark ? .white : .black)
    }
}

/// Shared title metrics with AppKit's normal font rendering.
final class TabTitleField: FadingTextField {
    override init(frame: NSRect) {
        super.init(frame: frame); font = .systemFont(ofSize: 13)
    }
    required init?(coder: NSCoder) { fatalError() }
}
