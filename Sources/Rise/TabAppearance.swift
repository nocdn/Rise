import AppKit

/// Geometry measured at 2× from the Dia references. Opacities are verified
/// against Dia's TabUI color assets; selected fill is the rendered reference.
@MainActor enum TabAppearance {
    static let height: CGFloat = 34
    static let subtitleRowHeight: CGFloat = 44
    static let spacing: CGFloat = 3
    static let inset: CGFloat = 6
    static let radius: CGFloat = 11
    static func repositoryColor(_ repository: String, theme: RiseTheme) -> NSColor {
        // FNV-1a gives the repo the same hue after every restart.
        let seed = repository.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        let hue = (seed % 360 + 120) % 360
        let tint = NSColor(calibratedHue: CGFloat(hue)/360, saturation: 0.62,
                           brightness: theme == .dark ? 0.8 : 0.58, alpha: 1)
        return theme.muted.blended(withFraction: 0.8, of: tint) ?? theme.muted
    }
    static func selectedFill(_ theme: RiseTheme) -> NSColor { PlainTabBackground.chosen(dark: theme == .dark) }
    static func hoverFill(_ theme: RiseTheme) -> NSColor { PlainTabBackground.hover(dark: theme == .dark) }
    /// Flatten the hover fill against the sidebar, so neighboring rows cannot show through a drag.
    static func dragFill(_ theme: RiseTheme, sidebarFraction: CGFloat) -> NSColor {
        let hover = hoverFill(theme)
        return theme.background.blended(withFraction: hover.alphaComponent, of: hover.withAlphaComponent(1))!.withAlphaComponent(1)
    }
    static func text(_ theme: RiseTheme, selected: Bool) -> NSColor {
        return (theme == .dark ? NSColor.white : .black).withAlphaComponent(selected ? 1 : theme == .dark ? 0.835 : 0.76)
    }
}

/// Shared title metrics with AppKit's normal font rendering.
final class TabTitleField: FadingTextField {
    override init(frame: NSRect) {
        super.init(frame: frame); font = .systemFont(ofSize: 13)
    }
    required init?(coder: NSCoder) { fatalError() }
}
