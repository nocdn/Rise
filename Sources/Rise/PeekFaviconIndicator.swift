import AppKit

/// The open Peek's favicon, inset inside a quiet square. A 24-point face has radius 8,
/// inset 4 and favicon radius 4: inner radius = outer radius - inset.
final class PeekFaviconIndicator: NSView {
    let favicon = FaviconView(frame: .zero)
    static let side: CGFloat = 24
    static let inset: CGFloat = 4
    static let radius: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = Self.radius; layer?.cornerCurve = .continuous
        addSubview(favicon)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(image: NSImage?, theme: RiseTheme) {
        layer?.backgroundColor = (theme == .dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.07)).cgColor
        if let image { favicon.image = image } else { favicon.showEmptyPlaceholder(theme: theme) }
    }
    override func layout() { super.layout(); favicon.frame = bounds.insetBy(dx: Self.inset, dy: Self.inset) }
    // The row remains the click target; the usual close button still closes the tab.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
