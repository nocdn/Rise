import AppKit

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
}
enum RiseTheme: String, CaseIterable {
    case neutral, rose, dark
    var background: NSColor { NSColor(hex: self == .dark ? 0x363636 : self == .rose ? 0xF3D4D8 : 0xDFDFDF) }
    var backgroundGradient: [NSColor]? {
        self == .neutral ? [NSColor(hex: 0xDFDFDF), NSColor(hex: 0xE5E5E5)] : self == .dark ? [NSColor(hex: 0x363636), NSColor(hex: 0x2B2B2B)] : nil
    }
    var pill: NSColor { NSColor(hex: self == .dark ? 0x404040 : self == .rose ? 0xE9CACE : 0xDEDEDE) }
    var addressFill: NSColor { self == .neutral ? NSColor(hex: 0xD2D1D1) : pill }
    var text: NSColor { NSColor(hex: self == .dark ? 0xD1D1D1 : self == .rose ? 0x42121F : 0x343434) }
    var selectedText: NSColor { self == .dark ? NSColor(hex: 0xFEFEFE) : self == .neutral ? NSColor(hex: 0x111111) : text }
    var muted: NSColor { NSColor(hex: self == .dark ? 0xA0A1A0 : self == .rose ? 0x90777C : 0x888787) }
    var selectedTab: NSColor { NSColor(hex: self == .dark ? 0x1E1E1E : self == .rose ? 0xF8F6F6 : 0xF7F7F7) }
    var hoveredTab: NSColor { self == .dark ? NSColor(hex: 0x3D3D3D) : self == .rose ? text.withAlphaComponent(0.055) : NSColor(hex: 0xD7D5D4) }
    var accent: NSColor { NSColor(hex: self == .dark ? 0x8D9BAA : self == .rose ? 0xD96880 : 0xCA9D90) }
    var menuSelection: NSColor { self == .dark ? NSColor(hex: 0x515C68) : accent }
    var popup: NSColor { NSColor(hex: self == .dark ? 0x333333 : 0xF8F8F8) }
    var page: NSColor { NSColor(hex: self == .dark ? 0x1C1C1C : 0xFDFCFC) }
    // A contrasting glint is needed because the shimmer preserves glyph alpha.
    // Using selectedText made the rose theme invisible (identical text RGB).
    var linkShimmer: NSColor { NSColor(hex: self == .dark ? 0xFFFFFF : self == .rose ? 0xC6A0AB : 0xA4ACB6) }
    var status: NSColor { NSColor(hex: self == .dark ? 0x393939 : self == .rose ? 0xF8E8EB : 0xF3F3F3) }
    var developerSurface: NSColor { NSColor(hex: self == .dark ? 0x30282B : 0xFCF6F7) }
    var border: NSColor { self == .dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.16) }
    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}
class FlippedView: NSView { override var isFlipped: Bool { true } }
class Surface: FlippedView {
    private let gradient = CAGradientLayer()
    var gradientColors: [NSColor]? {
        didSet {
            guard gradientColors != oldValue else { return }
            gradient.colors = gradientColors?.map(\.cgColor)
            gradient.isHidden = gradientColors == nil
        }
    }
    init(color: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: .zero); wantsLayer = true; clipsToBounds = false
        layer?.backgroundColor = color.cgColor; layer?.cornerRadius = radius
        gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.isHidden = true; layer?.insertSublayer(gradient, at: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    var fill: NSColor { get { .clear } set { layer?.backgroundColor = newValue.cgColor } }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
}
func label(_ text: String, size: CGFloat = 14, weight: NSFont.Weight = .regular, color: NSColor = NSColor(hex: 0x343434)) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}
class ChromeButton: NSButton {
    var actionBlock: (() -> Void)?
    var baseColor = NSColor.clear
    var hover = false
    var hoverColor = NSColor.black.withAlphaComponent(0.05) {
        didSet { if hover { layer?.backgroundColor = hoverColor.cgColor } }
    }
    init(symbol: String, size: CGFloat = 16, title: String, action: @escaping () -> Void) {
        super.init(frame: .zero)
        isBordered = false; bezelStyle = .regularSquare; imagePosition = .imageOnly
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular))
        contentTintColor = NSColor(hex: 0x7D7B7B)
        toolTip = title; setAccessibilityLabel(title)
        target = self; self.action = #selector(runAction); actionBlock = action
        wantsLayer = true; layer?.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func runAction() { actionBlock?() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true; layer?.backgroundColor = hoverColor.cgColor }
    override func mouseExited(with event: NSEvent) { hover = false; layer?.backgroundColor = baseColor.cgColor }
}
final class SidebarGrip: FlippedView {
    var resize: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { resize?(event.locationInWindow.x) }
}
final class BrowserWindow: NSWindow {
    var escapeAction: (() -> Bool)?
    var tabSwitchEvent: ((NSEvent) -> Bool)?
    var pageMouseDown: ((NSEvent) -> Void)?
    var otherMouseEvent: ((NSEvent) -> Bool)?
    var historyScrollEvent: ((NSEvent) -> Bool)?
    var modifiersChanged: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if tabSwitchEvent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .flagsChanged { modifiersChanged?() }
        if tabSwitchEvent?(event) != true {
            if event.type == .scrollWheel, historyScrollEvent?(event) == true { return }
            if otherMouseEvent?(event) == true { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown { pageMouseDown?(event) }
            super.sendEvent(event)
        }
    }
    // Replay a buffered page scroll without recursively entering the swipe router.
    func deliverPageScroll(_ event: NSEvent) { super.sendEvent(event) }
    override func cancelOperation(_ sender: Any?) { if escapeAction?() != true { super.cancelOperation(sender) } }
}

final class DeveloperHeader: Surface {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor.white.withAlphaComponent(dark ? 0.055 : 0.28).setFill()
        for x in stride(from: -84.0, through: Double(bounds.width)+80, by: 44) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x+22, y: 0))
            p.line(to: NSPoint(x: x+62, y: bounds.height)); p.line(to: NSPoint(x: x+40, y: bounds.height)); p.close(); p.fill()
        }
        NSColor.black.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: bounds.height-0.5, width: bounds.width, height: 0.5).fill()
    }
}

/// A native titlebar accessory adjacent to the system window-control group.
/// Only navigation controls are custom; traffic lights stay owned by NSWindow.
final class NativeTitlebarControls: NSView {
    var buttons: [ChromeButton] = []
    override func layout() {
        super.layout()
        let centerY: CGFloat
        if let close = window?.standardWindowButton(.closeButton), close.window === window {
            centerY = close.convert(close.bounds, to: self).midY
        } else {
            centerY = bounds.midY
        }
        let visible = buttons.filter { !$0.isHidden }
        let gap = visible.count > 1 ? max(0, (bounds.width-CGFloat(visible.count)*28)/CGFloat(visible.count-1)) : 0
        for (index, button) in visible.enumerated() {
            button.frame = NSRect(x: CGFloat(index)*(28+gap), y: centerY-15, width: 28, height: 30)
        }
    }
}

final class PeekBackdrop: Surface {
    var dismiss: (() -> Void)?
    override func mouseDown(with event: NSEvent) { dismiss?() }
}

func chromeShadow(opacity: CGFloat, blur: CGFloat, offset: CGFloat, color: NSColor = .black) -> NSShadow {
    let shadow = NSShadow()
    shadow.shadowColor = color.withAlphaComponent(opacity)
    shadow.shadowBlurRadius = blur
    shadow.shadowOffset = NSSize(width: 0, height: offset)
    return shadow
}
func broomIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        let handle = NSBezierPath(); handle.lineWidth = 1.6; handle.lineCapStyle = .round
        handle.move(to: NSPoint(x: 14, y: 17)); handle.line(to: NSPoint(x: 7.5, y: 10)); handle.stroke()
        let head = NSBezierPath(); head.lineWidth = 1.3; head.lineJoinStyle = .round
        head.move(to: NSPoint(x: 6, y: 11)); head.line(to: NSPoint(x: 2, y: 4))
        head.curve(to: NSPoint(x: 8, y: 1.5), controlPoint1: NSPoint(x: 3.5, y: 2), controlPoint2: NSPoint(x: 6, y: 1.5))
        head.line(to: NSPoint(x: 12, y: 7)); head.line(to: NSPoint(x: 8.5, y: 12)); head.close(); head.stroke()
        for (a, b) in [(NSPoint(x: 7, y: 8), NSPoint(x: 4, y: 3)), (NSPoint(x: 9, y: 7), NSPoint(x: 6.5, y: 2.5))] {
            let bristle = NSBezierPath(); bristle.lineWidth = 1; bristle.move(to: a); bristle.line(to: b); bristle.stroke()
        }
        return true
    }
    image.isTemplate = true; return image
}
