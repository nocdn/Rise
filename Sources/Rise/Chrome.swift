import AppKit

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
}
enum RiseTheme: String, CaseIterable {
    case neutral, rose, dark
    var background: NSColor { NSColor(hex: self == .dark ? 0x363636 : self == .rose ? 0xF3D4D8 : 0xE0E0E0) }
    /// Top to bottom.
    var backgroundGradient: [NSColor]? {
        self == .neutral ? [NSColor(hex: 0xE0E0E0), NSColor(hex: 0xFAFAFA)] : self == .dark ? [NSColor(hex: 0x363636), NSColor(hex: 0x2B2B2B)] : nil
    }
    var pill: NSColor { NSColor(hex: self == .dark ? 0x404040 : self == .rose ? 0xE9CACE : 0xDEDEDE) }
    var addressFill: NSColor {
        (self == .neutral ? NSColor(hex: 0xD2D1D1) : pill).blended(withFraction: self == .dark ? 0.03 : 0.15, of: .white)!
    }
    var text: NSColor { NSColor(hex: self == .dark ? 0xD1D1D1 : self == .rose ? 0x42121F : 0x343434) }
    var selectedText: NSColor { self == .dark ? NSColor(hex: 0xFEFEFE) : self == .neutral ? NSColor(hex: 0x111111) : text }
    /// Sidebar chrome icons; the dark theme keeps its lighter muted tone for contrast.
    var sidebarIcon: NSColor { self == .dark ? muted : NSColor(hex: 0x717171) }
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
    /// Rounds the gradient along with the fill.
    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set {
            guard newValue != cornerRadius else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.cornerRadius = newValue; gradient.cornerRadius = newValue
            gradient.cornerCurve = layer?.cornerCurve ?? .circular
            CATransaction.commit()
        }
    }
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
        refreshHoverState()
    }
    /// The visible part of the button. Without clipping, visibleRect alone
    /// can span its whole window, which would put every button under the pointer.
    var hoverRect: NSRect { visibleRect.intersection(bounds) }
    /// Moving or revealing a button can leave its tracking state at the previous geometry.
    func refreshHoverState() {
        if let window, window.isVisible, !isHiddenOrHasHiddenAncestor, alphaValue > 0.01 {
            hover = hoverRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else { hover = false }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = (hover ? hoverColor : baseColor).cgColor
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { refreshHoverState() }
    override func mouseExited(with event: NSEvent) { refreshHoverState() }
}
final class SidebarGrip: FlippedView {
    var resize: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { resize?(event.locationInWindow.x) }
}
final class BrowserWindow: NSWindow {
    var escapeAction: (() -> Bool)?
    /// Sees Escape before the first responder does, so an open find bar can keep it from the page.
    var escapeEvent: ((NSEvent) -> Bool)?
    var tabSwitchEvent: ((NSEvent) -> Bool)?
    var addressPaletteEvent: ((NSEvent) -> Bool)?
    var pageMouseDown: ((NSEvent) -> Void)?
    var otherMouseEvent: ((NSEvent) -> Bool)?
    var historyScrollEvent: ((NSEvent) -> Bool)?
    var modifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    var pointerMoved: ((NSEvent) -> Void)?
    /// Sees ⌘Z before the page or the Edit menu does.
    var undoEvent: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if undoEvent?(event) == true { return true }
        if addressPaletteEvent?(event) == true { return true }
        if tabSwitchEvent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        defer {
            if [.mouseMoved, .leftMouseDragged, .scrollWheel, .leftMouseDown, .rightMouseDown].contains(event.type) { pointerMoved?(event) }
        }
        if addressPaletteEvent?(event) == true { return }
        if tabSwitchEvent?(event) != true {
            if event.type == .scrollWheel, historyScrollEvent?(event) == true { return }
            if otherMouseEvent?(event) == true { return }
            // keyCode is only valid on key events (it raises on others), so the type goes first.
            if event.type == .keyDown || event.type == .keyUp, event.keyCode == 53, escapeEvent?(event) == true { return }
            if event.type == .leftMouseDown || event.type == .rightMouseDown { pageMouseDown?(event) }
            super.sendEvent(event)
        }
        if event.type == .flagsChanged { modifiersChanged?(event.modifierFlags) }
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
    /// Moves the buttons sideways with a floating sidebar, leaving their spacing alone.
    var shift: CGFloat = 0
    /// Extra width beyond the buttons' span, for them to be carried into.
    var room: CGFloat = 0
    override func layout() {
        super.layout()
        let centerY: CGFloat
        if let close = window?.standardWindowButton(.closeButton), close.window === window {
            centerY = close.convert(close.bounds, to: self).midY
        } else {
            centerY = bounds.midY
        }
        let visible = buttons.filter { !$0.isHidden }
        let span = bounds.width-room
        let gap = visible.count > 1 ? max(0, (span-CGFloat(visible.count)*28)/CGFloat(visible.count-1)) : 0
        for (index, button) in visible.enumerated() {
            button.frame = NSRect(x: shift+CGFloat(index)*(28+gap), y: centerY-15, width: 28, height: 30)
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
