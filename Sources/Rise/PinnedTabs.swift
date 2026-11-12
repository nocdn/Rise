import AppKit

/// Pinned tabs sit between the address and New Tab as tiles: up to three to a row and six in
/// all, a row of fewer sharing its width between them.
enum PinnedLayout {
    static let maximum = 6, perRow = 3
    static let tileHeight: CGFloat = 48, gap: CGFloat = 6, radius: CGFloat = 12, border: CGFloat = 1.5
    /// Without a Calendar countdown to fit under an icon, tiles are a little shorter, growing
    /// upward to `tileHeight` as one appears.
    static let compactHeight: CGFloat = 44
    /// How quickly the tiles grow and shrink: fast, without a bounce.
    static let heightResponse = 0.2
    /// A countdown comes in from smaller, clear and a little high, and springs down into place.
    static let countdownScale: CGFloat = 0.6, countdownRise: CGFloat = -6, countdownResponse = 0.32, countdownBounce = 0.28
    /// It starts once the tile has grown a little, so it has room.
    static let countdownDelay = 0.06
    /// Going, it goes back the way it came; the tile shrinks once it's mostly gone.
    static let countdownOutDuration = 0.2, countdownOutLead = 0.12
    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    /// Each tile's wash of its favicon's colour (a grey without one), at rest, under the pointer
    /// and chosen; Dark needs twice as much to show.
    static func tint(_ accent: NSColor?, theme: RiseTheme, selected: Bool, hovered: Bool) -> NSColor {
        let dark = theme == .dark
        let amount: CGFloat = selected ? 0.14 : hovered ? 0.1 : 0.06
        guard let accent else { return (dark ? NSColor.white : .black).withAlphaComponent(amount*(dark ? 0.6 : 0.5)) }
        return accent.withAlphaComponent(amount*(dark ? 1.7 : 1))
    }
    /// The grid sits a little further in from the sidebar's sides than the tab rows.
    static let sideInset: CGFloat = 10
    /// A tile's edge in its favicon's colour: faint at rest, full chosen (a grey without one).
    static func edge(_ accent: NSColor?, theme: RiseTheme) -> NSColor {
        guard let accent else { return (theme == .dark ? NSColor.white : .black).withAlphaComponent(theme == .dark ? 0.08 : 0.06) }
        return accent.withAlphaComponent(theme == .dark ? 0.22 : 0.15)
    }
    static let restingBorder: CGFloat = 1
    /// `fill` laid flat on the sidebar's colour, so a tile in a drag hides the tiles it crosses, as
    /// a dragged row does (`TabAppearance.dragFill`).
    static func solid(_ fill: NSColor, on theme: RiseTheme) -> NSColor {
        guard fill.alphaComponent < 1 else { return fill }
        return theme.background.blended(withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1))?.withAlphaComponent(1) ?? theme.background
    }
    /// Below the address, a little closer than New Tab sits without tiles.
    static let top: CGFloat = 95
    /// Below the last row, before New Tab.
    static let bottom: CGFloat = 8

    /// The tiles' frames for `count` of them, in a grid `width` wide from the origin.
    static func frames(count: Int, width: CGFloat, tileHeight: CGFloat = tileHeight) -> [NSRect] {
        (0..<max(0, count)).map { index in
            let row = index/perRow, inRow = min(perRow, count-row*perRow), column = index%perRow
            let tileWidth = (width-CGFloat(inRow-1)*gap)/CGFloat(inRow)
            return NSRect(x: (CGFloat(column)*(tileWidth+gap)).rounded(), y: CGFloat(row)*(tileHeight+gap),
                          width: tileWidth.rounded(), height: tileHeight)
        }
    }
    /// The grid's room in the sidebar, nothing without tiles.
    static func height(count: Int, tileHeight: CGFloat = tileHeight) -> CGFloat {
        guard count > 0 else { return 0 }
        let rows = CGFloat((count+perRow-1)/perRow)
        return rows*tileHeight+(rows-1)*gap+bottom
    }
    /// The slot nearest `point` among `count` tiles: the one it's over, or the closest edge.
    static func slot(nearest point: NSPoint, count: Int, width: CGFloat, tileHeight: CGFloat = tileHeight) -> Int {
        let frames = frames(count: count, width: width, tileHeight: tileHeight)
        func distance(_ frame: NSRect) -> CGFloat {
            hypot(max(frame.minX-point.x, 0, point.x-frame.maxX), max(frame.minY-point.y, 0, point.y-frame.maxY))
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) } ?? 0
    }
}

/// A pinned tab: its favicon in the middle, and below it a Calendar tab's countdown. The
/// selected one takes a border in its favicon's colour. Dragged down to the list, it takes a
/// row's shape again, with its title.
@MainActor final class PinnedTabTile: NSView {
    let tabID: UUID
    let icon = FaviconView(frame: .zero)
    let badge = TabBadge()
    let title = NSTextField(labelWithString: "")
    private(set) var badgeText: String?
    var onSelect: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onPress: (() -> Void)?
    var onDragStart: ((NSEvent) -> Void)?
    var onDragMove: ((NSEvent) -> Void)?
    var onDragEnd: (() -> Void)?
    private(set) var selected = false
    private var theme = RiseTheme.neutral, accent: NSColor?
    private var hovered = false, pressEvent: NSEvent?, dragging = false
    var scrollFocus: Bool? {
        didSet {
            guard scrollFocus != oldValue else { return }
            if scrollFocus != nil { setHovered(false) }
            style()
        }
    }
    /// From picking up until it has sprung back into place, when it may cross other tiles.
    private var lifted = false
    /// While dragged out of the grid: a row's shape, favicon and title. It changes shape on
    /// the same spring as its frame.
    var rowStyle = false {
        didSet {
            guard rowStyle != oldValue else { return }
            if canAnimate { prepareMotion(); rowness.target = rowStyle ? 1 : 0; startMotion() }
            else { rowness = MotionSpring(rowStyle ? 1 : 0); style(); needsLayout = true }
        }
    }
    // MARK: Motion
    private var x = MotionSpring(), y = MotionSpring(), width = MotionSpring(), height = MotionSpring()
    private var rowness = MotionSpring()
    /// While held, where the tile's corner goes for a size, so it stays under the pointer as it changes shape.
    private var origin: ((NSSize) -> NSPoint)?
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    /// Called once the tile comes to rest.
    var onRest: (() -> Void)?
    /// Called at every step of its motion, for what follows it, such as a drag's shadow.
    var onStep: (() -> Void)?
    /// The background of the row it settles into, which its own fades to as it lands.
    private var restingFill: NSColor?, settleStart: CFTimeInterval = 0
    private var settled: CGFloat {
        guard restingFill != nil, canAnimate else { return 1 }
        return CGFloat(min(1, max(0, (CACurrentMediaTime()-settleStart)/PinnedLayout.settleDuration)))
    }
    func settle(into fill: NSColor) {
        restingFill = fill; settleStart = CACurrentMediaTime()
        if canAnimate { prepareMotion(); startMotion() } else { style() }
    }
    /// How far it has changed from a tile into a row.
    var shape: CGFloat { CGFloat(min(1, max(0, rowness.value))) }
    var cornerRadius: CGFloat { PinnedLayout.radius+(TabAppearance.radius-PinnedLayout.radius)*shape }
    var isMoving: Bool { link != nil }
    private var canAnimate: Bool { window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Springs to `frame`, keeping any speed it has. A tile in hand bounces a little; ones
    /// making room for it don't.
    func move(to frame: NSRect, animated: Bool = true, bouncy: Bool = true, completion: (() -> Void)? = nil) {
        onRest = completion
        guard animated, canAnimate, self.frame.width > 0 else {
            stopMotion(); origin = nil; setFrame(frame); rowness = MotionSpring(rowness.target); land(); style(); needsLayout = true
            completion.map { done in onRest = nil; done() }
            return
        }
        // Held until now, its place came from the pointer; it starts from there, at rest.
        if origin != nil { x = spring(self.frame.minX); y = spring(self.frame.minY); origin = nil }
        prepareMotion(bouncy: bouncy)
        x.target = frame.minX; y.target = frame.minY; width.target = frame.width; height.target = frame.height
        startMotion()
    }
    /// Springs to `size` with its corner at `origin`'s, for the pointer it's held by.
    func follow(size: NSSize, bouncy: Bool = true, origin: @escaping (NSSize) -> NSPoint) {
        self.origin = origin
        guard canAnimate else { stopMotion(); setFrame(NSRect(origin: origin(size), size: size)); return }
        if link == nil, frame.size == size, rowness.isResting(within: 0.001) { setFrame(NSRect(origin: origin(size), size: size)); return }
        prepareMotion(bouncy: bouncy)
        width.target = size.width; height.target = size.height
        startMotion()
    }
    /// At rest, every spring starts from where the tile is now, so none starts from nothing.
    private func prepareMotion(bouncy: Bool? = nil) {
        if let bouncy { self.bouncy = bouncy }
        if link == nil {
            x = spring(frame.minX); y = spring(frame.minY); width = spring(frame.width); height = spring(frame.height)
            var shape = spring(rowness.value); shape.target = rowness.target; rowness = shape
        }
        for keyPath in [\PinnedTabTile.x, \.y, \.width, \.height, \.rowness] {
            self[keyPath: keyPath].configure(response: PinnedLayout.response, bounce: self.bouncy ? PinnedLayout.bounce : 0)
        }
    }
    private var bouncy = true
    private func spring(_ value: CGFloat) -> MotionSpring { MotionSpring(value) }
    private func startMotion() {
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    /// Ends its motion where it was headed, as if it had got there.
    func finishMotion() {
        guard link != nil else { return }
        stopMotion()
        let size = NSSize(width: width.target, height: height.target)
        setFrame(NSRect(origin: origin?(size) ?? NSPoint(x: x.target, y: y.target), size: size))
        rowness = MotionSpring(rowness.target); land(); style(); needsLayout = true
        let done = onRest; onRest = nil; done?()
    }
    private func land() { if !dragging, lifted { lifted = false; style() } }
    private func stopMotion() { link?.invalidate(); link = nil; lastTick = nil }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        x.step(dt); y.step(dt); width.step(dt); height.step(dt); rowness.step(dt)
        let springs = origin == nil ? [x, y, width, height] : [width, height]
        let resting = springs.allSatisfy { $0.isResting(within: 0.05) } && rowness.isResting(within: 0.002) && settled >= 1
        if resting {
            x.value = x.target; y.value = y.target; width.value = width.target; height.value = height.target; rowness.value = rowness.target
        }
        let size = NSSize(width: max(0, width.value), height: max(0, height.value))
        setFrame(NSRect(origin: origin?(size) ?? NSPoint(x: x.value, y: y.value), size: size))
        style(); needsLayout = true; layoutSubtreeIfNeeded()
        if resting { stopMotion(); land(); let done = onRest; onRest = nil; done?() }
    }
    private func setFrame(_ frame: NSRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        self.frame = frame
        CATransaction.commit()
        onStep?()
    }
    /// A display link stops when its view moves, as a tile does into a drag and back, so one
    /// still moving takes a new link wherever it goes.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard link != nil else { return }
        stopMotion()
        if window != nil { startMotion() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard link != nil else { return }
        stopMotion()
        if window != nil { startMotion() }
    }
    var isDragging: Bool { dragging }
    var isHovered: Bool { hovered }
    /// A stand-in on its way to a slot lets clicks through to what's there.
    var takesClicks = true
    override func hitTest(_ point: NSPoint) -> NSView? { takesClicks ? super.hitTest(point) : nil }
    override var isFlipped: Bool { true }
    init(tabID: UUID) {
        self.tabID = tabID
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerCurve = .continuous
        title.font = .systemFont(ofSize: 13); title.lineBreakMode = .byTruncatingTail; title.alphaValue = 0
        badge.isHidden = true
        [icon, badge, title].forEach(addSubview)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }
    func update(tab: BrowserTab, selected: Bool, theme: RiseTheme) {
        self.selected = selected; self.theme = theme
        let image = tab.favicon(for: theme)
        if let image { if icon.image !== image { icon.image = image; accent = FaviconColor.dominant(image) } }
        else { icon.showEmptyPlaceholder(theme: theme); accent = nil }
        title.stringValue = tab.title; title.textColor = TabAppearance.text(theme, selected: selected)
        badge.apply(theme, selected: selected)
        setAccessibilityLabel(tab.title + (badgeText.map { ", \($0)" } ?? "") + (selected ? ", selected" : ""))
        style()
    }
    func setBadge(_ text: String?) {
        guard text != badgeText else { return }
        let arriving = badgeText == nil, going = text == nil
        badgeText = text
        if let text {
            badge.text = text
            if arriving { leavingBadge = false; animateBadgeIn() }
        } else if canAnimate, !badge.isHidden {
            leavingBadge = true; animateBadgeOut()
        } else {
            badge.isHidden = true
        }
        needsLayout = true
        (superview as? PinnedTabsView)?.updateTileHeight(after: going && leavingBadge ? PinnedLayout.countdownOutLead : 0)
    }
    private var leavingBadge = false
    /// How much room the tiles have grown for a countdown, from none to all of it.
    private var countdownRoom: CGFloat { (superview as? PinnedTabsView)?.countdownRoom ?? (badgeText == nil ? 0 : 1) }
    /// Smaller and a little high, about its centre, as a view's layer turns about its corner.
    private var badgeAway: CATransform3D {
        let size = badge.fittingSize, scale = PinnedLayout.countdownScale
        var t = CATransform3DMakeTranslation(size.width/2, size.height/2+PinnedLayout.countdownRise, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -size.width/2, -size.height/2, 0)
    }
    private static let badgeKeys = ["Rise.CountdownIn", "Rise.CountdownFade", "Rise.CountdownOut", "Rise.CountdownFadeOut"]
    private func animateBadgeIn() {
        guard canAnimate, let layer = badge.layer else { return }
        Self.badgeKeys.forEach { layer.removeAnimation(forKey: $0) }
        let start = CACurrentMediaTime()+PinnedLayout.countdownDelay
        let move = CASpringAnimation(perceptualDuration: PinnedLayout.countdownResponse, bounce: PinnedLayout.countdownBounce)
        move.keyPath = "transform"
        move.fromValue = badgeAway; move.toValue = CATransform3DIdentity
        move.duration = move.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = PinnedLayout.countdownResponse*0.7
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        for animation in [move, fade] as [CAAnimation] {
            animation.beginTime = start; animation.fillMode = .backwards; animation.preferredFrameRateRange = PinnedLayout.frameRate
        }
        layer.add(move, forKey: "Rise.CountdownIn"); layer.add(fade, forKey: "Rise.CountdownFade")
    }
    /// From wherever it is, even still coming in, back to smaller, clear and a little high.
    private func animateBadgeOut() {
        guard let layer = badge.layer else { return }
        let shown = layer.presentation()
        let transform = shown?.transform ?? CATransform3DIdentity, opacity = shown?.opacity ?? 1
        Self.badgeKeys.forEach { layer.removeAnimation(forKey: $0) }
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = transform; move.toValue = badgeAway
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity; fade.toValue = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.leavingBadge else { return }
            self.leavingBadge = false; self.badge.isHidden = true
            Self.badgeKeys.forEach { layer.removeAnimation(forKey: $0) }
            self.needsLayout = true
        }
        for animation in [move, fade] {
            animation.duration = PinnedLayout.countdownOutDuration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.6)
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            animation.preferredFrameRateRange = PinnedLayout.frameRate
        }
        layer.add(move, forKey: "Rise.CountdownOut"); layer.add(fade, forKey: "Rise.CountdownFadeOut")
        CATransaction.commit()
    }
    /// The favicon's colour, a little lighter, or a grey for a favicon without one.
    var borderColor: NSColor {
        guard let accent else { return NSColor(white: theme == .dark ? 0.5 : 0.72, alpha: 1) }
        return theme == .dark ? accent : accent.blended(withFraction: 0.35, of: .white) ?? accent
    }
    private func style() {
        let r = shape
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = cornerRadius
        let held = TabAppearance.dragFill(theme, sidebarFraction: 0.3)
        // Settling into a row, the held row's fill gives way to that row's own.
        let row = restingFill.map { held.blended(withFraction: settled, of: $0) ?? $0 } ?? held
        // A breath of the favicon's colour, more under the pointer and more again chosen.
        let shown = PinnedLayout.tint(accent, theme: theme, selected: selected, hovered: (scrollFocus ?? hovered) && !dragging)
        let fill = lifted || !takesClicks ? PinnedLayout.solid(shown, on: theme) : shown
        layer?.backgroundColor = (fill.blended(withFraction: r, of: row) ?? fill).cgColor
        // Chosen, a border in the favicon's colour; at rest, a faint one in it.
        layer?.borderWidth = (selected ? PinnedLayout.border : PinnedLayout.restingBorder)*(1-r)
        layer?.borderColor = (selected ? borderColor : PinnedLayout.edge(accent, theme: theme)).cgColor
        // The countdown's pill in the tile's own colour, as deep as a chosen tile's wash.
        badge.setFill(PinnedLayout.tint(accent, theme: theme, selected: true, hovered: false))
        CATransaction.commit()
    }
    /// Everything inside follows the tile's frame each step, from the centre of a tile to a
    /// row's leading edge as it changes shape.
    override func layout() {
        super.layout()
        let r = shape
        let side: CGFloat = 16, badgeSize = badge.fittingSize, room = countdownRoom
        let showsBadge = (badgeText != nil || leavingBadge) && r < 1
        badge.isHidden = !showsBadge
        // The countdown leaves room above and below it, as the tile grows for it; a row's height has none.
        let stack = side+(showsBadge ? (3+badgeSize.height)*(1-r)*room : 0)
        let tile = NSPoint(x: (bounds.width-side)/2, y: (bounds.height-stack)/2)
        let row = NSPoint(x: 8, y: (bounds.height-side)/2)
        let iconFrame = NSRect(x: (tile.x+(row.x-tile.x)*r).rounded(), y: (tile.y+(row.y-tile.y)*r).rounded(), width: side, height: side)
        icon.layer?.removeAnimation(forKey: TabListMotion.movementKey)
        icon.frame = iconFrame
        if showsBadge {
            // A tile keeps its bottom as it grows, and so does the countdown, so it only moves
            // as it comes in. As a row, it follows the icon.
            let full = side+3+badgeSize.height
            let settledY = bounds.height-(PinnedLayout.tileHeight-full)/2-badgeSize.height
            let y = settledY+(iconFrame.maxY+3-settledY)*r
            badge.frame = NSRect(x: ((bounds.width-badgeSize.width)/2).rounded(), y: y.rounded(), width: badgeSize.width, height: badgeSize.height)
            badge.alphaValue = 1-r
        }
        title.frame = NSRect(x: 30, y: ((bounds.height-17)/2).rounded(), width: max(0, bounds.width-38), height: 17)
        title.alphaValue = r
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    func refreshHover() {
        guard let window, !isHiddenOrHasHiddenAncestor else { setHovered(false); return }
        setHovered(visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }
    private func setHovered(_ value: Bool) {
        let value = scrollFocus == nil && value
        guard hovered != value else { return }
        hovered = value; style(); onHover?(value)
    }
    override func mouseEntered(with event: NSEvent) { if pressEvent == nil { setHovered(true) } }
    override func mouseExited(with event: NSEvent) { if pressEvent == nil { setHovered(false) } else { onHover?(false) } }
    /// Like a row, a tile answers the click that brings its window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with event: NSEvent) { onPress?(); onMenu?(event) }
    override func mouseDown(with event: NSEvent) { pressEvent = event; dragging = false; onPress?() }
    override func mouseDragged(with event: NSEvent) {
        guard let pressEvent else { return }
        if !dragging, hypot(event.locationInWindow.x-pressEvent.locationInWindow.x, event.locationInWindow.y-pressEvent.locationInWindow.y) >= 3 {
            dragging = true; lifted = true; style(); onDragStart?(pressEvent)
        }
        if dragging { onDragMove?(event) }
    }
    override func mouseUp(with event: NSEvent) {
        guard pressEvent != nil else { return }
        let wasDragging = dragging
        pressEvent = nil; dragging = false
        if wasDragging { onDragEnd?(); if !isMoving { land() } }
        else if bounds.contains(convert(event.locationInWindow, from: nil)) { onSelect?() }
        style(); refreshHover()
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}

/// The grid of tiles. A tab dragged up from the list opens a slot for itself, which the
/// tiles move apart to make.
@MainActor final class PinnedTabsView: FlippedView {
    private(set) var tiles: [UUID: PinnedTabTile] = [:]
    private(set) var order: [UUID] = []
    /// A slot held open for a tab coming up from the list.
    private(set) var opening: Int?
    /// A tile held out of the grid, whose slot the others close over.
    var held: UUID?
    var count: Int { order.filter { $0 != held }.count+(opening == nil ? 0 : 1) }
    func set(order: [UUID], make: (UUID) -> PinnedTabTile, closed: (UUID) -> Bool = { _ in false }) {
        // A tile being dragged belongs to the drag until it lands.
        for id in tiles.keys where !order.contains(id) {
            guard let tile = tiles.removeValue(forKey: id), tile.superview === self else { continue }
            if closed(id) { leave(tile) } else { tile.removeFromSuperview() }
        }
        for id in order where tiles[id] == nil { let tile = make(id); tiles[id] = tile; addSubview(tile) }
        self.order = order
        updateTileHeight()
    }
    func setOpening(_ slot: Int?) { opening = slot }
    /// A closed tab's tile shrinks into its middle as it fades, where it was, under the tiles
    /// springing into its place, and takes no clicks or hover meanwhile.
    private func leave(_ tile: PinnedTabTile) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { tile.removeFromSuperview(); return }
        tile.finishMotion(); tile.takesClicks = false; tile.onHover = nil; tile.onRest = nil
        guard let layer = tile.layer else { tile.removeFromSuperview(); return }
        let middle = CGPoint(x: tile.bounds.midX, y: tile.bounds.midY), scale = PinnedLayout.closeScale
        let shrunk = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(middle.x, middle.y, 0), scale, scale, 1), -middle.x, -middle.y, 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        addSubview(tile, positioned: .below, relativeTo: nil)
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        let shrink = CABasicAnimation(keyPath: "transform"); shrink.fromValue = CATransform3DIdentity; shrink.toValue = shrunk
        let group = CAAnimationGroup(); group.animations = [fade, shrink]
        group.duration = PinnedLayout.closeDuration; group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.fillMode = .forwards; group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { tile.removeFromSuperview() } }
        layer.add(group, forKey: PinnedLayout.closeKey)
        CATransaction.commit()
    }
    // MARK: Height
    private var height = MotionSpring(PinnedLayout.compactHeight)
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    /// The tiles' height now, between compact and tall.
    var tileHeight: CGFloat { height.value }
    var countdownRoom: CGFloat {
        min(1, max(0, (height.value-PinnedLayout.compactHeight)/(PinnedLayout.tileHeight-PinnedLayout.compactHeight)))
    }
    private var delayed: (target: CGFloat, task: Task<Void, Never>)?
    /// Tall while any tile shows a countdown. The grid keeps its bottom, so the tiles grow upward,
    /// starting `after` a moment when they're to wait for a countdown to go.
    func updateTileHeight(after delay: TimeInterval = 0) {
        let target = tiles.values.contains { $0.badgeText != nil } ? PinnedLayout.tileHeight : PinnedLayout.compactHeight
        if let delayed {
            if delayed.target == target { return }
            delayed.task.cancel(); self.delayed = nil
        }
        guard target != height.target else { return }
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            height = MotionSpring(target); followHeight(); return
        }
        if delay > 0 {
            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.delayed = nil; self.updateTileHeight()
            }
            delayed = (target, task); return
        }
        if link == nil { var spring = MotionSpring(height.value); spring.configure(response: PinnedLayout.heightResponse, bounce: 0); height = spring }
        height.target = target
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = PinnedLayout.frameRate
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        height.step(dt)
        if height.isResting(within: 0.02) { height.settle(); link.invalidate(); self.link = nil; lastTick = nil }
        followHeight()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, link != nil { link?.invalidate(); link = nil; height.settle(); followHeight() }
    }
    /// The grid's top and its tiles follow the height, keeping its bottom where it is.
    private func followHeight() {
        let room = max(0, PinnedLayout.height(count: count, tileHeight: tileHeight)-PinnedLayout.bottom)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = NSRect(x: frame.minX, y: frame.maxY-room, width: frame.width, height: room)
        CATransaction.commit()
        layoutTiles(animated: false)
    }
    func move(_ id: UUID, to index: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        order.remove(at: from); order.insert(id, at: min(index, order.count))
    }
    /// The frames tiles take, with the slot held open and without the held tile.
    func slotFrames(width: CGFloat) -> [NSRect] {
        PinnedLayout.frames(count: count, width: width-2*PinnedLayout.sideInset, tileHeight: tileHeight).map { $0.offsetBy(dx: PinnedLayout.sideInset, dy: 0) }
    }
    func layoutTiles(animated: Bool) {
        let frames = slotFrames(width: bounds.width)
        var slot = 0
        for id in order where id != held {
            if slot == opening { slot += 1 }
            guard let tile = tiles[id], slot < frames.count else { continue }
            if tile.superview === self, tile.frame != frames[slot] || tile.isMoving {
                tile.move(to: frames[slot], animated: animated || tile.isMoving, bouncy: false, completion: tile.onRest)
            }
            slot += 1
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit.map { view in tiles.values.first { view.isDescendant(of: $0) } ?? view }
    }
}

extension PinnedLayout {
    static let slideKey = "Rise.PinnedSlide"
    /// Slides `view` from `offset` above or below where it now is, as rows do.
    @MainActor static func slideVertically(_ view: NSView, from offset: CGFloat) {
        guard let layer = view.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let shown = layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = offset+shown; slide.toValue = 0; slide.duration = TabListMotion.duration
        slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        layer.add(slide, forKey: slideKey)
    }
    /// Tiles change shape and place on a spring a little slower than the list's slide, with a
    /// slight bounce.
    static let response = 0.28, bounce = 0.3
    /// A landing row's held fill fades out over about as long as it takes to land.
    static let settleDuration = 0.24
    /// A closed tab's tile shrinks to this as it fades, gone before the tiles closing over it land.
    static let closeScale: CGFloat = 0.7, closeDuration = 0.2
    static let closeKey = "Rise.PinnedClose"
}

/// A pinned tile held by the pointer, over the grid or down in the list.
@MainActor final class PinnedDrag {
    let id: UUID
    let tile: PinnedTabTile
    let overlay: TabDragOverlay
    /// Where the pointer holds the tile, as fractions of its size.
    let grab: NSPoint
    /// Its place among the list's rows, once it leaves the grid.
    var listIndex: Int?
    init(id: UUID, tile: PinnedTabTile, overlay: TabDragOverlay, grab: NSPoint) {
        self.id = id; self.tile = tile; self.overlay = overlay; self.grab = grab
    }
}

@MainActor extension SidebarView {
    /// What a tab's hover card and menu point at: its tile or its row.
    func anchor(for id: UUID) -> NSView? {
        if let tile = pinnedView.tiles[id], tile.superview === pinnedView { return tile }
        guard let row = rows[id], row.superview != nil else { return nil }
        return row
    }
    func isRenaming(_ id: UUID) -> Bool { rows[id]?.isRenaming ?? false }
    /// Rows and tiles crossed during a drag catch up with where the pointer is.
    func refreshHovers() {
        rows.values.forEach { $0.refreshHover() }
        pinnedView.tiles.values.forEach { $0.refreshHover() }
    }
    func updatePinned(_ pinned: [UUID], selected: BrowserTab?, theme: RiseTheme) {
        pinnedView.set(order: pinned, make: { makeTile($0) }, closed: { tabsByID[$0] == nil })
        for id in pinned {
            guard let tab = tabsByID[id] else { continue }
            pinnedView.tiles[id]?.update(tab: tab, selected: id == selected?.id, theme: theme)
        }
    }
    private func makeTile(_ id: UUID) -> PinnedTabTile {
        let tile = PinnedTabTile(tabID: id)
        tile.onSelect = { [weak self] in self?.onSelect?(id) }
        tile.onMenu = { [weak self] event in self?.onTabMenu?(id, event) }
        tile.onHover = { [weak self] hovering in self?.onTabHover?(id, hovering) }
        tile.onPress = { [weak self] in self?.onTabPress?() }
        tile.onDragStart = { [weak self] event in self?.beginPinnedDrag(id, event: event) }
        tile.onDragMove = { [weak self] event in self?.movePinnedDrag(event) }
        tile.onDragEnd = { [weak self] in self?.endPinnedDrag() }
        return tile
    }
    /// The list leaves out a row on its way up to the grid, and holds a place for a tile on
    /// its way down.
    func applyDragToList() {
        func remove(_ id: UUID) {
            guard let index = orderedIDs.firstIndex(of: id) else { return }
            orderedIDs.remove(at: index); displayedRows.remove(at: index)
        }
        if let drag, drag.pinSlot != nil { remove(drag.id) }
        if let index = displayedRows.firstIndex(where: { $0 === listPlaceholder }) {
            orderedIDs.remove(at: index); displayedRows.remove(at: index)
        }
        guard let pinnedDrag, let index = pinnedDrag.listIndex else { listPlaceholder.removeFromSuperview(); return }
        remove(pinnedDrag.id)
        let at = min(index, orderedIDs.count)
        orderedIDs.insert(pinnedDrag.id, at: at); displayedRows.insert(listPlaceholder, at: at)
        if listPlaceholder.superview !== rowsHost { rowsHost.addSubview(listPlaceholder, positioned: .below, relativeTo: nil) }
    }
    /// A tile over the grid stays within the sidebar's width.
    private func insideSidebar(_ frame: NSRect, in overlay: NSView) -> NSRect {
        let edges = convert(bounds.insetBy(dx: TabAppearance.inset, dy: 0), to: overlay)
        var frame = frame
        frame.origin.x = max(edges.minX, min(frame.minX, edges.maxX-frame.width))
        return frame
    }
    private func relayoutForDrag() { applyDragToList(); needsLayout = true; layoutSubtreeIfNeeded() }
    private func gridSlot(at location: NSPoint, count: Int) -> Int {
        let point = pinnedView.convert(location, from: nil)
        return PinnedLayout.slot(nearest: NSPoint(x: point.x-PinnedLayout.sideInset, y: point.y), count: count,
                                 width: pinnedView.bounds.width-2*PinnedLayout.sideInset, tileHeight: pinnedView.tileHeight)
    }
    /// Whether `location` reaches above New Tab, where tabs are pinned; without its row, anywhere
    /// above the list.
    private func isOverGrid(_ location: NSPoint) -> Bool {
        let point = convert(location, from: nil)
        return point.x >= 0 && point.x <= bounds.width && point.y > (minimalNewTab ? 0 : paletteAnchor.minY) && point.y < newTab.frame.midY
    }

    // MARK: Pinning a row

    enum PinningChange { case none, pinning, stopped }
    /// A row dragged above New Tab becomes a tile and opens a slot in the grid for itself.
    func updatePinning(_ drag: SidebarDrag, event: NSEvent) -> PinningChange {
        let wanted = drag.view is TabRow && drag.overlay != nil && isOverGrid(event.locationInWindow)
            && (drag.pinSlot != nil || pinnedView.order.count < PinnedLayout.maximum)
        guard wanted else {
            if drag.pinSlot != nil { stopPinning(drag); return .stopped }
            return .none
        }
        let slot = gridSlot(at: event.locationInWindow, count: pinnedView.order.count+1)
        if drag.pinSlot == nil {
            drag.pinSlot = slot; startPinning(drag)
            pinnedView.setOpening(slot); relayoutForDrag()
        } else if slot != drag.pinSlot {
            drag.pinSlot = slot; pinnedView.setOpening(slot); relayoutForDrag(); crossingClick()
        }
        guard let ghost = drag.ghost, let overlay = drag.overlay else { return .pinning }
        let frames = pinnedView.slotFrames(width: pinnedView.bounds.width)
        let size = frames[min(slot, frames.count-1)].size
        let point = overlay.convert(event.locationInWindow, from: nil)
        hold(ghost, at: insideSidebar(NSRect(x: point.x-drag.grab.x*size.width, y: point.y-drag.grab.y*size.height,
                                             width: size.width, height: size.height), in: overlay), grab: drag.grab)
        return .pinning
    }
    /// Holds a dragged tile under the pointer as it springs to `target`'s size: the point the
    /// pointer holds stays put while the rest grows or shrinks around it.
    /// It bounces a little becoming a tile, and settles without one becoming a row again.
    private func hold(_ tile: PinnedTabTile, at target: NSRect, grab: NSPoint) {
        tile.follow(size: target.size, bouncy: !tile.rowStyle) { size in
            NSPoint(x: target.minX+grab.x*(target.width-size.width), y: target.minY+grab.y*(target.height-size.height))
        }
    }
    private func startPinning(_ drag: SidebarDrag) {
        guard let row = drag.view as? TabRow, let overlay = drag.overlay, let tab = tabsByID[drag.id] else { return }
        if drag.ghost == nil {
            let ghost = PinnedTabTile(tabID: drag.id); ghost.takesClicks = false
            ghost.update(tab: tab, selected: selectedTabID == drag.id, theme: newTab.theme)
            ghost.rowStyle = true; ghost.frame = row.frame
            overlay.addSubview(ghost); ghost.layoutSubtreeIfNeeded()
            drag.ghost = ghost
        }
        drag.ghost?.onRest = nil
        row.alphaValue = 0
        if let ghost = drag.ghost { shadow(overlay.shadowView, follow: ghost) }
        drag.grab = NSPoint(x: drag.grabOffset.x/max(1, row.bounds.width), y: drag.grabOffset.y/max(1, row.bounds.height))
        drag.ghost?.rowStyle = false
        detachmentClick()
    }
    /// Back below New Tab: the tile grows into the row again, which takes over once it has.
    private func stopPinning(_ drag: SidebarDrag) {
        drag.pinSlot = nil; pinnedView.setOpening(nil)
        if let ghost = drag.ghost {
            ghost.rowStyle = true
            ghost.onRest = { [weak self, weak drag] in
                guard let drag, drag.ghost === ghost, drag.pinSlot == nil else { return }
                self?.retireGhost(drag)
            }
        }
        // Back in the list at its top, under the pointer.
        orderedIDs.insert(drag.id, at: 0); displayedRows.insert(drag.view, at: 0)
        onReorder?(orderedIDs)
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    /// While a tile grows back into the row, it follows the row the drag places.
    func followRow(_ drag: SidebarDrag) {
        guard drag.pinSlot == nil, let ghost = drag.ghost else { return }
        if !ghost.isMoving { retireGhost(drag); return }
        hold(ghost, at: drag.view.frame, grab: drag.grab)
        // The drag just placed the shadow with the row; it stays with the tile until they meet.
        ghost.onStep?()
    }
    func retireGhost(_ drag: SidebarDrag) {
        guard let ghost = drag.ghost else { return }
        ghost.onRest = nil; ghost.onStep = nil; ghost.removeFromSuperview(); drag.ghost = nil
        drag.view.alphaValue = 1
        if let shadow = drag.overlay?.shadowView {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            shadow.frame = drag.view.frame; shadow.alphaValue = 1
            shadow.layer?.shadowPath = PageOutline.path(in: shadow.bounds, radius: TabAppearance.radius, continuous: true)
            CATransaction.commit()
        }
    }
    /// The drag's shadow takes the tile's shape as it changes, fading as it becomes a tile and
    /// back as it becomes a row.
    private func shadow(_ shadow: NSView, follow ghost: PinnedTabTile) {
        shadow.isHidden = false
        ghost.onStep = { [weak ghost, weak shadow] in
            guard let ghost, let shadow, let layer = shadow.layer else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: TabDragMotion.springKey)
            shadow.frame = ghost.frame; shadow.alphaValue = ghost.shape
            layer.shadowPath = PageOutline.path(in: shadow.bounds, radius: ghost.cornerRadius, continuous: true)
            CATransaction.commit()
        }
        ghost.onStep?()
    }
    /// Dropped over the grid: the tab is pinned where its slot was, and the tile settles there.
    func landPinnedRow(_ drag: SidebarDrag) {
        guard let slot = drag.pinSlot else { return }
        pinnedView.setOpening(nil)
        drag.view.removeFromSuperview(); drag.view.alphaValue = 1
        (drag.view as? TabRow)?.dragFill = nil
        drag.pinSlot = nil
        onPin?(drag.id, slot)
        needsLayout = true; layoutSubtreeIfNeeded()
        land(drag.ghost, on: pinnedView.tiles[drag.id], overlay: drag.overlay)
    }
    /// Settles a dragged tile on the view taking its place, which shows once it's there.
    /// Into the grid it bounces a little; back into the list it doesn't.
    private func land(_ moving: PinnedTabTile?, on target: NSView?, overlay: NSView?) {
        guard let moving, let overlay, let target, let host = target.superview else { overlay?.removeFromSuperview(); return }
        target.alphaValue = 0
        let destination = host.convert(target.frame, to: overlay)
        moving.rowStyle = target is TabRow
        if let row = target as? TabRow { moving.settle(into: restingFill(for: row)) }
        moving.move(to: destination, bouncy: !(target is TabRow)) { [weak self] in
            overlay.removeFromSuperview(); target.alphaValue = 1
            self?.refreshHovers()
        }
    }
    /// What a row shows at rest: selected, under the pointer, or nothing.
    private func restingFill(for row: TabRow) -> NSColor {
        let theme = newTab.theme
        if row.tabID == selectedTabID { return TabAppearance.selectedFill(theme) }
        let pointer = window.map { row.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        if let pointer, row.bounds.contains(pointer) { return TabAppearance.hoverFill(theme) }
        return TabAppearance.dragFill(theme, sidebarFraction: 0.3).withAlphaComponent(0)
    }
    /// Where a tab shows now, before Pin or Unpin moves it.
    func pinFlightStart(for id: UUID) -> NSRect? {
        guard let view = anchor(for: id), view.window != nil else { return nil }
        return view.convert(view.bounds, to: nil)
    }
    /// Pinned or unpinned from a menu, the tab travels from where it was to its new place.
    func flyPinChange(_ id: UUID, from start: NSRect) {
        guard let host = window?.contentView, let tab = tabsByID[id] else { return }
        layoutSubtreeIfNeeded()
        let tile = pinnedView.tiles[id]
        guard let target: NSView = tile?.superview === pinnedView ? tile : rows[id], target.superview != nil else { return }
        let overlay = TabDragOverlay(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]; overlay.shadowView.isHidden = true
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        let ghost = PinnedTabTile(tabID: id); ghost.takesClicks = false
        ghost.update(tab: tab, selected: selectedTabID == id, theme: newTab.theme)
        ghost.rowStyle = target === tile
        ghost.frame = overlay.convert(start, from: nil)
        overlay.addSubview(ghost); ghost.layoutSubtreeIfNeeded()
        land(ghost, on: target, overlay: overlay)
    }

    // MARK: Dragging a tile

    func beginPinnedDrag(_ id: UUID, event: NSEvent) {
        guard drag == nil, pinnedDrag == nil, !isSearchingTabs, let tile = pinnedView.tiles[id], let host = window?.contentView else { return }
        finishReturningTab()
        // Picked up again on its way into its slot, it goes on from where it's shown.
        let shown = tile.convert(tile.bounds, to: nil)
        if tile.superview is TabDragOverlay { tile.finishMotion() }
        guard tile.superview === pinnedView else { return }
        let grabbed = NSPoint(x: event.locationInWindow.x-shown.minX, y: shown.maxY-event.locationInWindow.y)
        let overlay = TabDragOverlay(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]; overlay.shadowView.isHidden = true
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        let frame = overlay.convert(shown, from: nil)
        overlay.addSubview(tile); tile.frame = frame
        pinnedDrag = PinnedDrag(id: id, tile: tile, overlay: overlay,
                                grab: NSPoint(x: grabbed.x/max(1, frame.width), y: grabbed.y/max(1, frame.height)))
        (window as? BrowserWindow)?.isDraggingTab = true
    }
    func movePinnedDrag(_ event: NSEvent) {
        guard let pinnedDrag else { return }
        let location = event.locationInWindow, tile = pinnedDrag.tile
        let point = pinnedDrag.overlay.convert(location, from: nil)
        if isOverGrid(location) || pinnedView.held == nil && convert(location, from: nil).y < newTab.frame.minY {
            if pinnedDrag.listIndex != nil {
                pinnedDrag.listIndex = nil; pinnedView.held = nil; tile.rowStyle = false
                relayoutForDrag()
            }
            let slot = gridSlot(at: location, count: pinnedView.order.count)
            if slot != pinnedView.order.firstIndex(of: pinnedDrag.id) {
                pinnedView.move(pinnedDrag.id, to: slot); crossingClick()
                onReorderPinned?(pinnedView.order)
                pinnedView.layoutTiles(animated: true)
            }
            let frames = pinnedView.slotFrames(width: pinnedView.bounds.width)
            let size = frames[min(slot, frames.count-1)].size
            hold(tile, at: insideSidebar(NSRect(x: point.x-pinnedDrag.grab.x*size.width, y: point.y-pinnedDrag.grab.y*size.height,
                                                width: size.width, height: size.height), in: pinnedDrag.overlay), grab: pinnedDrag.grab)
            return
        }
        if pinnedDrag.listIndex == nil {
            pinnedView.held = pinnedDrag.id; tile.rowStyle = true
            detachmentClick()
        }
        // Its place among the rows as they'd stand without it.
        let y = rowsHost.convert(location, from: nil).y
        var top: CGFloat = 0, index = 0
        for row in displayedRows where row !== listPlaceholder {
            let height = (row as? SplitTabRow)?.rowHeight ?? (row as? TabRow)?.rowHeight ?? TabAppearance.height
            if top+height/2 < y { index += 1 }
            top += height+TabAppearance.spacing
        }
        if index != pinnedDrag.listIndex {
            if pinnedDrag.listIndex != nil { crossingClick() }
            pinnedDrag.listIndex = index; relayoutForDrag()
        }
        let height = TabAppearance.height, x = convert(NSPoint(x: TabAppearance.inset, y: 0), to: pinnedDrag.overlay).x
        hold(tile, at: NSRect(x: x, y: point.y-pinnedDrag.grab.y*height, width: bounds.width-2*TabAppearance.inset, height: height),
             grab: pinnedDrag.grab)
    }
    func endPinnedDrag(cancelled: Bool = false) {
        guard let pinnedDrag else { return }
        let id = pinnedDrag.id, tile = pinnedDrag.tile
        (window as? BrowserWindow)?.isDraggingTab = false
        if let index = pinnedDrag.listIndex, !cancelled {
            // Dropped in the list: unpinned there, and the tile becomes its row.
            self.pinnedDrag = nil; pinnedView.held = nil
            relayoutForDrag()
            onUnpin?(id, index)
            needsLayout = true; layoutSubtreeIfNeeded()
            land(tile, on: rows[id], overlay: pinnedDrag.overlay)
            return
        }
        self.pinnedDrag = nil; pinnedView.held = nil; tile.rowStyle = false
        relayoutForDrag()
        guard let index = pinnedView.order.firstIndex(of: id), pinnedView.tiles[id] === tile else {
            pinnedDrag.overlay.removeFromSuperview(); return
        }
        let frames = pinnedView.slotFrames(width: pinnedView.bounds.width)
        let target = frames[min(index, frames.count-1)]
        tile.move(to: pinnedView.convert(target, to: pinnedDrag.overlay)) { [weak self] in
            guard let self else { return }
            if self.pinnedView.tiles[id] === tile { self.pinnedView.addSubview(tile); tile.frame = target }
            pinnedDrag.overlay.removeFromSuperview(); self.refreshHovers()
        }
    }
}
