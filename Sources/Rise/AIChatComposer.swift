import AppKit
import RiseCore

/// The question being written. TextKit 1, so its lines can be counted as it grows; it draws its
/// own placeholder in the same line box as the text, and says when it takes and gives up the keyboard.
@MainActor final class AIChatInputView: NSTextView {
    var onFocus: ((Bool) -> Void)?
    var placeholder = NSAttributedString() { didSet { needsDisplay = true } }
    init() {
        let storage = NSTextStorage(), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) { super.init(frame: frameRect, textContainer: container) }
    required init?(coder: NSCoder) { fatalError() }
    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?(true) }
        return took
    }
    override func resignFirstResponder() -> Bool {
        let gave = super.resignFirstResponder()
        if gave { onFocus?(false) }
        return gave
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, placeholder.length > 0 else { return }
        let origin = textContainerOrigin
        placeholder.draw(with: NSRect(x: origin.x, y: origin.y, width: bounds.width-origin.x, height: AIChatStyle.inputLineHeight),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
    /// Dia's caret: 2 pt wide and as tall as the text, centred on its line rather than filling
    /// the whole line box, on whole pixels so it stays crisp.
    private func caret(_ rect: NSRect) -> NSRect {
        let width = AIChatStyle.caretSize.width, height = min(rect.height, AIChatStyle.caretSize.height)
        return backingAlignedRect(NSRect(x: rect.minX+0.5-width/2, y: rect.midY-height/2, width: width, height: height),
                                  options: .alignAllEdgesNearest)
    }
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Turned off, AppKit redraws the text over where it was.
        guard flag else { super.drawInsertionPoint(in: rect, color: color, turnedOn: flag); return }
        let caret = caret(rect)
        color.setFill()
        NSBezierPath(roundedRect: caret, xRadius: caret.width/2, yRadius: caret.width/2).fill()
    }
    /// AppKit erases its own 1 pt caret; this one reaches past it.
    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(rect.insetBy(dx: -AIChatStyle.caretSize.width, dy: 0), avoidAdditionalLayout: flag)
    }
    /// Pasted or dropped in, text comes as plain words in the composer's own style.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func pasteAsRichText(_ sender: Any?) { pasteAsPlainText(sender) }
    /// No bold, italic or underline from the keyboard.
    override func changeFont(_ sender: Any?) {}
    override func underline(_ sender: Any?) {}
    /// Copied or dragged, a mention is its page's title.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage, !storage.mentions.isEmpty else { return super.writeSelection(to: pboard, types: types) }
        let text = selectedRanges.map { storage.attributedSubstring(from: $0.rangeValue).plainMentionText }.joined(separator: "\n")
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }
    /// Lines the text takes, at least one.
    var lineCount: Int {
        guard let manager = layoutManager, let container = textContainer else { return 1 }
        manager.ensureLayout(for: container)
        var lines = 0
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        if manager.extraLineFragmentTextContainer != nil { lines += 1 }
        return max(1, lines)
    }
}

/// The round button at the composer's right: an arrow to send, or a square to stop an answer.
@MainActor final class AIChatSendButton: FlippedView {
    enum Mode { case send, stop }
    var mode = Mode.send { didSet { if mode != oldValue { update() } } }
    /// Dark, as when its window is in front; pale otherwise, as Dia's is.
    var isActive = false { didSet { if isActive != oldValue { update() } } }
    var action: (() -> Void)?
    private let circle = CALayer()
    private let icon = NSImageView()
    private var colors = AIChatColors(.neutral)
    private var hovering = false, pressed = false
    /// Rise's hover hint, as the toolbar's buttons have.
    private(set) lazy var hoverHint = ButtonHoverHint(button: self, text: "Send", shortcut: "↩")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.addSublayer(circle)
        icon.imageScaling = .scaleNone; addSubview(icon)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyColors(_ colors: AIChatColors) {
        self.colors = colors; hoverHint.appearance = NSAppearance(named: colors.dark ? .darkAqua : .aqua); update()
    }
    private func update() {
        hoverHint.update(text: mode == .send ? "Send" : "Stop answering", shortcut: mode == .send ? "↩" : "⎋")
        let symbol = mode == .send ? "arrow.up" : "stop.fill"
        let size: CGFloat = mode == .send ? 14 : 10
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: mode == .send ? .semibold : .regular))
        let active = isActive || mode == .stop
        var fill = active ? colors.sendOn : colors.sendOff
        if hovering && active { fill = fill.blended(withFraction: 0.12, of: colors.dark ? .black : .white) ?? fill }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        circle.backgroundColor = fill.cgColor
        CATransaction.commit()
        icon.contentTintColor = active ? colors.sendOnIcon : colors.sendOffIcon
        setAccessibilityLabel(mode == .send ? "Send" : "Stop")
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        circle.bounds = bounds; circle.position = CGPoint(x: bounds.midX, y: bounds.midY); circle.cornerRadius = bounds.width/2
        CATransaction.commit()
        icon.frame = bounds
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; hoverHint.setHovered(true); update() }
    override func mouseExited(with event: NSEvent) { hovering = false; hoverHint.setHovered(false); update() }
    override func viewDidHide() { super.viewDidHide(); hoverHint.setHovered(false) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { hoverHint.setHovered(false) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { hoverHint.hide(); pressed = true; PressScale.set(circle, to: 0.92) }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; PressScale.set(circle, to: 1)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
}

/// The microphone: a tap starts dictating and another stops it; held, it dictates until it's let
/// go. Its glyph turns into the stop button and back as SF Symbols' replace does.
@MainActor final class AIChatMicButton: ChromeButton {
    /// Held this long, letting go stops it.
    static let holdDuration: TimeInterval = 0.35
    /// Whether letting go stops dictating: only after holding it to talk, not after a tap, nor
    /// after the press that stopped it.
    static func releaseStops(startedByPress: Bool, held: TimeInterval) -> Bool { startedByPress && held >= holdDuration }
    private final class Glyph: NSImageView { override func hitTest(_ point: NSPoint) -> NSView? { nil } }
    private let glyph = Glyph()
    var glyphImage: NSImage? { glyph.image }
    var onPress: (() -> Void)?
    /// Let go, after being held this long.
    var onRelease: ((TimeInterval) -> Void)?
    private var pressedAt: TimeInterval?
    override var contentTintColor: NSColor? { didSet { glyph.contentTintColor = contentTintColor } }
    init() {
        super.init(symbol: "mic", size: 15, title: "Dictate", action: {})
        image = nil
        glyph.imageScaling = .scaleNone; glyph.setAccessibilityElement(false)
        addSubview(glyph)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); glyph.frame = bounds }
    func setGlyph(_ image: NSImage?, animated: Bool) {
        guard glyph.image !== image else { return }
        SymbolReplacement.setImage(image, in: glyph, animated: animated && window != nil)
    }
    override func mouseDown(with event: NSEvent) {
        hoverHint?.hide()
        guard isEnabled else { return }
        pressedAt = event.timestamp
        onPress?()
    }
    override func mouseUp(with event: NSEvent) {
        guard let pressedAt else { return }
        self.pressedAt = nil
        onRelease?(event.timestamp-pressedAt)
    }

    /// Solar's stop (480 Design, CC BY 4.0): a ring and a rounded square, drawn 18 pt so its
    /// 1.5-in-24 strokes come to the microphone glyph's 1.125, with the square filled in red.
    static let stopSquare = "M8 12c0-1.886 0-2.828.586-3.414S10.114 8 12 8s2.828 0 3.414.586S16 10.114 16 12s0 2.828-.586 3.414S13.886 16 12 16s-2.828 0-3.414-.586S8 13.886 8 12Z"
    static let stopSize: CGFloat = 18
    static func stopImage(ring: NSColor, red: NSColor) -> NSImage {
        let size = stopSize, scale = size/24
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: scale, y: scale)
            context.setLineWidth(1.5); context.setLineCap(.round); context.setLineJoin(.round)
            context.setStrokeColor(ring.cgColor)
            context.strokeEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            let square = TablerIcon.path(stopSquare)
            context.setFillColor(red.cgColor); context.setStrokeColor(red.cgColor)
            context.addPath(square); context.fillPath()
            context.addPath(square); context.strokePath()
            return true
        }
        image.isTemplate = false; image.accessibilityDescription = "Stop Dictating"
        return image
    }
    static let micImage = AIChatComposer.symbol("mic", size: 15, weight: .regular)
}

/// Dia's composer: a white card at the panel's foot. Empty and away from the keyboard it's one
/// row, the buttons beside the placeholder; written in, it's the text over a row of buttons; and
/// with pages attached, their chips sit above the text. It springs between them, growing upward.
@MainActor final class AIChatComposer: FlippedView, NSTextViewDelegate {
    private let card = Surface(radius: AIChatStyle.composerRadius)
    private let content = FlippedView()
    let input = AIChatInputView()
    private let inputScroll = NSScrollView()
    private let chipsView = FlippedView()
    private(set) var chips: [AIChatPageChip] = []
    let plusButton = MenuButton(title: "Add Pages")
    let moreButton = MenuButton(title: "More")
    let micButton = AIChatMicButton()
    /// Dictation's dots, between ⋯ and the microphone, and why it couldn't listen, in their place.
    let waveform = AIChatWaveform()
    private let dictationNote = label("", size: 13)
    private var noteTimer: Timer?
    let dictation = AIChatDictation()
    let sendButton = AIChatSendButton()
    private var height = MotionSpring(AIChatStyle.compactHeight), expansion = MotionSpring(0), chipRow = MotionSpring(0)
    private var colors = AIChatColors(.neutral)
    private var keyObservers: [NSObjectProtocol] = []
    private(set) var isFocused = false

    var onSend: (([AIChatQuestionPart]) -> Void)?
    /// What's typed after an @ (nil once it isn't), and where the @ is, in the composer.
    var onMentionQuery: ((String?, NSRect) -> Void)?
    /// A key for the @ menu while it shows: true if it took it.
    var onMentionKey: ((MentionKey) -> Bool)?
    enum MentionKey { case up, down, pick, dismiss }
    /// The pages mentioned in the text, in order, as they change.
    var onMentionsChanged: (([AIChatAttachment]) -> Void)?
    /// Where the @ being typed is, while it is.
    private(set) var mentionStart: Int?
    private var reportedMentions: [AIChatAttachment] = []
    var onStop: (() -> Void)?
    var onRemove: ((AIChatAttachment) -> Void)?
    /// Its height or layout is moving; the panel follows.
    var onMotion: (() -> Void)?
    var onEscape: (() -> Void)?
    var attachments: [AIChatAttachment] { chips.map(\.attachment) }
    /// The text as it reads, each mention by its page's title.
    var text: String { input.textStorage?.plainMentionText ?? input.string }
    /// The pages mentioned, in the order they are.
    var mentions: [AIChatAttachment] { input.textStorage?.mentions.map(\.page) ?? [] }
    /// "Ask another question…" once there's a conversation.
    var hasConversation = false { didSet { if hasConversation != oldValue { updatePlaceholder() } } }
    var isAnswering = false { didSet { sendButton.mode = isAnswering ? .stop : .send } }
    var currentHeight: CGFloat { CGFloat(height.value) }
    var targetHeight: CGFloat { CGFloat(height.target) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // Dia's shadow: darkest just under the card, a faint halo above it. A corner radius turns
        // clipping back on, which would cut it off, as with the find bar's panel; `content` clips instead.
        clipsToBounds = false; card.clipsToBounds = false
        card.layer?.cornerCurve = .continuous; card.layer?.borderWidth = 0.5
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0.12
        card.layer?.shadowRadius = 3
        // The card's layer is flipped, so down is positive.
        card.layer?.shadowOffset = NSSize(width: 0, height: 1.5)
        content.wantsLayer = true; content.layer?.masksToBounds = true
        content.layer?.cornerRadius = AIChatStyle.composerRadius; content.layer?.cornerCurve = .continuous

        // Rich, so undo brings a deleted mention back as itself; what's pasted or dropped in is
        // still plain text (`AIChatInputView`).
        input.isRichText = true; input.importsGraphics = false; input.usesFontPanel = false; input.usesRuler = false
        input.allowsUndo = true; input.drawsBackground = false
        input.font = AIChatStyle.font(AIChatStyle.inputFontSize); input.textContainer?.lineFragmentPadding = 0
        // Room for the caret either side of the text, which starts where it would without it.
        input.textContainerInset = NSSize(width: AIChatStyle.caretSize.width, height: 0)
        input.textContainer?.widthTracksTextView = true
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.minSize = .zero; input.maxSize = NSSize(width: 10_000, height: 10_000)
        input.delegate = self; input.setAccessibilityLabel("Ask a question")
        input.isAutomaticQuoteSubstitutionEnabled = false; input.isAutomaticDashSubstitutionEnabled = false
        input.onFocus = { [weak self] focused in self?.isFocused = focused; self?.retarget() }
        inputScroll.drawsBackground = false; inputScroll.borderType = .noBorder
        inputScroll.hasVerticalScroller = false; inputScroll.scrollerStyle = .overlay; inputScroll.autohidesScrollers = true
        inputScroll.verticalScrollElasticity = .none; inputScroll.documentView = input

        plusButton.image = Self.symbol("plus", size: 15, weight: .regular); moreButton.image = Self.symbol("ellipsis", size: 15)
        micButton.setGlyph(AIChatMicButton.micImage, animated: false)
        // Pressed, it listens; let go after holding it, it stops. VoiceOver's press toggles.
        micButton.onPress = { [weak self] in self?.micPressed() }
        micButton.onRelease = { [weak self] held in self?.micReleased(held) }
        micButton.actionBlock = { [weak self] in self?.dictate() }
        // Rise's own hover hints, not the system's tooltips.
        plusButton.setHoverHint("Add pages", shortcut: "@"); moreButton.setHoverHint("More")
        sendButton.action = { [weak self] in self?.sendOrStop() }
        dictationNote.alphaValue = 0; dictationNote.lineBreakMode = .byTruncatingTail
        dictation.onPhase = { [weak self] phase in self?.dictationChanged(phase) }
        dictation.onLevel = { [weak self] level in self?.waveform.hear(level) }
        dictation.onWords = { [weak self] words in self?.insertDictated(words) }
        dictation.onFailure = { [weak self] reason in self?.showDictationNote(reason) }
        [chipsView, inputScroll, plusButton, moreButton, waveform, dictationNote, micButton, sendButton].forEach(content.addSubview)
        [card, content].forEach(addSubview)
        for spring in [\AIChatComposer.height, \.expansion, \.chipRow] { self[keyPath: spring].configure(response: FindMotion.swapResponse, bounce: 0) }
        updatePlaceholder(); retarget(); settle()
    }
    required init?(coder: NSCoder) { fatalError() }
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .light) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
    }

    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        card.fill = colors.composer; card.layer?.borderColor = colors.composerBorder.cgColor
        card.layer?.shadowOpacity = colors.dark ? 0.3 : 0.12
        input.textColor = colors.text; input.insertionPointColor = colors.text
        input.typingAttributes = inputAttributes(colors.text)
        input.defaultParagraphStyle = AIChatStyle.paragraph(lineHeight: AIChatStyle.inputLineHeight)
        input.selectedTextAttributes = [.backgroundColor: colors.dark ? NSColor(hex: 0x3A3A3A) : NSColor(hex: 0xDADADA)]
        if let storage = input.textStorage, storage.length > 0 {
            // Mentions keep their pills, in the new colours.
            let mentions = storage.mentions
            storage.setAttributes(inputAttributes(colors.text), range: NSRange(location: 0, length: storage.length))
            for (range, page) in mentions { storage.addAttribute(.attachment, value: AIChatMentionAttachment(page, style: .composer(colors)), range: range) }
        }
        [plusButton, moreButton, micButton].forEach {
            $0.contentTintColor = colors.toolbarIcon; $0.hoverColor = colors.hover
            $0.hoverHint?.appearance = NSAppearance(named: colors.dark ? .darkAqua : .aqua)
        }
        waveform.color = colors.dark ? NSColor(hex: 0x6A6A6A) : NSColor(hex: 0xC4C4C4)
        dictationNote.textColor = colors.muted
        updateMic()
        sendButton.applyColors(colors)
        chips.forEach { $0.applyColors(colors) }
        updatePlaceholder()
    }
    private func updatePlaceholder() {
        let text = !chips.isEmpty ? (chips.count == 1 ? "Ask a question about this page…" : "Ask a question about these pages…")
            : hasConversation ? "Ask another question…" : "Ask anything…"
        input.placeholder = NSAttributedString(string: text, attributes: inputAttributes(colors.placeholder))
    }
    private func inputAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        AIChatStyle.attributes(AIChatStyle.font(AIChatStyle.inputFontSize), color: color, lineHeight: AIChatStyle.inputLineHeight)
    }

    /// The pages the next question goes with.
    func setAttachments(_ attachments: [AIChatAttachment]) {
        guard attachments != self.attachments else { return }
        chips.forEach { $0.removeFromSuperview() }
        chips = attachments.map { attachment in
            let chip = AIChatPageChip(attachment, removable: true)
            chip.onRemove = { [weak self] in self?.onRemove?(attachment) }
            chip.applyColors(colors); chipsView.addSubview(chip)
            return chip
        }
        updatePlaceholder(); retarget(); needsLayout = true
    }
    func clear() {
        input.string = ""; input.undoManager?.removeAllActions(); input.needsDisplay = true
        endMention(); mentionsMayHaveChanged()
        retarget()
    }
    func focus() { window?.makeFirstResponder(input) }

    private func sendOrStop() {
        // Listening, it's the words that go in first.
        if dictation.phase == .listening { dictation.stop(); return }
        if isAnswering { onStop?(); return }
        let parts = input.textStorage?.questionParts ?? []
        guard !parts.isEmpty else { focus(); return }
        endMention()
        onSend?(parts)
    }
    /// The microphone: starts listening, or stops and works out what was said. Before macOS 26,
    /// the system's own dictation.
    private func dictate() {
        focus()
        guard AIChatDictation.isAvailable else { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: self); return }
        dictation.toggle()
    }
    /// Pressed, it starts listening, or stops if it was.
    private var heldToTalk = false
    private func micPressed() {
        focus()
        guard AIChatDictation.isAvailable else { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: self); return }
        heldToTalk = dictation.phase == .idle
        switch dictation.phase {
        case .idle: dictation.start()
        case .listening: dictation.stop()
        case .transcribing: break
        }
    }
    /// Held, it listened until let go; tapped, it listens on until tapped again.
    private func micReleased(_ held: TimeInterval) {
        defer { heldToTalk = false }
        if AIChatMicButton.releaseStops(startedByPress: heldToTalk, held: held), dictation.phase == .listening { dictation.stop() }
    }
    /// Stops listening, or working the words out, with nothing to show for it.
    func cancelDictation() { dictation.cancel() }
    private func dictationChanged(_ phase: AIChatDictation.Phase) {
        switch phase {
        case .listening: hideDictationNote(); waveform.start()
        case .transcribing: waveform.transcribe()
        case .idle: waveform.stop()
        }
        updateMic(); retarget(); needsLayout = true
    }
    /// The stop button while it listens, its square red; the microphone otherwise, dimmed while
    /// it works the words out.
    private var stopImage: (image: NSImage, colors: AIChatColors)?
    private func updateMic() {
        let listening = dictation.phase == .listening
        if listening {
            if stopImage?.colors != colors {
                let red = NSColor(hex: colors.dark ? 0xFF453A : 0xFF3B30)
                stopImage = (AIChatMicButton.stopImage(ring: colors.toolbarIcon, red: red), colors)
            }
            micButton.setGlyph(stopImage?.image, animated: true)
        } else { micButton.setGlyph(AIChatMicButton.micImage, animated: true) }
        micButton.isEnabled = dictation.phase != .transcribing
        micButton.alphaValue = dictation.phase == .transcribing ? 0.5 : 1
        micButton.setHoverHint(listening ? "Stop dictating" : "Dictate", shortcut: listening ? "↩" : "Hold to talk")
        micButton.hoverHint?.appearance = NSAppearance(named: colors.dark ? .darkAqua : .aqua)
    }
    /// What was said, where the cursor is, or over what's selected.
    func insertDictated(_ words: String) {
        focus()
        let range = input.selectedRange()
        let text = DictationInsertion.text(words, in: input.string, replacing: range)
        guard !text.isEmpty else { return }
        // Each dictation its own undo, apart from typing just before it.
        input.breakUndoCoalescing()
        input.insertText(text, replacementRange: range)
        input.breakUndoCoalescing()
    }
    private func showDictationNote(_ reason: String) {
        dictationNote.stringValue = reason; needsLayout = true
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; dictationNote.animator().alphaValue = 1 }
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideDictationNote() }
        }
    }
    private func hideDictationNote() {
        noteTimer?.invalidate(); noteTimer = nil
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; dictationNote.animator().alphaValue = 0 }
    }

    // MARK: Text

    func textDidChange(_ notification: Notification) {
        input.needsDisplay = true; retarget()
        updateMention(); mentionsMayHaveChanged()
    }
    func textViewDidChangeSelection(_ notification: Notification) { updateMention() }
    /// An @ typed at a word's start begins a mention.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        guard text == "@", !isApplyingMention else { return true }
        let string = input.string as NSString
        let before = range.location > 0 ? string.character(at: range.location-1) : nil
        if before.map({ Self.opensMention(Character(UnicodeScalar($0) ?? " ")) }) ?? true { pendingMention = range.location }
        return true
    }
    private var pendingMention: Int?, isApplyingMention = false
    /// After nothing, a space, a new line or an opening bracket or quote.
    static func opensMention(_ character: Character) -> Bool { character.isWhitespace || "([{\"'“‘".contains(character) }

    // MARK: Mentions

    /// What's typed after the @, from it to the cursor, while the cursor's there.
    private func updateMention() {
        if let pending = pendingMention { pendingMention = nil; mentionStart = pending }
        guard let start = mentionStart else { return }
        let string = input.string as NSString, selection = input.selectedRange()
        guard start < string.length, string.character(at: start) == 0x40, selection.length == 0,
              selection.location > start, selection.location-start <= 60 else { endMention(); return }
        let query = string.substring(with: NSRange(location: start+1, length: selection.location-start-1))
        guard !query.contains(where: \.isNewline) else { endMention(); return }
        onMentionQuery?(query, mentionAnchor(at: start))
    }
    /// The @ being typed, in the composer's coordinates.
    /// Where the @ being typed is now, in the composer, as the text grows and scrolls.
    var mentionAt: NSRect? { mentionStart.map(mentionAnchor(at:)) }
    private func mentionAnchor(at index: Int) -> NSRect {
        guard let manager = input.layoutManager, let container = input.textContainer else { return .zero }
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += input.textContainerOrigin.x; rect.origin.y += input.textContainerOrigin.y
        return convert(rect, from: input)
    }
    /// No longer typing a mention: the @ and what follows stay as they were typed.
    func endMention() {
        guard mentionStart != nil || pendingMention != nil else { return }
        mentionStart = nil; pendingMention = nil
        onMentionQuery?(nil, .zero)
    }
    /// The @ and what's typed after it become a mention of `page`, with a space after it.
    func completeMention(with page: AIChatAttachment) {
        guard let start = mentionStart, let storage = input.textStorage else { return }
        let end = max(start, min(input.selectedRange().location, storage.length))
        let range = NSRange(location: start, length: end-start)
        endMention()
        insertMention(page, replacing: range)
    }
    /// A mention of `page` over `range`, as one undo.
    func insertMention(_ page: AIChatAttachment, replacing range: NSRange) {
        guard let storage = input.textStorage else { return }
        let mention = AIChatQuestionPart.attributed([.mention(page)], attributes: inputAttributes(colors.text), style: .composer(colors))
        let token = NSMutableAttributedString(attributedString: mention)
        let next = NSMaxRange(range) < storage.length ? (storage.string as NSString).character(at: NSMaxRange(range)) : nil
        let spaced = next.map { Character(UnicodeScalar($0) ?? " ").isWhitespace } ?? false
        if !spaced { token.append(NSAttributedString(string: " ", attributes: inputAttributes(colors.text))) }
        isApplyingMention = true; defer { isApplyingMention = false }
        input.breakUndoCoalescing()
        guard input.shouldChangeText(in: range, replacementString: token.string) else { return }
        storage.replaceCharacters(in: range, with: token)
        input.didChangeText()
        input.breakUndoCoalescing()
        // Past the mention and its space.
        input.setSelectedRange(NSRange(location: range.location+token.length+(spaced ? 1 : 0), length: 0))
        input.typingAttributes = inputAttributes(colors.text)
        focus()
    }
    /// A page's mentions become its title, as words, once it's taken off.
    func unmention(_ page: AIChatAttachment) {
        guard let storage = input.textStorage else { return }
        let ranges = storage.mentions.filter { $0.page.isSamePage(as: page) || $0.page == page }.map(\.range)
        guard !ranges.isEmpty else { return }
        for range in ranges.reversed() where input.shouldChangeText(in: range, replacementString: AIChatQuestionPart.title(of: page)) {
            storage.replaceCharacters(in: range, with: NSAttributedString(string: AIChatQuestionPart.title(of: page), attributes: inputAttributes(colors.text)))
            input.didChangeText()
        }
    }
    private func mentionsMayHaveChanged() {
        let mentions = self.mentions
        guard mentions != reportedMentions else { return }
        reportedMentions = mentions
        onMentionsChanged?(mentions)
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if mentionStart != nil, let key = Self.mentionKey(for: selector), onMentionKey?(key) == true {
            if key == .dismiss { endMention() }
            return true
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Return starts a new line, as Option-Return does.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            sendOrStop(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            if dictation.phase != .idle { dictation.cancel(); return true }
            onEscape?(); return true
        default: return false
        }
    }

    // MARK: Layout and motion

    /// One row while there's nothing to show but the placeholder.
    var isCompact: Bool { chips.isEmpty && input.string.isEmpty && !isFocused && dictation.phase == .idle }
    private var visibleLines: Int { min(AIChatStyle.maximumInputLines, input.lineCount) }
    private func retarget() {
        let chipsHeight: CGFloat = chips.isEmpty ? 0 : AIChatStyle.composerChipRow
        chipRow.target = Double(chipsHeight)
        expansion.target = isCompact ? 0 : 1
        height.target = Double(isCompact ? AIChatStyle.compactHeight
            : chipsHeight+AIChatStyle.expandedHeight+CGFloat(visibleLines-1)*AIChatStyle.inputLineHeight)
        sendButton.isActive = window?.isKeyWindow ?? false
        let scrolls = input.lineCount > AIChatStyle.maximumInputLines
        if inputScroll.hasVerticalScroller != scrolls { inputScroll.hasVerticalScroller = scrolls }
        onMotion?()
    }
    func step(_ dt: Double) { height.step(dt); expansion.step(dt); chipRow.step(dt); needsLayout = true }
    var isResting: Bool { height.isResting(within: 0.05) && expansion.isResting(within: 0.002) && chipRow.isResting(within: 0.05) }
    func settle() { for spring in [\AIChatComposer.height, \.expansion, \.chipRow] { self[keyPath: spring].value = self[keyPath: spring].target; self[keyPath: spring].velocity = 0 }; needsLayout = true }
    /// Where the text is, in the composer's coordinates: a sent question lifts off from here.
    var textFrame: NSRect { convert(inputScroll.frame, from: content) }
    /// Where the attached pages' chips are, in the composer's coordinates.
    var chipFrames: [NSRect] { chips.map { convert($0.frame, from: chipsView) } }

    override func layout() {
        super.layout()
        let width = bounds.width, open = CGFloat(min(1, max(0, expansion.value)))
        let path = PageOutline.path(in: bounds, radius: AIChatStyle.composerRadius, continuous: true)
        card.frame = bounds; card.layer?.shadowPath = path
        content.frame = bounds
        let chipsTop = AIChatStyle.composerInset*2
        // Room above and to the right for each chip's remove button, which reaches past its corner.
        let overhang = AIChatPageChip.removeOverhang, room = width-2*AIChatStyle.composerChipInset
        chipsView.frame = NSRect(x: AIChatStyle.composerChipInset, y: chipsTop-overhang, width: room+overhang, height: AIChatStyle.chipSize.height+overhang)
        chipsView.alphaValue = CGFloat(min(1, max(0, chipRow.value/Double(AIChatStyle.composerChipRow))))
        var x: CGFloat = 0
        let chipWidth = chips.isEmpty ? 0 : min(AIChatStyle.chipSize.width, (room-CGFloat(chips.count-1)*8)/CGFloat(chips.count))
        for chip in chips { chip.frame = NSRect(x: x, y: overhang, width: chipWidth, height: AIChatStyle.chipSize.height); x += chipWidth+8 }

        // The buttons' row is always 30 pt up from the bottom; + and ⋯ move from beside the microphone to the left.
        let mid = bounds.height-AIChatStyle.rowMid
        func place(_ view: NSView, _ center: CGFloat, size: CGFloat = 28) {
            view.frame = NSRect(x: round(center-size/2), y: round(mid-size/2), width: size, height: size)
        }
        place(plusButton, width-144+(30-(width-144))*open)
        place(moreButton, width-108+(66-(width-108))*open)
        place(micButton, width-71.5)
        place(sendButton, width-30, size: AIChatStyle.sendSize)
        // Dictation's dots fill the row between ⋯ and the microphone.
        let between = NSRect(x: moreButton.frame.maxX+6, y: round(mid-14), width: max(0, micButton.frame.minX-6-moreButton.frame.maxX-6), height: 28)
        waveform.frame = between
        let note = ceil(dictationNote.intrinsicContentSize.height)
        dictationNote.frame = NSRect(x: between.minX+4, y: round(mid-note/2), width: max(0, between.width-8), height: note)

        let lines = CGFloat(isCompact ? 1 : visibleLines)
        let top = CGFloat(chipRow.value)+AIChatStyle.rowMid-AIChatStyle.inputLineHeight/2
        let compactWidth = width-144-14-AIChatStyle.composerTextLeading-8
        let fieldWidth = compactWidth+(width-2*AIChatStyle.composerTextLeading-compactWidth)*open
        let caretRoom = AIChatStyle.caretSize.width
        inputScroll.frame = NSRect(x: AIChatStyle.composerTextLeading-caretRoom, y: top, width: max(40, fieldWidth)+2*caretRoom, height: lines*AIChatStyle.inputLineHeight)
        if input.frame.width != inputScroll.contentSize.width { input.frame.size.width = inputScroll.contentSize.width }
        input.textContainer?.containerSize = NSSize(width: max(0, inputScroll.contentSize.width-2*caretRoom), height: .greatestFiniteMagnitude)
        input.sizeToFit()
    }

    static func mentionKey(for selector: Selector) -> MentionKey? {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): .up
        case #selector(NSResponder.moveDown(_:)): .down
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)): .pick
        case #selector(NSResponder.cancelOperation(_:)): .dismiss
        default: nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver); keyObservers = []
        guard let window else { dictation.cancel(); return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sendButton.isActive = self?.window?.isKeyWindow ?? false }
            })
        }
        sendButton.isActive = window.isKeyWindow
    }
    /// A click anywhere on the card puts the cursor in the text.
    override func mouseDown(with event: NSEvent) { focus() }
    override func resetCursorRects() { addCursorRect(inputScroll.frame, cursor: .iBeam) }
}
