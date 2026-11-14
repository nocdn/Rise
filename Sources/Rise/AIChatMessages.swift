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
            // Dia's: a disc over the top-right corner, its cross 5 pt across with 1.5 pt strokes,
            // shown while the pointer is on the page.
            let button = AIChatRemoveButton(title: "Remove Page")
            button.action = { [weak self] in self?.onRemove?() }
            button.isHidden = true
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
        removeButton?.applyColors(colors)
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
    /// The remove button's disc, centred 4 pt in from the chip's top-right corner, in its ring.
    static let removeSize = AIChatRemoveButton.size, removeInset: CGFloat = 4
    /// How far it reaches past the chip's top and right edges, ring and all.
    static let removeOverhang = removeSize/2+AIChatRemoveButton.ring-removeInset
    private var removeFrame: NSRect {
        let outer = Self.removeSize+2*AIChatRemoveButton.ring
        return NSRect(x: bounds.width-Self.removeInset-outer/2, y: Self.removeInset-outer/2, width: outer, height: outer)
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
    /// A middle click takes the page off, as it closes a tab in the sidebar: pressed and let go
    /// on the same chip, anywhere on it, its button included.
    private var middlePressed = false
    override func otherMouseDown(with event: NSEvent) {
        guard removeButton != nil, event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        middlePressed = true
    }
    override func otherMouseUp(with event: NSEvent) {
        guard middlePressed, event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        middlePressed = false
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) || removeFrame.contains(point) { onRemove?() }
    }
    // The remove button pokes out past the top-right corner.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let button = removeButton, !button.isHidden, let hit = button.hitTest(convert(point, from: superview)) { return hit }
        return super.hitTest(point)
    }
}

/// A page chip's remove button: a disc with a cross, in a ring of the composer's own colour that
/// parts it from the page under it. The disc alone is the button: the pointer on it, and nowhere
/// else, turns it dark; the cross is drawn rather than an image, centred on the disc's middle.
@MainActor final class AIChatRemoveButton: FlippedView {
    static let size: CGFloat = 18, ring: CGFloat = 2
    /// The cross from end to end, and its strokes.
    static let cross: CGFloat = 5, stroke: CGFloat = 1.5
    var action: (() -> Void)?
    private let ringLayer = CAShapeLayer(), disc = CAShapeLayer(), crossLayer = CAShapeLayer()
    private var colors = AIChatColors(.neutral)
    private(set) var hover = false
    private var pressed = false

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size+2*Self.ring, height: Self.size+2*Self.ring))
        wantsLayer = true
        crossLayer.fillColor = nil; crossLayer.lineWidth = Self.stroke; crossLayer.lineCap = .round
        [ringLayer, disc, crossLayer].forEach { $0.actions = ["fillColor": NSNull(), "strokeColor": NSNull(), "path": NSNull(), "position": NSNull(), "bounds": NSNull()]; layer?.addSublayer($0) }
        toolTip = title
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyColors(_ colors: AIChatColors) { self.colors = colors; update() }

    /// The disc's middle, in its own coordinates.
    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    /// On the disc itself, not its ring nor the corners of its square.
    func isOnDisc(_ point: NSPoint) -> Bool { hypot(point.x-center.x, point.y-center.y) <= Self.size/2 }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        for layer in [ringLayer, disc, crossLayer] { layer.frame = bounds; layer.contentsScale = scale }
        let c = center, outer = Self.size/2+Self.ring, inner = Self.size/2, arm = Self.cross/2
        ringLayer.path = CGPath(ellipseIn: CGRect(x: c.x-outer, y: c.y-outer, width: 2*outer, height: 2*outer), transform: nil)
        disc.path = CGPath(ellipseIn: CGRect(x: c.x-inner, y: c.y-inner, width: 2*inner, height: 2*inner), transform: nil)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x-arm, y: c.y-arm)); path.addLine(to: CGPoint(x: c.x+arm, y: c.y+arm))
        path.move(to: CGPoint(x: c.x+arm, y: c.y-arm)); path.addLine(to: CGPoint(x: c.x-arm, y: c.y+arm))
        crossLayer.path = path
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    private func update() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        ringLayer.fillColor = colors.composer.cgColor
        disc.fillColor = (hover ? colors.removeHover : colors.remove).cgColor
        crossLayer.strokeColor = (hover ? colors.removeHoverIcon : colors.removeIcon).cgColor
        CATransaction.commit()
    }
    /// Whether the pointer is on the disc, as it is now: it may have come straight onto it while
    /// the button was hidden.
    func refreshHoverState(at point: NSPoint? = nil) {
        var on = false
        if let window, window.isVisible, !isHiddenOrHasHiddenAncestor {
            on = isOnDisc(convert(point ?? window.mouseLocationOutsideOfEventStream, from: nil))
        }
        guard on != hover else { return }
        hover = on; update()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        refreshHoverState()
    }
    override func mouseEntered(with event: NSEvent) { refreshHoverState(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { refreshHoverState(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { refreshHoverState(at: event.locationInWindow) }
    override func viewDidHide() { super.viewDidHide(); hover = false; pressed = false; update() }
    /// The ring takes a click so it doesn't fall through to the page under it, but does nothing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return hypot(local.x-center.x, local.y-center.y) <= Self.size/2+Self.ring ? self : nil
    }
    override func mouseDown(with event: NSEvent) { pressed = isOnDisc(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { refreshHoverState(at: event.locationInWindow) }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if isOnDisc(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}

/// The question, right-aligned in its grey bubble.
@MainActor final class AIChatBubble: FlippedView {
    let fill = Surface(radius: AIChatStyle.bubbleRadius)
    let textView = makeAIChatTextView()
    /// The question, its mentions of pages as their pills.
    let parts: [AIChatQuestionPart]
    var text: String { AIChatTurn(parts: parts, pages: []).question }
    private var colors: AIChatColors?
    convenience init(_ text: String) { self.init([.text(text)]) }
    init(_ parts: [AIChatQuestionPart]) {
        self.parts = parts
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
        let attributes = AIChatStyle.attributes(AIChatStyle.font(AIChatStyle.bubbleFontSize), color: colors.text, lineHeight: AIChatStyle.bubbleLineHeight)
        textView.textStorage?.setAttributedString(AIChatQuestionPart.attributed(parts, attributes: attributes, style: .bubble(colors)))
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

/// The answer: "Thinking…" while the model thinks, then how long it thought, rolling from one to
/// the other with SwiftUI's numeric text transition; under it each step the model took with its
/// tools, as it takes it; then the answer played out a word at a time with the find bar's token
/// effect, and Copy and Regenerate once it's done.
@MainActor final class AIChatAnswerView: FlippedView {
    enum Phase: Equatable { case thinking, answering, done, failed }
    private(set) var phase = Phase.thinking
    let status = AIChatStatusView()
    private var statusShown: Bool
    private(set) var steps: [AIChatStepRow] = []
    let textView = makeAIChatTextView()
    private var stream = TokenStream(), laidOut = "", paintedFrom = 0, failure = ""
    /// The model's answer so far, as Markdown.
    private(set) var markdown = ""
    private let copyButton = ChromeButton(symbol: "square.on.square", size: 13, title: "Copy", action: {})
    private let regenerateButton = ChromeButton(symbol: "arrow.clockwise", size: 13, title: "Regenerate", action: {})
    private var actions = MotionSpring(0)
    private var colors = AIChatColors(.neutral), applied: AIChatColors?
    /// Since when the model has been thinking, and how long it thought before.
    private var thinkingSince: Double?, thought: Double = 0
    var onCopy: (() -> Void)?
    var onRegenerate: (() -> Void)?
    /// A step about a tab or a page was clicked.
    var onStep: ((AIChatStep.Target) -> Void)?
    var canRegenerate = false { didSet { regenerateButton.isHidden = !canRegenerate } }

    init(thinking: Bool = true, now: Double = CACurrentMediaTime()) {
        statusShown = thinking
        thinkingSince = thinking ? now : nil
        super.init(frame: .zero)
        status.isHidden = !thinking
        status.show("Thinking…", thinking: false, animated: false)
        copyButton.actionBlock = { [weak self] in self?.onCopy?() }
        regenerateButton.actionBlock = { [weak self] in self?.onRegenerate?() }
        [copyButton, regenerateButton].forEach { $0.alphaValue = 0; $0.isHidden = true; $0.layer?.cornerRadius = 6 }
        actions.configure(response: FindMotion.swapResponse, bounce: 0)
        [status, textView, copyButton, regenerateButton].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    var hasThoughtRow: Bool { statusShown }
    /// What the status line says.
    var statusText: String { status.text }

    func applyColors(_ colors: AIChatColors) {
        guard colors != applied else { return }
        self.colors = colors; applied = colors
        status.applyColors(colors)
        steps.forEach { $0.applyColors(colors) }
        [copyButton, regenerateButton].forEach { $0.contentTintColor = colors.actionIcon; $0.hoverColor = colors.hover }
        textView.selectedTextAttributes = [.backgroundColor: colors.dark ? NSColor(hex: 0x3A3A3A) : NSColor(hex: 0xDADADA)]
        textView.linkTextAttributes = [.foregroundColor: colors.text, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .underlineColor: colors.muted, .cursor: NSCursor.pointingHand]
        render(at: CACurrentMediaTime())
    }

    /// Shimmers "Thinking…" once the answer is on screen.
    func beginThinking() { if thinkingSince != nil, statusShown { status.show("Thinking…", thinking: true, animated: false) } }
    /// The model's first words or tool: "Thinking…" rolls into how long it thought, all told.
    func responded(now: Double = CACurrentMediaTime()) {
        guard let since = thinkingSince else { return }
        thinkingSince = nil
        thought += max(0, now-since)
        statusShown = true; status.isHidden = false
        status.show(AIChatPrompt.thought(thought), thinking: false)
        needsLayout = true; superview?.needsLayout = true
    }
    /// The model's thinking again, with its tools' results.
    func thinkAgain(now: Double = CACurrentMediaTime()) {
        guard thinkingSince == nil, phase == .thinking || phase == .answering else { return }
        thinkingSince = now
        statusShown = true; status.isHidden = false
        status.show("Thinking…", thinking: true)
    }
    /// A step the model took, new or changed.
    func setStep(_ id: String, _ step: AIChatStep) {
        if let row = steps.first(where: { $0.id == id }) { row.update(step); return }
        let row = AIChatStepRow(id: id, step: step)
        row.applyColors(colors)
        row.onClick = { [weak self] target in self?.onStep?(target) }
        if window == nil || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { row.presence.settle() }
        steps.append(row); addSubview(row)
        render(at: CACurrentMediaTime())
        superview?.needsLayout = true
    }
    /// Steps still going when the answer stops end where they are.
    private func endSteps() {
        for row in steps where row.step.state == .running { row.update(row.step.failed()) }
    }
    /// The model's text so far.
    func receive(_ text: String, now: Double = CACurrentMediaTime()) {
        if thinkingSince != nil { responded(now: now) }
        if phase == .thinking { phase = .answering }
        markdown = text; stream.receive(text); layOut(now: now)
    }
    func finish(now: Double = CACurrentMediaTime()) {
        if phase == .thinking { receive("", now: now) }
        if thinkingSince != nil { responded(now: now) }
        endSteps()
        phase = .done; stream.finish(); layOut(now: now)
    }
    /// Shows why there's no answer, under whatever of it came.
    func fail(_ message: String, now: Double = CACurrentMediaTime()) {
        if let since = thinkingSince {
            thinkingSince = nil
            if markdown.isEmpty && steps.isEmpty { statusShown = false; status.isHidden = true }
            else { thought += max(0, now-since); status.show(AIChatPrompt.thought(thought), thinking: false) }
        }
        endSteps()
        phase = .failed; failure = message; stream.finish(); stream.revealAll(at: now)
        laidOut = ""; layOut(now: now)
    }
    /// Shown straight away: everything that arrived, with no effect.
    func revealAll(now: Double = CACurrentMediaTime()) {
        actions.settle(); steps.forEach { $0.presence.settle() }
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

    /// Steps the steps' entrance, the words' entrance and the actions' fade. True while any moves.
    func step(_ dt: Double, now: Double) -> Bool {
        steps.forEach { $0.presence.step(dt) }
        _ = stream.step(at: now)
        textView.paint(stream, from: &paintedFrom)
        let showsActions = (phase == .done && !stream.isRevealing && !markdown.isEmpty)
        actions.target = showsActions ? 1 : 0; actions.step(dt)
        render(at: now)
        return !(steps.allSatisfy { $0.presence.isResting(within: 0.002) } && !stream.needsFrames && actions.isResting(within: 0.002))
    }

    /// The status line, the steps as far as they've come in, then the answer, then the actions.
    private var stepsHeight: CGFloat {
        guard !steps.isEmpty else { return 0 }
        let rows = steps.reduce(CGFloat(0)) { $0+CGFloat(min(1, max(0, $1.presence.value)))*(AIChatStepRow.height+AIChatStepRow.gap) }
        return AIChatStyle.stepsGap-AIChatStepRow.gap+rows
    }
    private var textTop: CGFloat {
        let top = (hasThoughtRow ? 16 : 0)+stepsHeight
        return top > 0 ? top+AIChatStyle.answerGap : 0
    }
    func height(for width: CGFloat) -> CGFloat {
        let text = textView.usedSize(width: width)
        var height = textTop+text.height
        if phase == .done || phase == .failed, !markdown.isEmpty { height += AIChatStyle.actionsGap+24 }
        return height
    }
    override func layout() { super.layout(); render(at: CACurrentMediaTime()) }
    private func render(at now: Double) {
        let width = bounds.width
        status.frame = NSRect(x: 0, y: 0, width: width, height: 16)
        var y = (hasThoughtRow ? 16 : 0)+AIChatStyle.stepsGap
        for row in steps {
            let p = CGFloat(min(1, max(0, row.presence.value)))
            row.frame = NSRect(x: 0, y: round(y-(1-p)*6), width: width, height: AIChatStepRow.height)
            row.alphaValue = p
            y += p*(AIChatStepRow.height+AIChatStepRow.gap)
        }
        let top = textTop
        let text = textView.usedSize(width: width)
        textView.frame = NSRect(x: 0, y: top, width: width, height: text.height)
        let actionsY = top+text.height+AIChatStyle.actionsGap
        copyButton.frame = NSRect(x: -5, y: actionsY, width: 24, height: 24)
        regenerateButton.frame = NSRect(x: 21, y: actionsY, width: 24, height: 24)
        let alpha = CGFloat(min(1, max(0, actions.value)))
        copyButton.alphaValue = alpha; copyButton.isHidden = alpha < 0.01
        regenerateButton.alphaValue = alpha; regenerateButton.isHidden = alpha < 0.01 || !canRegenerate
    }
}
