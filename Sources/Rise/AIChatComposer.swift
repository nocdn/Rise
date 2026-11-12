import AppKit

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
        placeholder.draw(with: NSRect(x: origin.x, y: origin.y, width: bounds.width-origin.x, height: AIChatStyle.lineHeight),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
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
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.addSublayer(circle)
        icon.imageScaling = .scaleNone; addSubview(icon)
        setAccessibilityElement(true); setAccessibilityRole(.button)
        update()
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyColors(_ colors: AIChatColors) { self.colors = colors; update() }
    private func update() {
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
    override func mouseEntered(with event: NSEvent) { hovering = true; update() }
    override func mouseExited(with event: NSEvent) { hovering = false; update() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) { pressed = true; PressScale.set(circle, to: 0.92) }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false; PressScale.set(circle, to: 1)
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
    override func accessibilityPerformPress() -> Bool { action?(); return true }
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
    let cameraButton = ChromeButton(symbol: "camera", size: 15, title: "Attach a Screenshot of the Page", action: {})
    let micButton = ChromeButton(symbol: "mic", size: 15, title: "Dictate", action: {})
    let sendButton = AIChatSendButton()
    private var height = MotionSpring(AIChatStyle.compactHeight), expansion = MotionSpring(0), chipRow = MotionSpring(0)
    private var colors = AIChatColors(.neutral)
    private var keyObservers: [NSObjectProtocol] = []
    private(set) var isFocused = false

    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onRemove: ((AIChatAttachment) -> Void)?
    /// Its height or layout is moving; the panel follows.
    var onMotion: (() -> Void)?
    var onEscape: (() -> Void)?
    var attachments: [AIChatAttachment] { chips.map(\.attachment) }
    var text: String { input.string }
    /// "Ask another question…" once there's a conversation.
    var hasConversation = false { didSet { if hasConversation != oldValue { updatePlaceholder() } } }
    var isAnswering = false { didSet { sendButton.mode = isAnswering ? .stop : .send } }
    var currentHeight: CGFloat { CGFloat(height.value) }
    var targetHeight: CGFloat { CGFloat(height.target) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        card.layer?.cornerCurve = .continuous; card.layer?.borderWidth = 0.5
        card.layer?.shadowColor = NSColor.black.cgColor; card.layer?.shadowOpacity = 0.06
        card.layer?.shadowRadius = 6; card.layer?.shadowOffset = NSSize(width: 0, height: -2)
        content.wantsLayer = true; content.layer?.masksToBounds = true
        content.layer?.cornerRadius = AIChatStyle.composerRadius; content.layer?.cornerCurve = .continuous

        input.isRichText = false; input.allowsUndo = true; input.drawsBackground = false
        input.font = AIChatStyle.font(); input.textContainerInset = .zero; input.textContainer?.lineFragmentPadding = 0
        input.textContainer?.widthTracksTextView = true
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.minSize = .zero; input.maxSize = NSSize(width: 10_000, height: 10_000)
        input.delegate = self; input.setAccessibilityLabel("Ask a question")
        input.isAutomaticQuoteSubstitutionEnabled = false; input.isAutomaticDashSubstitutionEnabled = false
        input.onFocus = { [weak self] focused in self?.isFocused = focused; self?.retarget() }
        inputScroll.drawsBackground = false; inputScroll.borderType = .noBorder
        inputScroll.hasVerticalScroller = false; inputScroll.scrollerStyle = .overlay; inputScroll.autohidesScrollers = true
        inputScroll.verticalScrollElasticity = .none; inputScroll.documentView = input

        plusButton.image = Self.symbol("plus", size: 15); moreButton.image = Self.symbol("ellipsis", size: 15)
        cameraButton.image = Self.symbol("camera", size: 15); micButton.image = Self.symbol("mic", size: 15)
        micButton.actionBlock = { [weak self] in self?.dictate() }
        sendButton.action = { [weak self] in self?.sendOrStop() }
        [chipsView, inputScroll, plusButton, moreButton, cameraButton, micButton, sendButton].forEach(content.addSubview)
        [card, content].forEach(addSubview)
        for spring in [\AIChatComposer.height, \.expansion, \.chipRow] { self[keyPath: spring].configure(response: FindMotion.swapResponse, bounce: 0) }
        updatePlaceholder(); retarget(); settle()
    }
    required init?(coder: NSCoder) { fatalError() }
    static func symbol(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .light))
    }

    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        card.fill = colors.composer; card.layer?.borderColor = colors.composerBorder.cgColor
        card.layer?.shadowOpacity = colors.dark ? 0.3 : 0.06
        input.textColor = colors.text; input.insertionPointColor = colors.text
        input.typingAttributes = AIChatStyle.attributes(color: colors.text)
        input.selectedTextAttributes = [.backgroundColor: colors.dark ? NSColor(hex: 0x3A3A3A) : NSColor(hex: 0xDADADA)]
        if let storage = input.textStorage, storage.length > 0 {
            storage.setAttributes(AIChatStyle.attributes(color: colors.text), range: NSRange(location: 0, length: storage.length))
        }
        [plusButton, moreButton, cameraButton, micButton].forEach { $0.contentTintColor = colors.toolbarIcon; $0.hoverColor = colors.hover }
        sendButton.applyColors(colors)
        chips.forEach { $0.applyColors(colors) }
        updatePlaceholder()
    }
    private func updatePlaceholder() {
        let text = !chips.isEmpty ? (chips.count == 1 ? "Ask a question about this page…" : "Ask a question about these pages…")
            : hasConversation ? "Ask another question…" : "Ask anything…"
        input.placeholder = NSAttributedString(string: text, attributes: AIChatStyle.attributes(color: colors.placeholder))
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
        retarget()
    }
    func focus() { window?.makeFirstResponder(input) }

    private func sendOrStop() {
        if isAnswering { onStop?(); return }
        let question = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { focus(); return }
        onSend?(question)
    }
    private func dictate() {
        focus()
        NSApp.sendAction(Selector(("startDictation:")), to: nil, from: self)
    }

    // MARK: Text

    func textDidChange(_ notification: Notification) { input.needsDisplay = true; retarget() }
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Shift-Return starts a new line, as Option-Return does.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            sendOrStop(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?(); return true
        default: return false
        }
    }

    // MARK: Layout and motion

    /// One row while there's nothing to show but the placeholder.
    var isCompact: Bool { chips.isEmpty && input.string.isEmpty && !isFocused }
    private var visibleLines: Int { min(AIChatStyle.maximumInputLines, input.lineCount) }
    private func retarget() {
        let chipsHeight: CGFloat = chips.isEmpty ? 0 : AIChatStyle.composerChipRow
        chipRow.target = Double(chipsHeight)
        expansion.target = isCompact ? 0 : 1
        height.target = Double(isCompact ? AIChatStyle.compactHeight
            : chipsHeight+AIChatStyle.expandedHeight+CGFloat(visibleLines-1)*AIChatStyle.lineHeight)
        sendButton.isActive = window?.isKeyWindow ?? false
        let scrolls = input.lineCount > AIChatStyle.maximumInputLines
        if inputScroll.hasVerticalScroller != scrolls { inputScroll.hasVerticalScroller = scrolls }
        onMotion?()
    }
    func step(_ dt: Double) { height.step(dt); expansion.step(dt); chipRow.step(dt); needsLayout = true }
    var isResting: Bool { height.isResting(within: 0.05) && expansion.isResting(within: 0.002) && chipRow.isResting(within: 0.05) }
    func settle() { for spring in [\AIChatComposer.height, \.expansion, \.chipRow] { self[keyPath: spring].value = self[keyPath: spring].target; self[keyPath: spring].velocity = 0 }; needsLayout = true }
    /// Where the text starts, in the panel's coordinates: a sent question lifts off from here.
    var textFrame: NSRect { convert(inputScroll.frame, from: content) }

    override func layout() {
        super.layout()
        let width = bounds.width, open = CGFloat(min(1, max(0, expansion.value)))
        let path = PageOutline.path(in: bounds, radius: AIChatStyle.composerRadius, continuous: true)
        card.frame = bounds; card.layer?.shadowPath = path
        content.frame = bounds
        let chipsTop = AIChatStyle.composerInset*2
        chipsView.frame = NSRect(x: 16, y: chipsTop, width: width-32, height: AIChatStyle.chipSize.height)
        chipsView.alphaValue = CGFloat(min(1, max(0, chipRow.value/Double(AIChatStyle.composerChipRow))))
        var x: CGFloat = 0
        let chipWidth = chips.isEmpty ? 0 : min(AIChatStyle.chipSize.width, (chipsView.bounds.width-CGFloat(chips.count-1)*8)/CGFloat(chips.count))
        for chip in chips { chip.frame = NSRect(x: x, y: 0, width: chipWidth, height: AIChatStyle.chipSize.height); x += chipWidth+8 }

        // The buttons' row is always 30 pt up from the bottom; + and ⋯ move from beside the camera to the left.
        let mid = bounds.height-AIChatStyle.rowMid
        func place(_ view: NSView, _ center: CGFloat, size: CGFloat = 28) {
            view.frame = NSRect(x: round(center-size/2), y: round(mid-size/2), width: size, height: size)
        }
        place(plusButton, width-177+(30-(width-177))*open)
        place(moreButton, width-141+(66-(width-141))*open)
        place(cameraButton, width-106); place(micButton, width-70)
        place(sendButton, width-30, size: AIChatStyle.sendSize)

        let lines = CGFloat(isCompact ? 1 : visibleLines)
        let top = CGFloat(chipRow.value)+AIChatStyle.rowMid-AIChatStyle.lineHeight/2
        let compactWidth = width-177-14-AIChatStyle.composerTextLeading-8
        let fieldWidth = compactWidth+(width-2*AIChatStyle.composerTextLeading-compactWidth)*open
        inputScroll.frame = NSRect(x: AIChatStyle.composerTextLeading, y: top, width: max(40, fieldWidth), height: lines*AIChatStyle.lineHeight)
        if input.frame.width != inputScroll.contentSize.width { input.frame.size.width = inputScroll.contentSize.width }
        input.textContainer?.containerSize = NSSize(width: inputScroll.contentSize.width, height: .greatestFiniteMagnitude)
        input.sizeToFit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver); keyObservers = []
        guard let window else { return }
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
