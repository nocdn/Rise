import AppKit

final class NewTabButton: NSButton {
    private let plus = NSImageView()
    private let caption = TabTitleField(frame: .zero)
    private var hovered = false
    var theme = RiseTheme.neutral {
        didSet {
            plus.contentTintColor = theme.sidebarIcon
            caption.textColor = theme.isLight ? .black.withAlphaComponent(0.5) : theme.muted
            updateBackground()
        }
    }
    init() {
        super.init(frame: .zero)
        isBordered = false; title = ""; wantsLayer = true
        layer?.cornerRadius = TabAppearance.radius; layer?.cornerCurve = .continuous
        caption.stringValue = "New Tab"
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        plus.contentTintColor = theme.muted; caption.textColor = theme.muted
        addSubview(plus); addSubview(caption)
        setAccessibilityLabel("New Tab")
        toolTip = "New Tab (⌘T)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {}
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        plus.frame = NSRect(x: 8, y: (bounds.height - 16)/2, width: 16, height: 16)
        let height = ceil(caption.intrinsicContentSize.height)
        caption.frame = NSRect(x: 30, y: (bounds.height - height)/2, width: max(0, bounds.width - 38), height: height)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateBackground() }
    override func mouseExited(with event: NSEvent) { resetHover() }
    func resetHover() { hovered = false; updateBackground() }
    private func updateBackground() { layer?.backgroundColor = (hovered ? TabAppearance.hoverFill(theme) : .clear).cgColor }
}
