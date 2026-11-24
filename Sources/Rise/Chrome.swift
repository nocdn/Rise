import AppKit

extension NSColor {
    convenience init(hex: UInt32) { self.init(srgbRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
}
enum RiseTheme: String, CaseIterable {
    /// Light and Dark, as Kero's Plain (github.com/egoist/kero, theme.go): one colour over the
    /// window's material, Kero's tabs, and a page bar over the page.
    case neutral, dark
    var isLight: Bool { self == .neutral }
    /// The window behind the page: a light grey with a trace of cool, and near-black in the dark.
    static let plainBackground = NSColor(hex: 0xF2F2F4), plainDarkBackground = NSColor(hex: 0x141418)
    var background: NSColor { self == .dark ? Self.plainDarkBackground : Self.plainBackground }
    var pill: NSColor { NSColor(hex: self == .dark ? 0x404040 : 0xDEDEDE) }
    var addressFill: NSColor { isLight ? NSColor(hex: 0xE1E1E1) : pill.blended(withFraction: 0.03, of: .white)! }
    var text: NSColor { NSColor(hex: self == .dark ? 0xD1D1D1 : 0x343434) }
    var selectedText: NSColor { NSColor(hex: self == .dark ? 0xFEFEFE : 0x111111) }
    /// Sidebar chrome icons; the dark theme keeps its lighter muted tone for contrast.
    var sidebarIcon: NSColor { self == .dark ? muted : NSColor(hex: 0x717171) }
    var newTabPlus: NSColor { NSColor(hex: self == .dark ? 0xD8D8DA : 0x303032) }
    var muted: NSColor { NSColor(hex: self == .dark ? 0xA0A1A0 : 0x888787) }
    var accent: NSColor { NSColor(hex: self == .dark ? 0x8D9BAA : 0xCA9D90) }
    var menuSelection: NSColor { self == .dark ? NSColor(hex: 0x515C68) : accent }
    var popup: NSColor { NSColor(hex: self == .dark ? 0x333333 : 0xF8F8F8) }
    var page: NSColor { NSColor(hex: self == .dark ? 0x1C1C1C : 0xFDFCFC) }
    // A contrasting glint is needed because the shimmer preserves glyph alpha.
    var linkShimmer: NSColor { NSColor(hex: self == .dark ? 0xFFFFFF : 0xA4ACB6) }
    var status: NSColor { NSColor(hex: self == .dark ? 0x393939 : 0xF3F3F3) }
    var developerSurface: NSColor { NSColor(hex: self == .dark ? 0x30282B : 0xFCF6F7) }
    var border: NSColor { self == .dark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.16) }
    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }
}
class FlippedView: NSView { override var isFlipped: Bool { true } }
extension NSView {
    /// Whether `point`, in the window, is on this view itself rather than on something in front of
    /// it, such as Peek's buttons over the page bar: tracking areas report the pointer either way.
    func isFrontmost(at point: NSPoint) -> Bool {
        guard let frame = window?.contentView?.superview, let hit = frame.hitTest(frame.convert(point, from: nil)) else { return false }
        return hit === self || hit.isDescendant(of: self)
    }
    /// Removes the tracking areas the view added for itself, leaving AppKit's own. A tooltip's
    /// area belongs to AppKit's tooltip manager: removed with the rest, the manager loses track of
    /// the view and can message it after it's freed, which crashed Rise splitting a Peek.
    func removeOwnTrackingAreas() {
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
    }
}
class Surface: FlippedView {
    init(color: NSColor = .clear, radius: CGFloat = 0) {
        super.init(frame: .zero); wantsLayer = true; clipsToBounds = false
        layer?.backgroundColor = color.cgColor; layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }
    /// Only a different color is set: each set is a change Core Animation commits and redraws.
    var fill: NSColor {
        get { .clear }
        set { let color = newValue.cgColor; if layer?.backgroundColor != color { layer?.backgroundColor = color } }
    }
    var cornerRadius: CGFloat {
        get { layer?.cornerRadius ?? 0 }
        set {
            guard newValue != cornerRadius else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.cornerRadius = newValue
            CATransaction.commit()
        }
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
    private(set) var hoverHint: ButtonHoverHint?
    var baseColor = NSColor.clear
    var hover = false
    /// Lit as if hovered, as while the popover it opened shows, without its hint.
    var holdsHover = false { didSet { if holdsHover != oldValue { refreshHoverState() } } }
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
    func setHoverHint(_ text: String, shortcut: String = "") {
        if let hoverHint { hoverHint.update(text: text, shortcut: shortcut) }
        else { hoverHint = ButtonHoverHint(button: self, text: text, shortcut: shortcut) }
        toolTip = nil; setAccessibilityLabel(text)
    }
    @objc func runAction() { hoverHint?.hide(); actionBlock?() }
    override func mouseDown(with event: NSEvent) { hoverHint?.hide(); super.mouseDown(with: event) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hoverHint?.setHovered(false) } }
    override func viewDidHide() { super.viewDidHide(); hoverHint?.setHovered(false) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        // Moves too: off something in front of it and onto it is no entry of its own.
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        refreshHoverState()
    }
    /// The visible part of the button. Without clipping, visibleRect alone
    /// can span its whole window, which would put every button under the pointer.
    var hoverRect: NSRect { visibleRect.intersection(bounds) }
    /// Moving or revealing a button can leave its tracking state at the previous geometry.
    func refreshHoverState(at point: NSPoint? = nil) {
        if let window, window.isVisible, !isHiddenOrHasHiddenAncestor, alphaValue > 0.01 {
            let point = point ?? window.mouseLocationOutsideOfEventStream
            hover = hoverRect.contains(convert(point, from: nil)) && isFrontmost(at: point)
        } else { hover = false }
        hoverHint?.setHovered(hover && !holdsHover)
        let color = (hover || holdsHover ? hoverColor : baseColor).cgColor
        guard layer?.backgroundColor != color else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.backgroundColor = color
        CATransaction.commit()
    }
    override func mouseEntered(with event: NSEvent) { refreshHoverState() }
    override func mouseExited(with event: NSEvent) { refreshHoverState() }
    override func mouseMoved(with event: NSEvent) { refreshHoverState() }
}
/// The ⋯ that opens a menu, as in the find bar's answers and the pull request card. The menu opens
/// the moment the button is pressed: let go at once and it stays open, or drag onto an item and
/// let go to pick it, as macOS's own pop-up buttons do. The icon keeps its color throughout, and
/// the pointer is a hand over it.
class MenuButton: ChromeButton {
    /// The menu to show, made fresh each time.
    var makeMenu: (() -> NSMenu?)?
    var menuWillOpen: (() -> Void)?
    var menuDidClose: (() -> Void)?
    /// The menu's right edge under the button's, so a button near the window's right edge opens
    /// it leftwards rather than out to the edge.
    var alignsMenuTrailing = false
    init(title: String = "More") {
        super.init(symbol: "ellipsis", size: 10, title: title, action: {})
        (cell as? NSButtonCell)?.highlightsBy = []
        // VoiceOver's press opens it too.
        actionBlock = { [weak self] in self?.openMenu() }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func highlight(_ flag: Bool) {}
    override func mouseDown(with event: NSEvent) { if isEnabled { openMenu() } }
    func openMenu() {
        hoverHint?.hide()
        guard let menu = makeMenu?() else { return }
        menuWillOpen?()
        // Called while the press is under way, the menu follows it to an item and picks it on release.
        let shown = menu.separatingIconSections()
        let x = alignsMenuTrailing ? bounds.maxX-shown.size.width : 0
        shown.popUp(positioning: nil, at: NSPoint(x: x, y: isFlipped ? bounds.maxY+4 : -4), in: self)
        menuDidClose?()
        refreshHoverState()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
}
final class SidebarGrip: FlippedView {
    var resize: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { resize?(event.locationInWindow.x) }
}
final class BrowserWindow: NSWindow {
    var isDraggingTab = false {
        didSet {
            guard isDraggingTab != oldValue else { return }
            if isDraggingTab { disableCursorRects(); NSCursor.arrow.set() }
            else { enableCursorRects(); resetCursorRects() }
        }
    }
    var escapeAction: (() -> Bool)?
    /// Sees Escape before the first responder does, so an open find bar can keep it from the page.
    var escapeEvent: ((NSEvent) -> Bool)?
    var tabSwitchEvent: ((NSEvent) -> Bool)?
    var tabScrollEvent: ((NSEvent) -> Bool)?
    var shortcutEvent: ((NSEvent) -> Bool)?
    var addressPaletteEvent: ((NSEvent) -> Bool)?
    var pageMouseDown: ((NSEvent) -> Void)?
    /// Sees a link click before the page does, and takes it (with the rest of the click) if it returns true.
    var linkClickEvent: ((NSEvent) -> Bool)?
    var otherMouseEvent: ((NSEvent) -> Bool)?
    var historyScrollEvent: ((NSEvent) -> Bool)?
    var modifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    var pointerMoved: ((NSEvent) -> Void)?
    /// Sees ⌘Z before the page or the Edit menu does.
    var undoEvent: ((NSEvent) -> Bool)?
    /// Sees ⌃R before the page does, for the tab under the pointer.
    var smartRenameEvent: ((NSEvent) -> Bool)?
    /// Sees key presses with ⌘, ⌃ or ⌥ before the page does, for extensions' shortcuts.
    var extensionShortcutEvent: ((NSEvent) -> Bool)?
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool { super.makeFirstResponder(pageFocusTarget(responder)) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if tabScrollEvent?(event) == true { return true }
        if shortcutEvent?(event) == true { return true }
        if undoEvent?(event) == true { return true }
        if smartRenameEvent?(event) == true { return true }
        if addressPaletteEvent?(event) == true { return true }
        if tabSwitchEvent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func sendEvent(_ event: NSEvent) {
        defer {
            if [.mouseMoved, .leftMouseDragged, .scrollWheel, .leftMouseDown, .rightMouseDown].contains(event.type) { pointerMoved?(event) }
            if isDraggingTab { NSCursor.arrow.set() }
        }
        if isDraggingTab, event.type == .cursorUpdate { return }
        if tabScrollEvent?(event) == true { return }
        if shortcutEvent?(event) == true { return }
        if addressPaletteEvent?(event) == true { return }
        if tabSwitchEvent?(event) != true {
            if event.type == .scrollWheel, historyScrollEvent?(event) == true { return }
            if otherMouseEvent?(event) == true { return }
            // keyCode is only valid on key events (it raises on others), so the type goes first.
            if event.type == .keyDown || event.type == .keyUp, event.keyCode == 53, escapeEvent?(event) == true { return }
            if event.type == .keyDown, !event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
               extensionShortcutEvent?(event) == true { return }
            if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type), linkClickEvent?(event) == true { return }
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
    /// Where nothing's to click, it moves the window, as the page bar does.
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        DeveloperStripes.draw(in: bounds, appearance: effectiveAppearance)
        NSColor.black.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: bounds.height-0.5, width: bounds.width, height: 0.5).fill()
    }
}

/// Developer mode's stripes on its colour, under Find's and a permission's panel over a developer
/// mode page, so they read as its bar does (`FindBar.stylePanel` puts one in each panel).
final class DeveloperStripes: FlippedView {
    var color = NSColor.clear { didSet { if color != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); bounds.fill()
        Self.draw(in: bounds, appearance: effectiveAppearance)
    }
    /// The bar's stripes: white bands 22 points wide every 44, each leaning a point right for every
    /// point down, so they keep the bar's angle in a panel of any height.
    static func draw(in bounds: NSRect, appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor.white.withAlphaComponent(dark ? 0.055 : 0.28).setFill()
        let lean = Double(bounds.height)
        for x in stride(from: -44-lean, through: Double(bounds.width)+44, by: 44) {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 0)); p.line(to: NSPoint(x: x+22, y: 0))
            p.line(to: NSPoint(x: x+22+lean, y: bounds.height)); p.line(to: NSPoint(x: x+lean, y: bounds.height)); p.close(); p.fill()
        }
    }
}

/// A native titlebar accessory beside the window's traffic lights, which stay NSWindow's: it holds
/// the titlebar's room over the sidebar.
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
