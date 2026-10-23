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
    /// The pointer moved over the card.
    var hover: ((UUID) -> Void)?
    init(_ tab: BrowserTab) {
        tabID = tab.id
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true
        layer?.cornerRadius = TabSwitcherView.cornerRadius - TabSwitcherView.padding; layer?.cornerCurve = .continuous
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
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover?(tabID) }
    override func mouseMoved(with event: NSEvent) { hover?(tabID) }
    func update(_ tab: BrowserTab, selected: Bool) {
        titleField.stringValue = tab.title
        if let favicon = tab.favicon { icon.image = favicon }
        else { icon.showEmptyPlaceholder(theme: .neutral) }
        icon.contentTintColor = nil
        if tab.url?.host == "news.ycombinator.com", tab.favicon == nil {
            icon.image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                NSColor(hex: 0xFF6600).setFill(); NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                ("Y" as NSString).draw(at: NSPoint(x: 4, y: 1), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]); return true
            }
        }
        preview.image = tab.thumbnail; placeholder.isHidden = tab.thumbnail != nil
        titleField.textColor = NSColor(hex: selected ? 0x000000 : 0x494949)
        layer?.backgroundColor = (selected ? NSColor(hex: 0xD3D3D3) : .clear).cgColor
        setAccessibilityLabel(tab.title + (selected ? ", selected" : ""))
        needsLayout = true
    }
    override func layout() {
        super.layout()
        // The title row keeps its size; a smaller card takes it from the picture.
        thumbnailClip.frame = NSRect(x: 12, y: 12, width: bounds.width - 24, height: max(0, bounds.height - 52))
        placeholder.frame = NSRect(x: thumbnailClip.bounds.midX - 18, y: thumbnailClip.bounds.midY - 18, width: 36, height: 36)
        if let image = preview.image {
            let size = image.size
            let scale = max(thumbnailClip.bounds.width/max(1, size.width), thumbnailClip.bounds.height/max(1, size.height))
            preview.frame = NSRect(x: (thumbnailClip.bounds.width - size.width*scale)/2,
                                   y: (thumbnailClip.bounds.height - size.height*scale)/2, width: size.width*scale, height: size.height*scale)
        } else { preview.frame = thumbnailClip.bounds }
        icon.frame = NSRect(x: 17, y: bounds.height - 28, width: 16, height: 16)
        titleField.frame = NSRect(x: 38, y: bounds.height - 28, width: max(0, bounds.width - 62), height: 20)
    }
}

/// Control-Tab's cards, five to a row, every one in sight: they shrink to fit the window rather
/// than scroll.
final class TabSwitcherView: Surface {
    static let cornerRadius: CGFloat = 27, padding: CGFloat = 12
    static let cardSize = NSSize(width: 182, height: 158), columns = 5
    private let cardsHost = FlippedView()
    private(set) var cards: [TabPreviewCard] = []
    private var selectedID: UUID?
    var choose: ((UUID) -> Void)?
    var hover: ((UUID) -> Void)?
    /// Where the pointer was as the switcher showed: cards it rests on aren't chosen until it moves.
    private var restingPointer: NSPoint?
    override var acceptsFirstResponder: Bool { true }
    init() {
        super.init(color: NSColor(hex: 0xF7F7F7), radius: Self.cornerRadius)
        appearance = NSAppearance(named: .aqua); layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.black.withAlphaComponent(0.344).cgColor; layer?.borderWidth = 0.5
        // Positive Y casts the shadow below this flipped AppKit surface.
        shadow = chromeShadow(opacity: 0.25, blur: 30, offset: 4)
        addSubview(cardsHost); isHidden = true
        setAccessibilityRole(.group); setAccessibilityLabel("Tab switcher")
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(tabs: [BrowserTab], selected: UUID?) {
        if cards.map(\.tabID) != tabs.map(\.id) {
            cards.forEach { $0.removeFromSuperview() }
            cards = tabs.map { tab in
                let card = TabPreviewCard(tab); card.choose = { [weak self] id in self?.choose?(id) }
                card.hover = { [weak self] id in self?.pointerMoved(over: id) }
                cardsHost.addSubview(card); return card
            }
        }
        selectedID = selected
        for (tab, card) in zip(tabs, cards) { card.update(tab, selected: tab.id == selected) }
        needsLayout = true
    }
    func noteShown() { restingPointer = NSEvent.mouseLocation }
    private func pointerMoved(over id: UUID) {
        if let resting = restingPointer {
            guard NSEvent.mouseLocation != resting else { return }
            restingPointer = nil
        }
        hover?(id)
    }
    private var columns: Int { max(1, min(cards.count, Self.columns)) }
    private var rows: Int { max(1, (cards.count + Self.columns - 1)/Self.columns) }
    private var cardSize = TabSwitcherView.cardSize
    func place(in bounds: NSRect) {
        // As large as the cards' own size, or smaller to keep 40 pt from the window's edges.
        let room = NSSize(width: bounds.width - 80 - 2*Self.padding, height: bounds.height - 80 - 2*Self.padding)
        cardSize = NSSize(width: min(Self.cardSize.width, max(1, room.width)/CGFloat(columns)),
                          height: min(Self.cardSize.height, max(1, room.height)/CGFloat(rows)))
        let size = NSSize(width: cardSize.width*CGFloat(columns) + 2*Self.padding, height: cardSize.height*CGFloat(rows) + 2*Self.padding)
        frame = NSRect(x: (bounds.midX - size.width/2).rounded(), y: (bounds.midY - size.height/2).rounded(), width: size.width, height: size.height)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout()
        cardsHost.frame = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        for (index, card) in cards.enumerated() {
            let row = index/Self.columns, column = index%Self.columns
            // A last row that isn't full sits in the middle.
            let inRow = min(Self.columns, cards.count - row*Self.columns)
            let inset = CGFloat(columns - inRow)*cardSize.width/2
            card.frame = NSRect(x: (inset + CGFloat(column)*cardSize.width).rounded(), y: CGFloat(row)*cardSize.height,
                                width: cardSize.width.rounded(), height: cardSize.height.rounded())
        }
    }
    func dismiss() {
        isHidden = true; cards.forEach { $0.removeFromSuperview() }; cards = []; selectedID = nil; restingPointer = nil
    }
}
