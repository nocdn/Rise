import AppKit

/// "Search Amazon" and a Tab keycap at the end of the address, offering the site's own search.
@MainActor final class SiteSearchHint: FlippedView {
    static let gap: CGFloat = 8, keyHeight: CGFloat = 20, keyPadding: CGFloat = 6, keySize: CGFloat = 11
    let text = label("", size: AddressAppearance.textSize, weight: AddressAppearance.textWeight)
    /// Its own layer so it can shrink about its center while pressed.
    let key = CALayer()
    private let keyText = CATextLayer()
    private(set) var siteName = ""
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        text.lineBreakMode = .byClipping
        addSubview(text)
        key.cornerRadius = 5; key.cornerCurve = .continuous
        keyText.string = "Tab"; keyText.alignmentMode = .center
        keyText.font = NSFont.systemFont(ofSize: Self.keySize, weight: .medium); keyText.fontSize = Self.keySize
        key.addSublayer(keyText); layer?.addSublayer(key)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(site name: String, theme: RiseTheme) {
        siteName = name
        text.stringValue = "Search \(name)"; text.textColor = theme.muted
        key.backgroundColor = theme.text.withAlphaComponent(theme == .dark ? 0.13 : 0.08).cgColor
        keyText.foregroundColor = theme.muted.cgColor
        setAccessibilityLabel("Press Tab to search \(name)")
        needsLayout = true
    }
    private var keyWidth: CGFloat {
        ceil(("Tab" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Self.keySize, weight: .medium)]).width)+2*Self.keyPadding
    }
    var preferredWidth: CGFloat { ceil(text.intrinsicContentSize.width)+Self.gap+keyWidth }
    override func layout() {
        super.layout()
        let textSize = text.intrinsicContentSize
        // Fractional-width slack, so the last letter isn't clipped.
        text.frame = NSRect(x: 0, y: (bounds.height-textSize.height)/2, width: ceil(textSize.width)+4, height: textSize.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let width = keyWidth
        key.bounds = CGRect(x: 0, y: 0, width: width, height: Self.keyHeight)
        key.position = CGPoint(x: bounds.width-width/2, y: bounds.midY)
        let scale = window?.backingScaleFactor ?? 2
        keyText.contentsScale = scale
        let line = ceil(NSFont.systemFont(ofSize: Self.keySize, weight: .medium).boundingRectForFont.height)
        keyText.frame = CGRect(x: 0, y: (Self.keyHeight-line)/2+0.5, width: width, height: line)
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    /// The keycap answers the key: down, then back once the hint has gone.
    func press() { PressScale.set(key, to: 0.88) }
    func release() { PressScale.set(key, to: 1) }
    var keyScale: CGFloat { key.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? key.transform.m11 }
}
