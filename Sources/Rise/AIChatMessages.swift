import AppKit

/// A text view for the chat's text: TextKit 1, as the streaming effect paints with its layout
/// manager, selectable but not editable, with no insets of its own.
@MainActor func makeAIChatTextView() -> TokenTextView {
    let view = TokenTextView()
    view.isEditable = false; view.isSelectable = true; view.drawsBackground = false; view.isRichText = true
    view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
    view.textContainer?.widthTracksTextView = false
    view.isVerticallyResizable = false; view.isHorizontallyResizable = false
    // Words fade and sharpen into place without sliding in.
    view.tokenLayout.travels = false
    return view
}
extension NSTextView {
    /// The text's size laid out `width` wide, with the widest line's own width.
    func usedSize(width: CGFloat) -> NSSize {
        guard let container = textContainer, let manager = layoutManager else { return .zero }
        if container.containerSize.width != width { container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude) }
        manager.ensureLayout(for: container)
        var widest: CGFloat = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, _ in widest = max(widest, used.maxX) }
        return NSSize(width: ceil(widest), height: ceil(manager.usedRect(for: container).height))
    }
}

/// An attached page, as Dia shows one: its favicon on a little white card, then its title over
/// its site. In the composer it can be taken off again.
@MainActor final class AIChatPageChip: FlippedView {
    let attachment: AIChatAttachment
    private let fill = Surface(radius: AIChatStyle.chipRadius)
    private let tile = Surface(radius: AIChatStyle.tileRadius)
    private let icon = NSImageView()
    private let title = label("", size: 13)
    private let site = label("", size: 13)
    private(set) var removeButton: AIChatRemoveButton?
    private var hovering = false
    var onRemove: (() -> Void)?

    init(_ attachment: AIChatAttachment, removable: Bool) {
        self.attachment = attachment
        super.init(frame: NSRect(origin: .zero, size: AIChatStyle.chipSize))
        fill.layer?.cornerCurve = .continuous; tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 0.5
        tile.layer?.shadowColor = NSColor.black.cgColor; tile.layer?.shadowOpacity = 0.06
        tile.layer?.shadowRadius = 1.5; tile.layer?.shadowOffset = NSSize(width: 0, height: -1)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = attachment.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        title.stringValue = attachment.title.isEmpty ? attachment.subtitle : attachment.title
        site.stringValue = attachment.subtitle
        [title, site].forEach { $0.lineBreakMode = .byTruncatingTail; $0.cell?.truncatesLastVisibleLine = true }
        tile.addSubview(icon)
        [fill, tile, title, site].forEach(addSubview)
        if removable {
            // Dia's: a disc over the top-right corner, its cross 6.5 pt across with 1.5 pt strokes,
            // shown while the pointer is on the page.
            let button = AIChatRemoveButton(symbol: "xmark", size: 8, title: "Remove Page", action: {})
            button.image = TablerIcon.image(TablerIcon.cross, size: 10, strokeWidth: 1.5, description: "Remove Page")
            button.actionBlock = { [weak self] in self?.onRemove?() }
            button.layer?.cornerRadius = Self.removeSize/2; button.isHidden = true
            addSubview(button); removeButton = button
        }
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("Attached page: \(title.stringValue)")
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyColors(_ colors: AIChatColors) {
        fill.fill = colors.chip; tile.fill = colors.tile; tile.layer?.borderColor = colors.tileBorder.cgColor
        title.textColor = colors.text; site.textColor = colors.dark ? colors.muted : NSColor(hex: 0x797A7A)
        if attachment.favicon == nil { icon.contentTintColor = colors.muted }
        if let button = removeButton {
            button.baseColor = colors.remove; button.hoverColor = colors.removeHover
            button.tint = colors.removeIcon; button.hoverTint = colors.removeHoverIcon
            button.refreshHoverState()
        }
    }
    override func layout() {
        super.layout()
        fill.frame = bounds
        let tileFrame = NSRect(origin: NSPoint(x: AIChatStyle.tileInset.width, y: AIChatStyle.tileInset.height), size: AIChatStyle.tileSize)
        tile.frame = tileFrame
        tile.layer?.shadowPath = CGPath(roundedRect: tile.bounds, cornerWidth: AIChatStyle.tileRadius, cornerHeight: AIChatStyle.tileRadius, transform: nil)
        icon.frame = NSRect(x: (tileFrame.width-16)/2, y: (tileFrame.height-16)/2, width: 16, height: 16)
        // Labels draw 2 pt in from their frames.
        let textX = tileFrame.maxX+6, textWidth = max(0, bounds.width-textX-10)
        title.frame = NSRect(x: textX, y: 9.5, width: textWidth, height: 17)
        site.frame = NSRect(x: textX, y: 27.5, width: textWidth, height: 17)
        removeButton?.frame = removeFrame
    }
    /// The remove button's disc, centred 4 pt in from the chip's top-right corner.
    static let removeSize: CGFloat = 18, removeInset: CGFloat = 4
    /// How far it reaches past the chip's top and right edges.
    static let removeOverhang = removeSize/2-removeInset
    private var removeFrame: NSRect {
        NSRect(x: bounds.width-Self.removeInset-Self.removeSize/2, y: Self.removeInset-Self.removeSize/2, width: Self.removeSize, height: Self.removeSize)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        guard removeButton != nil else { return }
        // The chip and the part of the button past its corner, so moving onto the button keeps it.
        addTrackingArea(NSTrackingArea(rect: bounds.union(removeFrame), options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        removeButton?.isHidden = false
        // The pointer may have come straight onto the button, which took no entry while hidden.
        removeButton?.refreshHoverState()
    }
    override func mouseExited(with event: NSEvent) { removeButton?.isHidden = true }
    // The remove button pokes out past the top-right corner.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let button = removeButton, !button.isHidden, button.frame.contains(convert(point, from: superview)) { return button }
        return super.hitTest(point)
    }
}

/// A page chip's remove button, whose cross changes color along with its disc on hover.
@MainActor final class AIChatRemoveButton: ChromeButton {
    var tint = NSColor.black, hoverTint = NSColor.white
    override func refreshHoverState(at point: NSPoint? = nil) {
        super.refreshHoverState(at: point)
        let color = hover ? hoverTint : tint
        if contentTintColor != color { contentTintColor = color }
    }
}

/// The question, right-aligned in its grey bubble.
@MainActor final class AIChatBubble: FlippedView {
    let fill = Surface(radius: AIChatStyle.bubbleRadius)
    let textView = makeAIChatTextView()
    let text: String
    private var colors: AIChatColors?
    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        fill.layer?.cornerCurve = .continuous
        [fill, textView].forEach(addSubview)
        textView.setAccessibilityLabel("Your question")
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyColors(_ colors: AIChatColors) {
        guard colors != self.colors else { return }
        self.colors = colors
        fill.fill = colors.bubble
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: AIChatStyle.attributes(
            AIChatStyle.font(AIChatStyle.bubbleFontSize), color: colors.text, lineHeight: AIChatStyle.bubbleLineHeight)))
        textView.selectedTextAttributes = [.backgroundColor: colors.dark ? NSColor(hex: 0x3A3A3A) : NSColor(hex: 0xDADADA)]
    }
    /// Its size at most `width` wide, wrapping the question as needed.
    func fit(maxWidth: CGFloat) -> NSSize {
        let padding = AIChatStyle.bubblePadding
        let text = textView.usedSize(width: max(40, maxWidth-2*padding.width))
        textView.textContainer?.containerSize = NSSize(width: text.width+1, height: .greatestFiniteMagnitude)
        textView.frame = NSRect(x: padding.width, y: padding.height, width: text.width+1, height: text.height)
        return NSSize(width: text.width+2*padding.width, height: text.height+2*padding.height)
    }
    override func layout() { super.layout(); fill.frame = bounds }
}

/// The answer: "Thinking…" while the model thinks, then how long it thought, the answer played
/// out a word at a time with the find bar's token effect, and Copy and Regenerate once it's done.
@MainActor final class AIChatAnswerView: FlippedView {
    enum Phase: Equatable { case thinking, answering, done, failed }
    private(set) var phase = Phase.thinking
    private let thinking = label("Thinking…", size: 13, weight: .medium)
    private let thought = label("", size: 13, weight: .medium)
    private let shimmer = InputShimmer()
    private var thinkingItem: PresenceItem, thoughtItem: PresenceItem
    let textView = makeAIChatTextView()
    private var stream = TokenStream(), laidOut = "", paintedFrom = 0, failure = ""
    /// The model's answer so far, as Markdown.
    private(set) var markdown = ""
    private let copyButton = ChromeButton(symbol: "square.on.square", size: 13, title: "Copy", action: {})
    private let regenerateButton = ChromeButton(symbol: "arrow.clockwise", size: 13, title: "Regenerate", action: {})
    private var actions = MotionSpring(0)
    private var colors = AIChatColors(.neutral), applied: AIChatColors?
    private let started = CACurrentMediaTime()
    var onCopy: (() -> Void)?
    var onRegenerate: (() -> Void)?
    var canRegenerate = false { didSet { regenerateButton.isHidden = !canRegenerate } }

    init(thinking: Bool = true) {
        thinkingItem = PresenceItem(self.thinking, shown: thinking)
        thoughtItem = PresenceItem(thought, shown: false)
        super.init(frame: .zero)
        shimmer.field = self.thinking; shimmer.bandWidth = 60
        copyButton.actionBlock = { [weak self] in self?.onCopy?() }
        regenerateButton.actionBlock = { [weak self] in self?.onRegenerate?() }
        [copyButton, regenerateButton].forEach { $0.alphaValue = 0; $0.isHidden = true; $0.layer?.cornerRadius = 6 }
        actions.configure(response: FindMotion.swapResponse, bounce: 0)
        [self.thinking, thought, shimmer, textView, copyButton, regenerateButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A finished answer shown at once, as when the panel is drawn again.
    var hasThoughtRow: Bool { thinkingItem.shown || thoughtItem.shown }

    func applyColors(_ colors: AIChatColors) {
        guard colors != applied else { return }
        self.colors = colors; applied = colors
        [thinking, thought].forEach { $0.textColor = colors.muted }
        shimmer.baseColor = colors.muted; shimmer.bandColor = colors.text
        shimmer.setRestingColor(colors.muted)
        [copyButton, regenerateButton].forEach { $0.contentTintColor = colors.actionIcon; $0.hoverColor = colors.hover }
        textView.selectedTextAttributes = [.backgroundColor: colors.dark ? NSColor(hex: 0x3A3A3A) : NSColor(hex: 0xDADADA)]
        textView.linkTextAttributes = [.foregroundColor: colors.text, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: colors.muted, .cursor: NSCursor.pointingHand]
        render(at: CACurrentMediaTime())
    }

    /// Shimmers "Thinking…" once the answer is on screen.
    func beginThinking() { if phase == .thinking { shimmer.start() } }
    /// The model's text so far.
    func receive(_ text: String, now: Double = CACurrentMediaTime()) {
        if phase == .thinking {
            phase = .answering
            thought.stringValue = AIChatPrompt.thought(now-started)
            shimmer.cancel(); thinkingItem.set(false); thoughtItem.set(true)
        }
        markdown = text; stream.receive(text); layOut(now: now)
    }
    func finish(now: Double = CACurrentMediaTime()) {
        if phase == .thinking { receive("", now: now) }
        phase = .done; stream.finish(); layOut(now: now)
    }
    /// Shows why there's no answer, under whatever of it came.
    func fail(_ message: String, now: Double = CACurrentMediaTime()) {
        shimmer.cancel()
        if markdown.isEmpty { thinkingItem.set(false); thoughtItem.set(false) }
        phase = .failed; failure = message; stream.finish(); stream.revealAll(at: now)
        laidOut = ""; layOut(now: now)
    }
    /// Shown straight away: everything that arrived, with no effect.
    func revealAll(now: Double = CACurrentMediaTime()) {
        thinkingItem.settle(); thoughtItem.settle(); actions.settle()
        guard !stream.isEmpty else { return }
        stream.revealAll(at: now); textView.paint(stream, from: &paintedFrom)
    }

    private func layOut(now: Double) {
        let ready = stream.text
        let display = failure.isEmpty ? ready : (ready.isEmpty ? failure : ready+"\n\n"+failure)
        guard display != laidOut else { return }
        laidOut = display
        let text = NSMutableAttributedString(attributedString: AIChatMarkdown.render(ready, colors: colors, finished: phase != .answering))
        if !failure.isEmpty {
            if text.length > 0 { text.append(NSAttributedString(string: "\n", attributes: AIChatStyle.attributes(color: colors.text, spacing: AIChatStyle.paragraphSpacing))) }
            text.append(NSAttributedString(string: failure, attributes: AIChatStyle.attributes(color: colors.muted)))
        }
        textView.textStorage?.setAttributedString(text)
        stream.base = OKLab(colors.text)
        if !stream.isEmpty { stream.place(in: textView.string as NSString, at: now) }
        paintedFrom = 0; textView.paint(stream, from: &paintedFrom)
        needsLayout = true; superview?.needsLayout = true
    }

    /// Steps the labels' swap, the words' entrance and the actions' fade. True while any moves.
    func step(_ dt: Double, now: Double) -> Bool {
        thinkingItem.step(dt); thoughtItem.step(dt)
        _ = stream.step(at: now)
        textView.paint(stream, from: &paintedFrom)
        let showsActions = (phase == .done && !stream.isRevealing && !markdown.isEmpty)
        actions.target = showsActions ? 1 : 0; actions.step(dt)
        render(at: now)
        return !(thinkingItem.isResting && thoughtItem.isResting && !stream.needsFrames && actions.isResting(within: 0.002))
    }

    /// The thought row, then the answer, then the actions.
    func height(for width: CGFloat) -> CGFloat {
        let text = textView.usedSize(width: width)
        var height = (hasThoughtRow ? 16+AIChatStyle.answerGap : 0)+text.height
        if phase == .done || phase == .failed, !markdown.isEmpty { height += AIChatStyle.actionsGap+24 }
        return height
    }
    override func layout() { super.layout(); render(at: CACurrentMediaTime()) }
    private func render(at now: Double) {
        let width = bounds.width
        // A label's own 2 pt inset would put its text right of the answer's.
        let row = NSRect(x: -2, y: 0, width: width+2, height: 16)
        thinkingItem.render(at: row); thoughtItem.render(at: row)
        shimmer.frame = thinking.frame.insetBy(dx: 0, dy: -3)
        let top = hasThoughtRow ? 16+AIChatStyle.answerGap : 0
        let text = textView.usedSize(width: width)
        textView.frame = NSRect(x: 0, y: top, width: width, height: text.height)
        let y = top+text.height+AIChatStyle.actionsGap
        copyButton.frame = NSRect(x: -5, y: y, width: 24, height: 24)
        regenerateButton.frame = NSRect(x: 21, y: y, width: 24, height: 24)
        let alpha = CGFloat(min(1, max(0, actions.value)))
        copyButton.alphaValue = alpha; copyButton.isHidden = alpha < 0.01
        regenerateButton.alphaValue = alpha; regenerateButton.isHidden = alpha < 0.01 || !canRegenerate
    }
}
