import AppKit
import RiseCore

final class TabPreviewCard: NSButton {
    let tabID: UUID
    private let thumbnailClip = Surface(color: NSColor(hex: 0x242424), radius: 5)
    private let preview = NSImageView()
    private let placeholder = NSImageView()
    private let icon = FaviconView(frame: .zero)
    private let titleField = label("", size: 14, weight: .semibold, color: .white)
    var choose: ((UUID) -> Void)?
    init(_ tab: BrowserTab) {
        tabID = tab.id
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true
        layer?.cornerRadius = 9; layer?.cornerCurve = .continuous
        thumbnailClip.layer?.masksToBounds = true; thumbnailClip.clipsToBounds = true
        preview.imageScaling = .scaleProportionallyUpOrDown
        thumbnailClip.addSubview(preview); thumbnailClip.addSubview(placeholder)
        placeholder.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        placeholder.contentTintColor = NSColor(hex: 0x777777)
        [thumbnailClip, icon, titleField].forEach(addSubview)
        target = self; action = #selector(openTab)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc private func openTab() { choose?(tabID) }
    func update(_ tab: BrowserTab, selected: Bool, theme: RiseTheme) {
        titleField.stringValue = tab.title
        icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = NSColor(hex: 0xD1D1D1)
        if tab.url?.host == "news.ycombinator.com", tab.favicon == nil {
            icon.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor(hex: 0xFF6600).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                ("Y" as NSString).draw(at: NSPoint(x: 4, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]); return true
            }
        }
        preview.image = tab.thumbnail; placeholder.isHidden = tab.thumbnail != nil
        let highlight = theme == .rose ? NSColor(hex: 0x783148) : theme == .dark ? NSColor(hex: 0x3D4B5B) : NSColor(hex: 0x795C54)
        layer?.backgroundColor = (selected ? highlight : .clear).cgColor
        setAccessibilityLabel(tab.title + (selected ? ", selected" : ""))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        thumbnailClip.frame = NSRect(x: 12, y: 12, width: bounds.width - 24, height: 105)
        placeholder.frame = NSRect(x: thumbnailClip.bounds.midX - 18, y: thumbnailClip.bounds.midY - 18, width: 36, height: 36)
        if let image = preview.image {
            let size = image.size
            let scale = max(thumbnailClip.bounds.width/max(1, size.width), thumbnailClip.bounds.height/max(1, size.height))
            preview.frame = NSRect(x: (thumbnailClip.bounds.width - size.width*scale)/2,
                                   y: (thumbnailClip.bounds.height - size.height*scale)/2, width: size.width*scale, height: size.height*scale)
        } else { preview.frame = thumbnailClip.bounds }
        icon.frame = NSRect(x: 14, y: 130, width: 16, height: 16)
        titleField.frame = NSRect(x: 38, y: 128, width: max(0, bounds.width - 50), height: 20)
    }
}

final class TabSwitcherView: Surface {
    let scroll = NSScrollView()
    private let cardsHost = FlippedView()
    private(set) var cards: [TabPreviewCard] = []
    private var selectedID: UUID?
    var choose: ((UUID) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(color: NSColor(hex: 0x191919), radius: 27)
        layer?.borderColor = NSColor(hex: 0x5B5B5B).cgColor; layer?.borderWidth = 1
        shadow = chromeShadow(opacity: 0.35, blur: 30, offset: -10)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.documentView = cardsHost; addSubview(scroll); isHidden = true
        setAccessibilityRole(.group); setAccessibilityLabel("Tab switcher")
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(tabs: [BrowserTab], selected: UUID?, theme: RiseTheme) {
        if cards.map(\.tabID) != tabs.map(\.id) {
            cards.forEach { $0.removeFromSuperview() }
            cards = tabs.map { tab in
                let card = TabPreviewCard(tab); card.choose = { [weak self] id in self?.choose?(id) }
                cardsHost.addSubview(card); return card
            }
        }
        selectedID = selected
        for (tab, card) in zip(tabs, cards) { card.update(tab, selected: tab.id == selected, theme: theme) }
        needsLayout = true
    }
    func place(in bounds: NSRect) {
        let width = min(CGFloat(cards.count)*182 + 28, min(1120, bounds.width - 80))
        frame = NSRect(x: bounds.midX - width/2, y: bounds.midY - 95, width: width, height: 190)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 14, dy: 16)
        let width = max(160, min(182, scroll.bounds.width))
        for (index, card) in cards.enumerated() { card.frame = NSRect(x: CGFloat(index)*width, y: 0, width: width, height: 158) }
        cardsHost.frame = NSRect(x: 0, y: 0, width: CGFloat(cards.count)*width, height: 158)
        if let card = cards.first(where: { $0.tabID == selectedID }) { card.scrollToVisible(card.bounds) }
    }
    func dismiss() {
        isHidden = true; cards.forEach { $0.removeFromSuperview() }; cards = []; selectedID = nil
    }
}
