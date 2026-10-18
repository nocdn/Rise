import AppKit

/// The native overlay scroller still handles fading and hit testing; its ink is a 3 pt line
/// pinned to the edge, so it stays put as the scroller widens under the pointer. It's light,
/// and darkens while the pointer is over it.
final class GmailScroller: NSScroller {
    /// A card keeps it out of sight from opening until the reader scrolls.
    var isRevealed = true { didSet { if isRevealed != oldValue { needsDisplay = true } } }
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var hoverArea: NSTrackingArea?
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        guard isRevealed else { return }
        let knob = rect(for: .knob)
        let thin = NSRect(x: bounds.maxX-7, y: knob.minY, width: 3, height: knob.height)
        NSColor.secondaryLabelColor.withAlphaComponent(isHovered ? 0.6 : 0.28).setFill()
        NSBezierPath(roundedRect: thin, xRadius: 1.5, yRadius: 1.5).fill()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
        isHovered = window.map { visibleRect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); isHovered = true }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); isHovered = false }
    override func viewDidHide() { super.viewDidHide(); isHovered = false }
}

/// A card's list: its scroller appears once the reader scrolls, not as the card opens.
final class CardScrollView: NSScrollView {
    func hideScrollerUntilScrolled() { (verticalScroller as? GmailScroller)?.isRevealed = false }
    override func scrollWheel(with event: NSEvent) {
        (verticalScroller as? GmailScroller)?.isRevealed = true
        super.scrollWheel(with: event)
    }
}

final class GmailEmailRow: NSButton {
    static let inset: CGFloat = 14
    let email: GmailEmail
    let sender = NSTextField(labelWithString: "")
    let subject = NSTextField(labelWithString: "")
    let preview = NSTextField(wrappingLabelWithString: "")
    private let divider = Surface()
    var onOpen: (() -> Void)?
    /// The card sets this from the pointer, since scrolling moves rows without telling them.
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var theme = RiseTheme.neutral
    override var isFlipped: Bool { true }
    init(_ email: GmailEmail) {
        self.email = email
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(openEmail)
        sender.stringValue = email.sender; sender.font = .systemFont(ofSize: 14, weight: .medium)
        sender.lineBreakMode = .byTruncatingTail
        subject.stringValue = email.subject; subject.font = .systemFont(ofSize: 13, weight: .medium)
        subject.lineBreakMode = .byTruncatingTail; subject.maximumNumberOfLines = 1
        preview.stringValue = email.preview; preview.font = .systemFont(ofSize: 12, weight: .regular)
        preview.maximumNumberOfLines = 3; preview.cell?.truncatesLastVisibleLine = true
        [sender, subject, preview, divider].forEach(addSubview)
        setAccessibilityLabel(email.sender+", "+email.subject)
        setAccessibilityValue(email.preview)
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyTheme(_ theme: RiseTheme, last: Bool) {
        self.theme = theme
        sender.textColor = theme.text; subject.textColor = theme.text
        preview.textColor = theme.text.withAlphaComponent(0.65)
        divider.fill = theme.text.withAlphaComponent(0.12); divider.isHidden = last
        needsDisplay = true
    }
    private func height(_ field: NSTextField, width: CGFloat, lines: Int) -> CGFloat {
        let line = ceil(NSLayoutManager().defaultLineHeight(for: field.font!))
        return min(line*CGFloat(lines), ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? line))
    }
    static let top: CGFloat = 10, bottom: CGFloat = 10, gap: CGFloat = 2, previewGap: CGFloat = 4
    private func lineHeight(_ field: NSTextField) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: field.font!)) }
    func fittingHeight(width: CGFloat) -> CGFloat {
        let textWidth = width-2*(Self.inset-2)
        let previewHeight = email.preview.isEmpty ? 0 : Self.previewGap+height(preview, width: textWidth, lines: 3)
        return Self.top+lineHeight(sender)+Self.gap+lineHeight(subject)+previewHeight+Self.bottom
    }
    override func layout() {
        super.layout()
        let x = Self.inset-2, width = bounds.width-2*x
        sender.frame = NSRect(x: x, y: Self.top, width: width, height: lineHeight(sender))
        subject.frame = NSRect(x: x, y: sender.frame.maxY+Self.gap, width: width, height: lineHeight(subject))
        preview.isHidden = email.preview.isEmpty
        preview.frame = NSRect(x: x, y: subject.frame.maxY+Self.previewGap, width: width, height: height(preview, width: width, lines: 3))
        divider.frame = NSRect(x: 0, y: bounds.height-0.5, width: bounds.width, height: 0.5)
    }
    override func draw(_ dirtyRect: NSRect) {
        if isHovered { theme.text.withAlphaComponent(0.04).setFill(); bounds.fill() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    @objc private func openEmail() { onOpen?() }
}

/// The same surface and positioning springs as the PR card, with a bounded, native list.
@MainActor final class GmailTooltip: FlippedView {
    static let width = PullRequestTooltip.width
    static let maximumHeight: CGFloat = 400
    let scroll = CardScrollView()
    private let panel = Surface(radius: FindBar.radius)
    private let clip = FlippedView(), stack = FlippedView()
    private(set) var rows: [GmailEmailRow] = []
    let footer = NSTextField(labelWithString: "")
    let shimmer = InputShimmer()
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    private var height = MotionSpring(0), top = MotionSpring(0)
    private var link: CADisplayLink?, lastTick: CFTimeInterval?
    private var anchorTop: CGFloat = 0, maxBottom: CGFloat = 0, contentHeight: CGFloat = 72
    private var loading = false, hasMore = false, error: String?
    private var layingOut = false
    private var theme = RiseTheme.neutral
    private(set) var key: String?
    var onPointer: ((Bool) -> Void)?
    var onLoadMore: (() -> Void)?
    var onOpen: ((GmailEmail) -> Void)?

    init() {
        super.init(frame: .zero)
        isHidden = true; wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        panel.layer?.cornerCurve = .continuous; panel.layer?.borderWidth = 0.5
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = 0.12
        panel.layer?.shadowRadius = 10; panel.layer?.shadowOffset = NSSize(width: 0, height: -3)
        panel.clipsToBounds = false
        clip.wantsLayer = true; clip.layer?.cornerRadius = FindBar.radius
        clip.layer?.cornerCurve = .continuous; clip.layer?.masksToBounds = true
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.verticalScroller = GmailScroller(); scroll.verticalScroller?.controlSize = .small
        scroll.scrollerStyle = .overlay; scroll.autohidesScrollers = true
        scroll.documentView = stack; scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        footer.font = .systemFont(ofSize: 12)
        shimmer.configureForSmartRename(field: footer)
        retry.isBordered = false; retry.font = .systemFont(ofSize: 12, weight: .medium)
        retry.target = self; retry.action = #selector(retryLoading)
        stack.addSubview(footer); stack.addSubview(retry)
        clip.addSubview(scroll); panel.addSubview(clip); addSubview(panel)
        height.configure(response: FindMotion.swapResponse, bounce: 0)
        top.configure(response: FindMotion.swapResponse, bounce: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden || key == nil ? nil : super.hitTest(point) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onPointer?(true); updateHover() }
    override func mouseExited(with event: NSEvent) { onPointer?(false); updateHover() }
    override func mouseMoved(with event: NSEvent) { updateHover() }
    /// Only the row under the pointer is highlighted, including after the list scrolls under it.
    func updateHover() {
        let point = window.map { stack.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let inside = !isHidden && window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } == true
        for row in rows { row.isHovered = inside && point.map(row.frame.contains) == true }
    }

    /// Comes and goes with the hover cards' motion, out of its tab or out of `growsFrom` when given.
    func present(key: String, inbox: GmailInbox, left: CGFloat, anchorTop: CGFloat, maxBottom: CGFloat, theme: RiseTheme,
                 glides: Bool = false, growsFrom: NSPoint? = nil) {
        let appearing = self.key == nil, switching = self.key != key
        if appearing { CardMotionAnimator.cancelOut(self) }
        self.key = key; self.theme = theme; isHidden = false
        frame.origin.x = left; self.anchorTop = anchorTop; self.maxBottom = maxBottom; tabPoint = growsFrom
        appearance = theme.appearance
        panel.fill = theme == .dark ? theme.popup : TabAppearance.selectedFill(theme)
        panel.layer?.borderColor = theme.border.cgColor
        if switching { rows.forEach { $0.removeFromSuperview() }; rows = []; scroll.contentView.scroll(to: .zero); scroll.hideScrollerUntilScrolled() }
        update(inbox)
        if appearing { height.settle(); if !glides { top.settle() }; render() }
        if appearing && !glides { CardMotionAnimator.animateIn(self, CardMotion.selected, tab: tabOrigin) }
        animate()
    }
    private var tabPoint: NSPoint?
    /// Where the card comes out of its tab, in its own coordinates.
    private var tabOrigin: CGPoint {
        let point = tabPoint ?? NSPoint(x: frame.minX, y: anchorTop+TabAppearance.height/2)
        return CGPoint(x: point.x-frame.minX, y: point.y-frame.minY)
    }
    func update(_ inbox: GmailInbox) {
        guard key != nil else { return }
        loading = inbox.showsLoading; hasMore = inbox.hasMore; error = inbox.error
        if rows.map(\.email) != inbox.emails {
            let existing = Dictionary(uniqueKeysWithValues: rows.map { ($0.email.id, $0) })
            let next = inbox.emails.map { email -> GmailEmailRow in
                if let row = existing[email.id], row.email == email { return row }
                let row = GmailEmailRow(email)
                row.onOpen = { [weak self] in self?.onOpen?(email) }; return row
            }
            rows.filter { !next.contains($0) }.forEach { $0.removeFromSuperview() }
            next.filter { $0.superview == nil }.forEach(stack.addSubview)
            rows = next
        }
        layoutList(); updateHover(); animate()
        DispatchQueue.main.async { [weak self] in self?.loadIfNearEnd() }
    }
    /// Plays the way in again, for the motion tester.
    func replayMotion() {
        guard key != nil, !isHidden else { return }
        CardMotionAnimator.animateIn(self, CardMotion.selected, tab: tabOrigin)
    }
    /// Goes with the hover cards' motion, or at once with `animated: false`.
    func dismiss(animated: Bool = true) {
        let wasShown = key != nil
        key = nil; link?.invalidate(); link = nil; shimmer.cancel()
        height.settle(); top.settle()
        guard animated, wasShown else { isHidden = true; return }
        CardMotionAnimator.animateOut(self, CardMotion.selected, tab: tabOrigin) { [weak self] in
            if self?.key == nil { self?.isHidden = true }
        }
    }
    private func layoutList() {
        layingOut = true
        defer { layingOut = false }
        let origin = scroll.contentView.bounds.origin
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            row.applyTheme(theme, last: index == rows.count-1 && !loading && error == nil)
            row.frame = NSRect(x: 0, y: y, width: Self.width, height: row.fittingHeight(width: Self.width)); y += row.frame.height
        }
        let showsFooter = loading || error != nil || rows.isEmpty
        footer.isHidden = !showsFooter; retry.isHidden = error == nil
        if showsFooter {
            let text = error ?? (loading ? (rows.isEmpty ? "Loading emails" : "Loading more emails") : "No emails in this category")
            if footer.stringValue != text { shimmer.cancel(); footer.stringValue = text }
            footer.textColor = theme.muted; shimmer.baseColor = theme.muted; shimmer.bandColor = theme.text
            let textWidth = ceil(footer.attributedStringValue.size().width)+4
            footer.frame = NSRect(x: (Self.width-textWidth)/2, y: y+24, width: textWidth, height: 17)
            shimmer.frame = footer.bounds
            if loading, !shimmer.isRunning, window != nil { shimmer.start() }
            if !loading { shimmer.cancel() }
            if error != nil { retry.frame = NSRect(x: (Self.width-100)/2, y: y+47, width: 100, height: 22) }
            y += error == nil ? 65 : 83
        } else { shimmer.cancel() }
        contentHeight = max(65, y)
        stack.setFrameSize(NSSize(width: Self.width, height: contentHeight))
        height.target = min(contentHeight, Self.maximumHeight, max(65, maxBottom-8))
        top.target = max(8, min(anchorTop, maxBottom-height.target))
        render(scrollOrigin: origin)
    }
    private func render(scrollOrigin: NSPoint? = nil) {
        let wasLayingOut = layingOut; layingOut = true
        defer { layingOut = wasLayingOut }
        let origin = scrollOrigin ?? scroll.contentView.bounds.origin
        frame = NSRect(x: frame.minX, y: top.value, width: Self.width, height: max(0, height.value))
        panel.frame = bounds; clip.frame = bounds; scroll.frame = clip.bounds
        // AppKit otherwise keeps the bottom edge when an initially short document
        // grows. Preserve the reader's position as rows arrive and the card resizes.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(origin.y, contentHeight-scroll.contentView.bounds.height))))
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    @objc private func scrolled() { updateHover(); loadIfNearEnd() }
    private func loadIfNearEnd() {
        guard !layingOut, key != nil, !isHidden, !loading, error == nil, hasMore, !rows.isEmpty,
              scroll.contentView.bounds.height > 0,
              scroll.contentView.bounds.maxY >= contentHeight-160 else { return }
        onLoadMore?()
    }
    @objc private func retryLoading() { onLoadMore?() }
    private func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { height.settle(); top.settle(); render(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        height.step(dt); top.step(dt)
        if height.isResting(within: 0.05), top.isResting(within: 0.05) {
            link.invalidate(); self.link = nil; height.settle(); top.settle()
        }
        render()
    }
}
