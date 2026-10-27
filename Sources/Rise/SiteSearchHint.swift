import AppKit

/// "Search Amazon" and a Tab keycap at the end of the address, offering the site's own search.
/// After Tab, "Search" and the keycap fade, and the site's name takes its colour and springs over
/// to the end, where the keycap was; Escape puts it all back.
@MainActor final class SiteSearchHint: FlippedView {
    static let gap: CGFloat = 8, keyHeight: CGFloat = 20, keyPadding: CGFloat = 6, keySize: CGFloat = 11
    /// The find bar's Ask button on iOS: quick, with a light bounce.
    static let slideDuration: CGFloat = 0.3, slideBounce: CGFloat = 0.25
    private let searchText = CATextLayer(), nameText = CATextLayer()
    /// Its own layer so it can shrink about its center while pressed.
    let key = CALayer()
    private let keyText = CATextLayer()
    private(set) var siteName = ""
    private(set) var action = "Search"
    /// Searching the site, after Tab.
    private(set) var isSearching = false
    private var muted = NSColor.secondaryLabelColor, siteColor = NSColor.labelColor
    /// A step heavier than the address, so the offer reads apart from what's typed.
    /// The centred new tab palette's own, in place of the address palette's.
    var fontOverride: NSFont?
    private var font: NSFont { fontOverride ?? AddressAppearance.siteSearchFont }
    private var keyFont: NSFont { .systemFont(ofSize: Self.keySize, weight: .medium) }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for text in [searchText, nameText] {
            text.font = font; text.fontSize = font.pointSize; text.alignmentMode = .left
            layer?.addSublayer(text)
        }
        searchText.string = "Search "
        key.cornerRadius = 5; key.cornerCurve = .continuous
        keyText.string = "Tab"; keyText.alignmentMode = .center
        keyText.font = keyFont; keyText.fontSize = Self.keySize
        key.addSublayer(keyText); layer?.addSublayer(key)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    /// The site on offer, back at rest: "Search", its name in gray, and the keycap.
    func configure(site name: String, action: String = "Search", color: NSColor, theme: RiseTheme) {
        siteName = name; self.action = action; isSearching = false
        searchText.string = action+" "
        nameText.string = name
        setAccessibilityLabel("Press Tab to \(action.lowercased()) \(name)")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        [searchText, nameText, key].forEach { $0.removeAllAnimations() }
        searchText.opacity = 1; key.opacity = 1; key.transform = CATransform3DIdentity
        CATransaction.commit()
        applyTheme(theme, siteColor: color)
        needsLayout = true
    }
    func applyTheme(_ theme: RiseTheme, siteColor: NSColor) {
        muted = theme.muted; self.siteColor = siteColor
        CATransaction.begin(); CATransaction.setDisableActions(true)
        searchText.foregroundColor = muted.cgColor
        nameText.foregroundColor = (isSearching ? siteColor : muted).cgColor
        key.backgroundColor = theme.text.withAlphaComponent(theme == .dark ? 0.13 : 0.08).cgColor
        keyText.foregroundColor = muted.cgColor
        CATransaction.commit()
    }
    /// Takes up a changed font (`AddressAppearance.siteSearchFont`).
    func applyFont() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for text in [searchText, nameText] { text.font = font; text.fontSize = font.pointSize }
        CATransaction.commit()
        needsLayout = true
    }
    private func width(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
    private var searchWidth: CGFloat { width(action+" ", font) }
    private var nameWidth: CGFloat { width(siteName, font)+2 }
    private var keyWidth: CGFloat { width("Tab", keyFont)+2*Self.keyPadding }
    var preferredWidth: CGFloat { searchWidth+nameWidth+Self.gap+keyWidth }
    /// Where the name rests: after "Search", or at the end, in the keycap's place.
    private var nameX: CGFloat { isSearching ? bounds.width-nameWidth/2 : searchWidth+nameWidth/2 }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let line = ceil(font.boundingRectForFont.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        searchText.frame = CGRect(x: 0, y: (bounds.height-line)/2, width: searchWidth+2, height: line)
        nameText.bounds = CGRect(x: 0, y: 0, width: nameWidth+2, height: line)
        nameText.position = CGPoint(x: nameX+1, y: bounds.midY)
        let width = keyWidth
        key.bounds = CGRect(x: 0, y: 0, width: width, height: Self.keyHeight)
        key.position = CGPoint(x: bounds.width-width/2, y: bounds.midY)
        let keyLine = ceil(keyFont.boundingRectForFont.height)
        keyText.frame = CGRect(x: 0, y: (Self.keyHeight-keyLine)/2+0.5, width: width, height: keyLine)
        [searchText, nameText, keyText].forEach { $0.contentsScale = scale }
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }

    /// Tab, or Escape back: "Search" and the keycap fade out (or in) while the name changes colour
    /// and springs to its place.
    func setSearching(_ searching: Bool, animated: Bool) {
        guard searching != isSearching else { return }
        isSearching = searching
        setAccessibilityLabel(searching ? "\(action == "Ask" ? "Asking" : "Searching") \(siteName)" : "Press Tab to \(action.lowercased()) \(siteName)")
        let animate = animated && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fromX = nameText.presentation()?.position.x ?? nameText.position.x
        let fromColor = nameText.presentation()?.foregroundColor ?? nameText.foregroundColor
        let fromOpacity = searchText.presentation()?.opacity ?? searchText.opacity
        let fromKeyOpacity = key.presentation()?.opacity ?? key.opacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        searchText.opacity = searching ? 0 : 1; key.opacity = searching ? 0 : 1
        nameText.foregroundColor = (searching ? siteColor : muted).cgColor
        nameText.position.x = nameX+1
        CATransaction.commit()
        guard animate else {
            [searchText, nameText, key].forEach { $0.removeAllAnimations() }
            key.transform = CATransform3DIdentity
            return
        }
        func fade(_ layer: CALayer, from: Float, duration: CFTimeInterval) {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from; fade.toValue = layer.opacity; fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "fade")
        }
        fade(searchText, from: fromOpacity, duration: searching ? 0.12 : 0.16)
        fade(key, from: fromKeyOpacity, duration: searching ? 0.12 : 0.16)
        // The keycap answers the key going down; coming back, it springs up from pressed.
        if searching { PressScale.set(key, to: 0.88) }
        else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            key.transform = CATransform3DMakeScale(0.88, 0.88, 1)
            CATransaction.commit()
            PressScale.set(key, to: 1)
        }
        let color = CABasicAnimation(keyPath: "foregroundColor")
        color.fromValue = fromColor; color.toValue = nameText.foregroundColor; color.duration = 0.16
        color.timingFunction = CAMediaTimingFunction(name: .easeOut)
        nameText.add(color, forKey: "color")
        let slide = CASpringAnimation(perceptualDuration: Self.slideDuration, bounce: Self.slideBounce)
        slide.keyPath = "position.x"
        slide.fromValue = fromX; slide.toValue = nameText.position.x
        slide.duration = slide.settlingDuration
        nameText.add(slide, forKey: "slide")
    }
    /// Where the name is drawn, for checks.
    var nameFrame: CGRect { nameText.presentation()?.frame ?? nameText.frame }
}
