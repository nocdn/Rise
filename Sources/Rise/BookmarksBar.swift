import AppKit
import RiseCore

/// The bookmarks bar under the page's bar: each bookmark's icon and title, on the page bar's
/// colour, with a hairline under it, as the page bar has. Those that don't fit go in a menu at its
/// end. Dragged sideways, a bookmark moves along the bar, the others making room.
@MainActor final class BookmarksBar: FlippedView {
    static let height: CGFloat = 34
    static let itemHeight: CGFloat = 26, itemMaxWidth: CGFloat = 180, gap: CGFloat = 2, inset: CGFloat = 6
    /// Each bookmark's icon, a little smaller than the sidebar's, with its rounded corners, and the
    /// room either side of it and after the title.
    static let iconSize: CGFloat = 14, iconLeading: CGFloat = 7, iconGap: CGFloat = 7, trailing: CGFloat = 8
    static let font = NSFont.systemFont(ofSize: 12)
    lazy var slide = BookmarksBarSlide(view: self)
    private(set) var items: [BookmarkBarItem] = []
    private(set) var hiddenItems: [BookmarkBarItem] = []
    let overflow: ChromeButton
    let emptyLabel = NSTextField(labelWithString: "")
    private let hairline = CALayer()
    private(set) var color = NSColor.white
    private(set) var ink = PlainNavBar.Ink.on(.white)
    var onOpen: ((UUID, Bool) -> Void)?
    var onMenu: ((UUID, NSEvent, NSView) -> Void)?
    var onReorder: ((UUID, Int) -> Void)?
    var onMenuOpen: ((Bool) -> Void)?
    /// A title being typed: the bookmark and what it's called now, or nil when the typing was cancelled.
    var onEditEnd: ((UUID, String?) -> Void)?
    var editingItem: BookmarkBarItem? { items.first { $0.isEditing } }
    /// What the bar says while there's nothing in it.
    var emptyText = "" { didSet { emptyLabel.stringValue = emptyText } }
    private var dragged: (item: BookmarkBarItem, grab: CGFloat, x: CGFloat)?
    var isDragging: Bool { dragged != nil }

    init() {
        overflow = ChromeButton(symbol: "chevron.right.2", size: 11, title: "More Bookmarks", action: {})
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        overflow.actionBlock = { [weak self] in self?.showOverflow() }
        overflow.layer?.cornerRadius = 6
        emptyLabel.font = Self.font; emptyLabel.lineBreakMode = .byTruncatingTail
        addSubview(emptyLabel); addSubview(overflow)
        layer?.addSublayer(hairline)
        setAccessibilityRole(.toolbar); setAccessibilityLabel("Bookmarks")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The bookmarks shown, and where their icons come from, for a dark or a light bar.
    private var shown: [Bookmark] = []
    private var icons: ((Bookmark, Bool) -> NSImage?)?
    func update(_ bookmarks: [Bookmark], icon: @escaping (Bookmark, Bool) -> NSImage?) {
        shown = bookmarks; icons = icon
        var byID = Dictionary(uniqueKeysWithValues: items.map { ($0.bookmarkID, $0) })
        var next: [BookmarkBarItem] = []
        let dark = PlainNavBar.Ink.isDark(color)
        for bookmark in bookmarks {
            let item = byID.removeValue(forKey: bookmark.id) ?? makeItem(bookmark.id)
            item.show(bookmark, icon: icon(bookmark, dark), ink: ink, on: color)
            next.append(item)
        }
        byID.values.forEach { $0.removeFromSuperview() }
        items = next
        emptyLabel.isHidden = !items.isEmpty
        needsLayout = true
    }
    private func makeItem(_ id: UUID) -> BookmarkBarItem {
        let item = BookmarkBarItem(id: id)
        item.onOpen = { [weak self] atTop in self?.onOpen?(id, atTop) }
        item.onMenu = { [weak self, weak item] event in if let item { self?.onMenu?(id, event, item) } }
        item.onDragStart = { [weak self, weak item] event in if let item { self?.beginDrag(item, event) } }
        item.onDragMove = { [weak self] event in self?.moveDrag(event) }
        item.onDragEnd = { [weak self] in self?.endDrag() }
        item.onEditChange = { [weak self] in self?.placeItems(animated: true) }
        item.onEditEnd = { [weak self] title in self?.placeItems(animated: true); self?.onEditEnd?(id, title) }
        addSubview(item, positioned: .below, relativeTo: overflow)
        return item
    }
    /// The page bar's colour and ink, taken as the page bar takes them: at once, or with the very
    /// fade it's fading with (`PlainNavBar.onColorChange`), from the same moment, so the two bars
    /// are always one colour.
    func follow(_ bar: PlainNavBar, fade: CABasicAnimation?) {
        let color = bar.color, ink = bar.ink
        guard color != self.color || layer?.backgroundColor == nil else { return }
        let from = layer?.presentation()?.backgroundColor ?? layer?.backgroundColor
        let turnsDark = PlainNavBar.Ink.isDark(color) != PlainNavBar.Ink.isDark(self.color)
        self.color = color; self.ink = ink
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.removeAnimation(forKey: "color")
        layer?.backgroundColor = color.cgColor; hairline.backgroundColor = ink.hairline.cgColor
        CATransaction.commit()
        if let fade, let from {
            let same = CABasicAnimation(keyPath: "backgroundColor")
            same.fromValue = from; same.toValue = color.cgColor
            same.duration = fade.duration; same.timingFunction = fade.timingFunction; same.beginTime = fade.beginTime
            same.fillMode = .backwards
            layer?.add(same, forKey: "color")
        }
        // A bar turning dark or light takes the icons drawn for it.
        if turnsDark, let icons { update(shown, icon: icons) } else { items.forEach { $0.apply(ink, on: color) } }
        emptyLabel.textColor = ink.faint
        overflow.contentTintColor = ink.strong; overflow.hoverColor = ink.hover
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hairline.frame = NSRect(x: 0, y: bounds.height-1/scale, width: bounds.width, height: 1/scale)
        CATransaction.commit()
        let line = ceil(emptyLabel.intrinsicContentSize.height)
        emptyLabel.frame = NSRect(x: Self.inset+6, y: round((bounds.height-line)/2), width: max(0, bounds.width-2*Self.inset-12), height: line)
        placeItems(animated: false)
    }
    /// Starts typing a bookmark's title in its place on the bar, its title all chosen.
    func beginEditing(_ id: UUID) {
        guard let item = items.first(where: { $0.bookmarkID == id }) else { return }
        layoutSubtreeIfNeeded()
        item.beginEditing()
        placeItems(animated: false)
    }
    /// Each in its place along the bar, left to right; those past its end wait in the menu. One
    /// being named always has its place, the others before it giving theirs up if they must.
    func placeItems(animated: Bool) {
        let y = (bounds.height-Self.itemHeight)/2
        let widths = items.map(\.fittingWidth)
        let total = widths.reduce(0, +)+Self.gap*CGFloat(max(0, items.count-1))
        let room = bounds.width-2*Self.inset
        let end = total <= room ? room : room-28-Self.gap
        let editing = editingItem
        let reserved = editing.map { $0.fittingWidth+Self.gap } ?? 0
        var x = Self.inset, used: CGFloat = 0
        hiddenItems = []
        // The order shown while one's dragged: it holds the place the pointer's over.
        var order = items
        if let dragged, let from = order.firstIndex(where: { $0 === dragged.item }) {
            order.remove(at: from); order.insert(dragged.item, at: dropIndex(for: dragged.x, among: order))
        }
        for item in order {
            let width = item.fittingWidth
            let fits = item === editing || item === dragged?.item || used+width+reserved <= end+0.5
            item.isHidden = !fits
            if !fits { hiddenItems.append(item); continue }
            if item !== editing { used += width+Self.gap }
            let frame = NSRect(x: item === dragged?.item ? dragged!.x : x, y: y, width: width, height: Self.itemHeight)
            if item === dragged?.item { CATransaction.begin(); CATransaction.setDisableActions(true); item.frame = frame; CATransaction.commit() }
            else { Self.move(item, to: NSRect(x: x, y: y, width: width, height: Self.itemHeight), animated: animated) }
            x += width+Self.gap
        }
        overflow.isHidden = hiddenItems.isEmpty
        overflow.frame = NSRect(x: bounds.width-Self.inset-28, y: y, width: 28, height: Self.itemHeight)
    }
    private func dropIndex(for x: CGFloat, among others: [BookmarkBarItem]) -> Int {
        guard let dragged else { return 0 }
        let centre = x+dragged.item.fittingWidth/2
        var edge = Self.inset
        for (index, item) in others.enumerated() {
            if centre < edge+item.fittingWidth/2 { return index }
            edge += item.fittingWidth+Self.gap
        }
        return others.count
    }
    static func move(_ view: NSView, to frame: NSRect, animated: Bool) {
        guard view.frame != frame else { return }
        let old = view.layer?.presentation()?.position ?? view.layer?.position
        let sameSize = view.frame.size == frame.size
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.frame = frame
        CATransaction.commit()
        guard animated, sameSize, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = view.layer, let old else { return }
        let movement = CASpringAnimation(keyPath: "position")
        movement.mass = 1; movement.stiffness = 520; movement.damping = 2*sqrt(520)
        movement.fromValue = old; movement.toValue = layer.position; movement.duration = movement.settlingDuration
        layer.add(movement, forKey: "Rise.BookmarkMove")
    }

    // MARK: Dragging a bookmark along the bar

    private func beginDrag(_ item: BookmarkBarItem, _ event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        dragged = (item, x-item.frame.minX, item.frame.minX)
        item.layer?.zPosition = 1; item.isLifted = true
        NSCursor.closedHand.push()
    }
    private func moveDrag(_ event: NSEvent) {
        guard let current = dragged else { return }
        let x = convert(event.locationInWindow, from: nil).x-current.grab
        dragged?.x = min(max(Self.inset, x), bounds.width-Self.inset-current.item.fittingWidth)
        placeItems(animated: true)
    }
    private func endDrag() {
        guard let current = dragged else { return }
        var others = items; others.removeAll { $0 === current.item }
        let index = dropIndex(for: current.x, among: others)
        dragged = nil
        NSCursor.pop()
        current.item.layer?.zPosition = 0; current.item.isLifted = false
        if let from = items.firstIndex(where: { $0 === current.item }), from != index {
            items.remove(at: from); items.insert(current.item, at: index)
            onReorder?(current.item.bookmarkID, index)
        }
        placeItems(animated: true)
    }

    /// A shade of the bar's colour for what's lit on it: a light bar a little darker and a touch
    /// richer, so white turns a soft grey and a colour a deeper shade of itself rather than greyer,
    /// and a dark bar a little lighter and a touch softer. `by` deepens it, as for a press.
    static func shade(of color: NSColor, by amount: CGFloat = 1) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        c.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        if PlainNavBar.Ink.isDark(c) {
            return NSColor(hue: hue, saturation: saturation*(1-0.1*amount),
                           brightness: min(1, brightness+(1-brightness)*0.11*amount+0.03*amount), alpha: 1)
        }
        let richer = saturation < 0.03 ? saturation : min(1, saturation*(1+0.12*amount)+0.015*amount)
        return NSColor(hue: hue, saturation: richer, brightness: brightness*(1-0.065*amount), alpha: 1)
    }

    private func showOverflow() {
        let menu = NSMenu()
        for item in hiddenItems {
            let entry = NSMenuItem(title: item.title, action: #selector(BookmarkBarItem.openFromMenu(_:)), keyEquivalent: "")
            entry.target = item; entry.image = item.menuImage; entry.toolTip = item.toolTip
            menu.addItem(entry)
        }
        onMenuOpen?(true)
        menu.popUp(positioning: nil, at: NSPoint(x: overflow.frame.minX, y: overflow.frame.maxY+4), in: self)
        onMenuOpen?(false)
    }
}

/// One bookmark on the bar: its icon and title, lit under the pointer as the page bar's buttons are.
@MainActor final class BookmarkBarItem: NSView, NSTextFieldDelegate {
    let bookmarkID: UUID
    /// Being named, the field is at least and at most this wide, growing with what's typed.
    static let editingWidth: ClosedRange<CGFloat> = 120...240
    private let icon = FaviconView(frame: .zero), label = NSTextField(labelWithString: "")
    private(set) var title = ""
    private var ink = PlainNavBar.Ink.on(.white)
    /// The bar's colour, which the hover and the field being named are a shade of.
    private var barColor = NSColor.white
    private var hovered = false { didSet { if hovered != oldValue { style() } } }
    private var pressEvent: NSEvent?, dragging = false
    var isLifted = false { didSet { style() } }
    var onOpen: ((Bool) -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private(set) var isEditing = false
    private var originalTitle = ""
    var onEditChange: (() -> Void)?
    var onEditEnd: ((String?) -> Void)?
    override var isFlipped: Bool { true }
    init(id: UUID) {
        bookmarkID = id
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 6; layer?.cornerCurve = .continuous
        label.font = BookmarksBar.font; label.lineBreakMode = .byTruncatingTail; label.cell?.usesSingleLineMode = true
        addSubview(icon); addSubview(label)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(_ bookmark: Bookmark, icon image: NSImage?, ink: PlainNavBar.Ink, on color: NSColor) {
        // What's being typed stays as it is.
        if !isEditing { title = bookmark.shownTitle; label.stringValue = title }
        // A site's icon gets the sidebar's rounded corners; the stand-in globe keeps its own shape.
        icon.roundsImage = image != nil
        icon.image = image ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        toolTip = "\(title)\n\(AddressDisplay.text(bookmark.url.absoluteString))"
        setAccessibilityLabel(title)
        apply(ink, on: color); needsLayout = true
    }
    func apply(_ ink: PlainNavBar.Ink, on color: NSColor) {
        self.ink = ink; barColor = color
        label.textColor = ink.strong; icon.contentTintColor = ink.strong
        style()
    }
    var fittingWidth: CGFloat {
        let typed = isEditing ? label.currentEditor()?.string ?? label.stringValue : title
        let text = ceil((typed as NSString).size(withAttributes: [.font: BookmarksBar.font]).width)
        let lead = BookmarksBar.iconLeading+BookmarksBar.iconSize+BookmarksBar.iconGap
        if isEditing { return min(Self.editingWidth.upperBound, max(Self.editingWidth.lowerBound, lead+text+14)) }
        return min(BookmarksBar.itemMaxWidth, lead+text+BookmarksBar.trailing)
    }
    var menuImage: NSImage? {
        guard let image = icon.image?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 16, height: 16); return image
    }
    override func layout() {
        super.layout()
        let size = BookmarksBar.iconSize
        icon.frame = NSRect(x: BookmarksBar.iconLeading, y: (bounds.height-size)/2, width: size, height: size)
        let line = ceil(label.intrinsicContentSize.height)
        // The field's own 2 pt insets either side of the text it was measured by.
        let x = BookmarksBar.iconLeading+size+BookmarksBar.iconGap-2
        label.frame = NSRect(x: x, y: round((bounds.height-line)/2), width: max(0, bounds.width-x-4), height: line)
    }
    private func style() {
        // A shade of the bar's own colour: under the pointer and being named, and deeper pressed or dragged.
        let fill = isLifted || pressEvent != nil ? BookmarksBar.shade(of: barColor, by: 1.6)
            : isEditing || hovered ? BookmarksBar.shade(of: barColor) : .clear
        CATransaction.begin(); CATransaction.setDisableActions(!isLifted && !hovered)
        layer?.backgroundColor = fill.cgColor
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        if isEditing, label.frame.contains(convert(point, from: superview)) { return label.hitTest(convert(point, from: superview)) ?? label }
        return self
    }

    // MARK: Naming it, as a tab is renamed

    func beginEditing() {
        guard !isEditing else { return }
        isEditing = true; originalTitle = title
        label.isEditable = true; label.isSelectable = true; label.delegate = self; label.focusRingType = .none
        label.cell?.isScrollable = true; label.cell?.wraps = false; label.lineBreakMode = .byClipping
        style(); needsLayout = true; layoutSubtreeIfNeeded()
        label.selectText(nil)
    }
    /// Enter keeps what's typed, or the title it had if nothing is; Escape cancels.
    func finishEditing(save: Bool) {
        guard isEditing else { return }
        let value = (label.currentEditor()?.string ?? label.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        // Ended by a click elsewhere, focus is already on its way there; only Enter and Escape let go of it here.
        let ownsFocus = label.currentEditor() != nil && window?.firstResponder === label.currentEditor()
        isEditing = false
        if ownsFocus { window?.makeFirstResponder(nil) }
        label.isEditable = false; label.isSelectable = false
        label.cell?.isScrollable = false; label.lineBreakMode = .byTruncatingTail
        title = save && !value.isEmpty ? value : originalTitle
        label.stringValue = title
        style(); needsLayout = true
        onEditEnd?(save ? title : nil)
    }
    func controlTextDidChange(_ notification: Notification) { onEditChange?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finishEditing(save: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finishEditing(save: false); return true }
        return false
    }
    func controlTextDidEndEditing(_ notification: Notification) { finishEditing(save: true) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) {
        if isEditing { return }
        if event.modifierFlags.contains(.control) { onMenu?(event); return }
        pressEvent = event; dragging = false; style()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressEvent else { return }
        if !dragging && abs(event.locationInWindow.x-pressEvent.locationInWindow.x) >= 4 { dragging = true; onDragStart?(pressEvent) }
        if dragging { onDragMove?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard pressEvent != nil else { return }
        let wasDragging = dragging
        pressEvent = nil; dragging = false
        if wasDragging { onDragEnd?() }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?(event.modifierFlags.contains(.command)) }
        hovered = bounds.contains(convert(event.locationInWindow, from: nil)); style()
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func accessibilityPerformPress() -> Bool { onOpen?(false); return true }
    @objc func openFromMenu(_ sender: NSMenuItem) { onOpen?(NSApp.currentEvent?.modifierFlags.contains(.command) == true) }
}

/// The bar comes down from under the page bar, and goes back up under it, on the springs the page
/// bar slides on in simulated full screen.
@MainActor final class BookmarksBarSlide {
    private weak var view: NSView?
    /// Where it is while it shows.
    private(set) var frame: NSRect = .zero
    private var spring = MotionSpring(1)
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    var isShown: Bool { spring.target == 1 }
    /// How far down it is: 0 under the page bar, 1 shown.
    var progress: CGFloat { CGFloat(spring.value) }
    init(view: NSView) { self.view = view }
    func place(_ frame: NSRect) { self.frame = frame; apply() }
    func setShown(_ shown: Bool, animated: Bool) {
        let target: Double = shown ? 1 : 0
        if spring.target != target { ChromeSlideMotion.configure(&spring, showing: shown) }
        spring.target = target
        guard animated, view?.window?.isVisible == true, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            settle(); apply(); return
        }
        apply()
        guard link == nil, !spring.isResting(within: 0.001), let view else { return }
        lastTick = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        spring.step(dt)
        if spring.isResting(within: 0.001) { settle() }
        apply()
    }
    private func settle() {
        link?.invalidate(); link = nil; lastTick = nil; spring.settle()
    }
    private func apply() {
        guard let view else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        view.frame = frame.offsetBy(dx: 0, dy: -frame.height*(1-CGFloat(spring.value)))
        // Tucked away, it takes no clicks and says nothing to accessibility.
        let away = spring.target == 0 && spring.value < 0.001
        if view.isHidden != away { view.isHidden = away }
        CATransaction.commit()
    }
}

/// Watches the top of the page while the bookmarks bar hides itself: the pointer in the page
/// bar brings it down, and leaving both takes it back up. Clicks pass through.
final class BookmarksBarHover: NSView {
    var changed: ((NSPoint) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { changed?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { changed?(event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { changed?(event.locationInWindow) }
}

@MainActor extension BrowserController {
    /// The room the bookmarks bar takes above the page: none while it hides itself, or the page is
    /// in simulated full screen.
    var bookmarksBarRoom: CGFloat { showsBookmarksBar && !autoHidesBookmarksBar ? BookmarksBar.height : 0 }
    /// The bar shows once there's a bookmark in it, rather than an empty bar over every page.
    var showsBookmarksBar: Bool {
        bookmarkPlacement == .bar && !bookmarks.items.isEmpty && !pageBarTabs.contains { overlaysFullscreenNavigation(for: $0.tab) }
            && !pageBarTabs.contains { $0.tab.isInNativeFullscreen }
    }
    /// The page's bar and what's under it, down to where the page starts.
    var pageHeaderHeight: CGFloat { PlainNavBar.Metrics.height+bookmarksBarRoom }

    func installBookmarksBar() {
        bookmarksBar.onOpen = { [weak self] id, atTop in self?.openBookmark(id, atTop: atTop) }
        bookmarksBar.onMenu = { [weak self] id, event, view in self?.showBookmarkMenu(id, event: event, in: view) }
        bookmarksBar.onReorder = { [weak self] id, index in self?.bookmarks.move(id, to: index) }
        bookmarksBar.onMenuOpen = { [weak self] open in self?.bookmarksMenuOpen = open; self?.refreshBookmarksBar() }
        bookmarksBar.onEditEnd = { [weak self] id, title in self?.finishBookmarkEdit(id, title: title) }
        // Its colour is the page bar's, changing with it in the same frame and the same fade.
        for pageBar in [navBar, splitBar] {
            pageBar.onColorChange = { [weak self, weak pageBar] fade in
                guard let self, let pageBar, pageBar === self.tabBar else { return }
                self.bookmarksBar.follow(pageBar, fade: fade)
            }
        }
        bookmarksBarHover.changed = { [weak self] point in self?.refreshBookmarksBar(pointer: point) }
        bookmarks.onChange = { [weak self] in self?.bookmarksChanged() }
        bookmarksBar.slide.setShown(!autoHidesBookmarksBar, animated: false)
        // Building the window: it's laid out once it's all there.
        bookmarksChanged(layout: false)
    }
    /// Under the page's bar, across the page: in its place while it stays, or coming and going
    /// from under the page bar while it hides itself, over the page so the page doesn't move.
    func layoutBookmarksBar(width: CGFloat) {
        let bar = bookmarksBar
        if bar.superview !== pageClip { pageClip.addSubview(bar, positioned: .below, relativeTo: navBar) }
        let shows = showsBookmarksBar
        // Taken from the page bar as it changes (below); this catches a different bar becoming the one in front.
        bar.follow(tabBar, fade: nil)
        bar.emptyText = "Press \(keyboardShortcuts.bindings("bookmarkCurrentPage").first?.display ?? "⌘D") to bookmark the page you're on"
        if !shows {
            bar.slide.setShown(false, animated: false); bar.isHidden = true
        } else if !autoHidesBookmarksBar, !bar.slide.isShown || bar.isHidden {
            bar.slide.setShown(true, animated: false)
        }
        bar.slide.place(NSRect(x: 0, y: PlainNavBar.Metrics.height, width: width, height: BookmarksBar.height))
        let hover = bookmarksBarHover
        let watches = shows && autoHidesBookmarksBar
        hover.isHidden = !watches
        if watches {
            if hover.superview !== root { root.addSubview(hover, positioned: .above, relativeTo: nil) }
            let header = root.convert(NSRect(x: 0, y: 0, width: pageClip.bounds.width, height: PlainNavBar.Metrics.height+BookmarksBar.height), from: pageClip)
            // From the window's top edge down to the bar's bottom, in the root's flipped terms.
            hover.frame = NSRect(x: header.minX, y: 0, width: header.width, height: header.maxY)
        }
        refreshBookmarksBar()
    }
    /// While it hides itself: down while the pointer's in the page bar, or in it once it's down,
    /// or a menu from it is open; up otherwise.
    func refreshBookmarksBar(pointer: NSPoint? = nil) {
        guard showsBookmarksBar, autoHidesBookmarksBar, let window else { return }
        let point = pageClip.convert(pointer ?? window.mouseLocationOutsideOfEventStream, from: nil)
        let top = pageClip.convert(.zero, from: root).y
        // From the window's top edge, so reaching it reveals the bar too.
        let pageBar = NSRect(x: 0, y: min(0, top), width: pageClip.bounds.width, height: PlainNavBar.Metrics.height-min(0, top))
        let shownBar = bookmarksBar.slide.frame
        let inside = pageBar.contains(point) || bookmarksBar.slide.isShown && shownBar.contains(point)
        let held = bookmarksMenuOpen || bookmarksBar.isDragging || bookmarkEdit != nil
            || (bookmarksBarRevealUntil.map { $0 > Date() } ?? false)
        bookmarksBar.slide.setShown(inside || held, animated: true)
    }
    /// Brings the bar down for a moment, as when a page is bookmarked while it hides itself.
    func revealBookmarksBar(for seconds: TimeInterval) {
        bookmarksBarRevealUntil = Date().addingTimeInterval(seconds)
        refreshBookmarksBar()
        DispatchQueue.main.asyncAfter(deadline: .now()+seconds+0.02) { [weak self] in
            guard let self, let until = self.bookmarksBarRevealUntil, until <= Date() else { return }
            self.bookmarksBarRevealUntil = nil; self.refreshBookmarksBar()
        }
    }
}
