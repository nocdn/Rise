import AppKit
import RiseCore

final class TabPreviewCard: NSButton {
    let tabID: UUID
    private let thumbnailClip = Surface(color: .white, radius: 8)
    private let preview = NSImageView()
    private let placeholder = NSImageView()
    private let icon = FaviconView(frame: .zero)
    private let titleField = FadingTextField(frame: .zero)
    var choose: ((UUID) -> Void)?
    init(_ tab: BrowserTab) {
        tabID = tab.id
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true
        layer?.cornerRadius = 16; layer?.cornerCurve = .continuous
        appearance = NSAppearance(named: .aqua)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = NSColor(hex: 0x494949)
        thumbnailClip.layer?.masksToBounds = true; thumbnailClip.clipsToBounds = true
        thumbnailClip.layer?.cornerCurve = .continuous
        thumbnailClip.layer?.borderWidth = 1; thumbnailClip.layer?.borderColor = NSColor(hex: 0xE3E3E3).cgColor
        preview.imageScaling = .scaleProportionallyUpOrDown
        thumbnailClip.addSubview(preview); thumbnailClip.addSubview(placeholder)
        placeholder.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        placeholder.contentTintColor = NSColor(hex: 0xB5B5B5)
        [thumbnailClip, icon, titleField].forEach(addSubview)
        target = self; action = #selector(openTab)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    @objc private func openTab() { choose?(tabID) }
    func update(_ tab: BrowserTab, selected: Bool) {
        titleField.stringValue = tab.title
        icon.image = tab.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = tab.favicon == nil ? NSColor(hex: 0xB5B5B5) : nil
        if tab.url?.host == "news.ycombinator.com", tab.favicon == nil {
            icon.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor(hex: 0xFF6600).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                ("Y" as NSString).draw(at: NSPoint(x: 4, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]); return true
            }
        }
        preview.image = tab.thumbnail; placeholder.isHidden = tab.thumbnail != nil
        titleField.textColor = NSColor(hex: selected ? 0x000000 : 0x494949)
        layer?.backgroundColor = (selected ? NSColor(hex: 0xCBCBCB) : .clear).cgColor
        setAccessibilityLabel(tab.title + (selected ? ", selected" : ""))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        thumbnailClip.frame = NSRect(x: 12, y: 12, width: bounds.width - 24, height: 106)
        placeholder.frame = NSRect(x: thumbnailClip.bounds.midX - 18, y: thumbnailClip.bounds.midY - 18, width: 36, height: 36)
        if let image = preview.image {
            let size = image.size
            let scale = max(thumbnailClip.bounds.width/max(1, size.width), thumbnailClip.bounds.height/max(1, size.height))
            preview.frame = NSRect(x: (thumbnailClip.bounds.width - size.width*scale)/2,
                                   y: (thumbnailClip.bounds.height - size.height*scale)/2, width: size.width*scale, height: size.height*scale)
        } else { preview.frame = thumbnailClip.bounds }
        icon.frame = NSRect(x: 17, y: 130, width: 16, height: 16)
        titleField.frame = NSRect(x: 38, y: 130, width: max(0, bounds.width - 62), height: 20)
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
        super.init(color: NSColor(hex: 0xF7F7F7), radius: 27)
        appearance = NSAppearance(named: .aqua); layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.black.withAlphaComponent(0.344).cgColor; layer?.borderWidth = 0.5
        // Positive Y casts the shadow below this flipped AppKit surface.
        shadow = chromeShadow(opacity: 0.25, blur: 30, offset: 4)
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
        scroll.documentView = cardsHost; addSubview(scroll); isHidden = true
        setAccessibilityRole(.group); setAccessibilityLabel("Tab switcher")
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(tabs: [BrowserTab], selected: UUID?) {
        if cards.map(\.tabID) != tabs.map(\.id) {
            cards.forEach { $0.removeFromSuperview() }
            cards = tabs.map { tab in
                let card = TabPreviewCard(tab); card.choose = { [weak self] id in self?.choose?(id) }
                cardsHost.addSubview(card); return card
            }
        }
        selectedID = selected
        for (tab, card) in zip(tabs, cards) { card.update(tab, selected: tab.id == selected) }
        needsLayout = true
    }
    func place(in bounds: NSRect) {
        let width = min(CGFloat(cards.count)*182 + 32, min(942, bounds.width - 80))
        frame = NSRect(x: bounds.midX - width/2, y: bounds.midY - 95, width: width, height: 190)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 16, dy: 16)
        let width = max(160, min(182, scroll.bounds.width))
        for (index, card) in cards.enumerated() { card.frame = NSRect(x: CGFloat(index)*width, y: 0, width: width, height: 158) }
        cardsHost.frame = NSRect(x: 0, y: 0, width: CGFloat(cards.count)*width, height: 158)
        if let card = cards.first(where: { $0.tabID == selectedID }) { card.scrollToVisible(card.bounds) }
    }
    func dismiss() {
        isHidden = true; cards.forEach { $0.removeFromSuperview() }; cards = []; selectedID = nil
    }
}
