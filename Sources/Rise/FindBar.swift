import AppKit
import WebKit

/// The find bar's motion. Swaps are translated from the Motion (framer-motion) spec they
/// were designed in:
///
///     <AnimatePresence initial={false} mode="popLayout">
///       <motion.div key={state} initial={{ opacity: 0, y: -15 }} animate={{ opacity: 1, y: 0 }}
///         exit={{ opacity: 0, y: 15 }} transition={{ type: "spring", bounce: 0, duration: 0.2 }} />
///
/// The bar itself slides in and out on the download archive tray's springs.
enum FindMotion {
    /// `{ type: "spring", bounce: 0, duration: 0.2 }`. Motion turns a duration into the
    /// stiffness whose critically damped envelope (1+ωt)·e^(-ωt) has fallen to 0.001 by
    /// then (its `findSpring`: Newton's method from 5/duration, 12 steps). ``MotionSpring``
    /// takes the same spring as the response 2π/ω with no bounce.
    static let swapResponse: Double = {
        let duration = 0.2
        var omega = 5/duration
        for _ in 0..<12 {
            let decay = exp(-omega*duration)
            omega -= (decay*(omega*duration+1) - 0.001)/(-omega*duration*duration*decay)
        }
        return 2 * .pi/omega
    }()
    /// Leaving is a little quicker than the tray's own exit.
    static let outResponse = 0.2
    /// How long "Done" shows before swapping to the close X.
    static let doneHold = 0.4
    /// `initial={{ y: -15 }}` and `exit={{ y: 15 }}`: content enters from above and leaves downward.
    static let swapTravel = 15.0
}

extension MotionSpring {
    mutating func settle() { value = target; velocity = 0 }
}

/// One keyed child of a `popLayout` presence: it enters from above and leaves downward,
/// fading on the same spring. Coming back while still leaving springs from where it is,
/// as Motion does when a key returns mid-exit.
struct PresenceItem {
    let view: NSView
    private(set) var shown: Bool
    private var offset = MotionSpring(0), opacity = MotionSpring(0)
    init(_ view: NSView, shown: Bool) {
        self.view = view; self.shown = shown
        offset.configure(response: FindMotion.swapResponse, bounce: 0)
        opacity.configure(response: FindMotion.swapResponse, bounce: 0)
        opacity.value = shown ? 1 : 0; opacity.target = opacity.value
    }
    mutating func set(_ show: Bool) {
        guard show != shown else { return }
        shown = show
        if show && opacity.value < 0.001 { offset.value = -FindMotion.swapTravel; offset.velocity = 0 }
        offset.target = show ? 0 : FindMotion.swapTravel; opacity.target = show ? 1 : 0
    }
    mutating func step(_ dt: Double) { offset.step(dt); opacity.step(dt) }
    mutating func settle() {
        offset.settle(); opacity.settle()
        if !shown { offset.value = 0; offset.target = 0 }
    }
    var isResting: Bool { offset.isResting(within: 0.05) && opacity.isResting(within: 0.002) }
    /// Places the view at `base` (in its flipped superview), displaced by the swap.
    func render(at base: NSRect) {
        view.frame = base.offsetBy(dx: 0, dy: offset.value)
        view.alphaValue = min(1, max(0, opacity.value))
        // A leaving control stays visible until it fades out, but never takes clicks.
        view.isHidden = !shown && opacity.value < 0.01
    }
}

/// Ask mode's action at the right edge. Captions, including the close X, use the
/// same keyed spring swap as the placeholders.
@MainActor final class SendBadge: FlippedView {
    enum Caption: CaseIterable { case send, thinking, done, close }
    static let iconSize: CGFloat = 12, iconGap: CGFloat = 4
    private let sendView = FlippedView()
    private let returnIcon = NSImageView(image: TablerIcon.image(TablerIcon.enterKey, size: SendBadge.iconSize))
    private let send = label("Send", size: 13)
    private let thinking = label("Thinking", size: 13)
    private let done = label("Done", size: 13)
    let closeButton = ChromeButton(symbol: "xmark", size: 11, title: "Close Find", action: {})
    private var items: [PresenceItem]
    private var widthSpring = MotionSpring(0), insetSpring = MotionSpring(14)
    private var theme = RiseTheme.neutral
    private var hovering = false
    var action: (() -> Void)?
    var width: CGFloat { widthSpring.value }
    var rightInset: CGFloat { insetSpring.value }
    var caption = Caption.send {
        didSet {
            guard caption != oldValue else { return }
            for (index, kind) in Caption.allCases.enumerated() { items[index].set(kind == caption) }
            widthSpring.target = width(of: caption)
            insetSpring.target = caption == .close ? 8 : 14
            closeButton.isEnabled = caption == .close
            setAccessibilityElement(caption != .close)
            window?.invalidateCursorRects(for: self)
            updateColors()
            setAccessibilityLabel(caption == .close ? "Close Find" : caption == .thinking ? "Thinking" : caption == .done ? "Done" : "Send")
            setAccessibilityEnabled(caption == .send || caption == .close)
        }
    }
    var isThinking: Bool { caption == .thinking }
    init() {
        items = [PresenceItem(sendView, shown: true), PresenceItem(thinking, shown: false), PresenceItem(done, shown: false), PresenceItem(closeButton, shown: false)]
        super.init(frame: .zero)
        returnIcon.imageScaling = .scaleNone
        closeButton.actionBlock = { [weak self] in self?.action?() }
        // Leave fractional-width slack on the left of the right-aligned captions.
        [send, thinking, done].forEach { $0.lineBreakMode = .byClipping; $0.alignment = .right }
        [returnIcon, send].forEach(sendView.addSubview)
        [sendView, thinking, done, closeButton].forEach(addSubview)
        widthSpring.configure(response: FindMotion.swapResponse, bounce: 0)
        insetSpring.configure(response: FindMotion.swapResponse, bounce: 0)
        widthSpring.value = width(of: .send); widthSpring.target = widthSpring.value
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Send")
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    private static func labelSize(_ label: NSTextField) -> NSSize {
        let size = label.intrinsicContentSize
        return NSSize(width: ceil(size.width)+4, height: size.height)
    }
    private func size(of caption: Caption) -> NSSize {
        switch caption {
        case .send: let text = Self.labelSize(send); return NSSize(width: Self.iconSize+Self.iconGap+text.width, height: text.height)
        case .thinking: return Self.labelSize(thinking)
        case .done: return Self.labelSize(done)
        case .close: return NSSize(width: 26, height: 28)
        }
    }
    private func width(of caption: Caption) -> CGFloat { size(of: caption).width-(caption == .close ? 0 : 4) }
    func applyTheme(_ theme: RiseTheme) { self.theme = theme; updateColors() }
    private func updateColors() {
        // Assign directly: hovering changes the text color immediately, without a transition.
        let color = hovering && caption == .send ? theme.muted.blended(withFraction: 0.22, of: .white) ?? theme.muted : theme.muted
        send.textColor = color; returnIcon.contentTintColor = color
        [thinking, done].forEach { $0.textColor = theme.muted }
        closeButton.contentTintColor = theme.muted
        closeButton.hoverColor = theme.text.withAlphaComponent(0.07)
    }
    func step(_ dt: Double) {
        for index in items.indices { items[index].step(dt) }
        widthSpring.step(dt); insetSpring.step(dt)
    }
    func settle() { for index in items.indices { items[index].settle() }; widthSpring.settle(); insetSpring.settle() }
    var isResting: Bool { items.allSatisfy(\.isResting) && widthSpring.isResting(within: 0.05) && insetSpring.isResting(within: 0.05) }
    func renderContents() {
        for (index, kind) in Caption.allCases.enumerated() {
            let size = size(of: kind)
            items[index].render(at: NSRect(x: bounds.width+(kind == .close ? 0 : 4)-size.width, y: (bounds.height-size.height)/2, width: size.width, height: size.height))
        }
        // Tracking enter/exit events can refer to its old frame while this button slides in.
        // Reconcile against the current pointer even when no mouse movement occurs.
        closeButton.refreshHoverState()
        let text = Self.labelSize(send)
        send.frame = NSRect(x: sendView.bounds.width-text.width, y: 0, width: text.width, height: text.height)
        returnIcon.frame = NSRect(x: 0, y: (text.height-Self.iconSize)/2, width: Self.iconSize, height: Self.iconSize)
    }
    override func layout() { super.layout(); renderContents() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; updateColors() }
    override func mouseExited(with event: NSEvent) { hovering = false; updateColors() }
    override func resetCursorRects() {
        if caption == .send || caption == .close { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0.01, frame.contains(point) else { return nil }
        return caption == .close ? super.hitTest(point) : self
    }
    override func mouseDown(with event: NSEvent) { if caption == .send || caption == .close { action?() } }
    override func accessibilityPerformPress() -> Bool {
        guard caption == .send || caption == .close else { return false }
        action?(); return true
    }
}

/// The find bar's input, with its own field editor so its selection can be a quiet gray, as
/// on jakub.kr, without restyling the window's shared field editor for every other field.
final class FindInput: NSTextField {
    override class var cellClass: AnyClass? { get { FindInputCell.self } set {} }
    var selectionColor = NSColor.selectedTextBackgroundColor {
        didSet { (cell as? FindInputCell)?.editor.selectedTextAttributes = [.backgroundColor: selectionColor] }
    }
}
final class FindInputCell: NSTextFieldCell {
    // TextKit 1 from the start: the shimmer reads the editor's layout manager.
    let editor: NSTextView = {
        let editor = NSTextView(usingTextLayoutManager: false)
        editor.isFieldEditor = true; editor.allowsUndo = true
        return editor
    }()
    override func fieldEditor(for controlView: NSView) -> NSTextView? { editor }
}

/// Find on page, which Tab turns into a question for a model about the page. Covers the
/// page and clips to it, so the panel slides in from the page's top-right edge; only the
/// panel takes clicks.
@MainActor final class FindBar: FlippedView, NSTextFieldDelegate {
    enum Mode { case find, ask }
    struct Turn { let question: String, answer: String }
    /// The panel sits as far from the page's side as from its top.
    static let width: CGFloat = 360, margin: CGFloat = 8, top: CGFloat = 8, bottom: CGFloat = 8
    static let rowHeight: CGFloat = 40, radius: CGFloat = 12
    static let answerInset = NSSize(width: 14, height: 10)
    /// The "Answered by" row under an answer, which takes the place of its bottom inset.
    static let footerHeight: CGFloat = 34, footerMid: CGFloat = 18
    static var modelName: String { PageAssistant.model.split(separator: "/").last.map(String.init) ?? PageAssistant.model }

    let panel = Surface(radius: radius)
    private let content = FlippedView(), row = FlippedView()
    let input = FindInput()
    private let placeholders = FlippedView()
    private let findPlaceholder = label("Find on page", size: 13)
    private let askPlaceholder = label("Ask a model about the page", size: 13)
    let previous: ChromeButton
    let next: ChromeButton
    let close: ChromeButton
    private let findControls = FlippedView()
    let count = label("", size: 12)
    let badge = SendBadge()
    let shimmer = InputShimmer()
    private let separator = Surface()
    private let answerScroll = NSScrollView()
    // TextKit 1 from the start: the streaming effect paints with the layout manager.
    private let answerView = NSTextView(usingTextLayoutManager: false)
    private let footer = FlippedView()
    private let footerIcon = NSImageView(image: TablerIcon.image(TablerIcon.searchWindow, size: 13))
    private let footerLabel = label("Answered by \(FindBar.modelName)", size: 11)
    let moreButton: ChromeButton
    /// Where Copy puts the answer.
    var pasteboard = NSPasteboard.general
    private var findText: PresenceItem, askText: PresenceItem, controls: PresenceItem, badgeItem: PresenceItem
    private var slide = MotionSpring(0), height = MotionSpring(FindBar.rowHeight)
    private var inputColor = MotionSpring(1)
    private var inputColorStart: NSColor?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var theme = RiseTheme.neutral

    private(set) var mode = Mode.find
    private(set) var isPresented = false
    private(set) var hasSubmittedQuestion = false
    /// Space at the top of the page taken by the developer header.
    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { needsLayout = true } } }
    /// Searches the page, steps through its matches, or clears them for an empty query.
    var find: ((String, PageFind.Direction) async -> PageFind.Matches)?
    private var findGeneration = 0
    var dismiss: (() -> Void)?
    /// Streams an answer to a question about the page, given the conversation so far.
    var answer: ((String, [Turn]) -> AsyncThrowingStream<String, Error>)?
    private(set) var conversation: [Turn] = []
    private var answerText = "", answerFailed = false
    /// The streamed answer, shown a word at a time; `answerText` is the part laid out so far.
    private var stream = TokenStream()
    /// Where the streaming effect's colors start in the answer.
    private var paintedFrom = 0
    /// The last question asked, for Regenerate.
    private var lastQuestion: (question: String, asked: String)?
    /// The last search's matches, so Enter on none can offer to ask instead.
    private var lastMatches: PageFind.Matches?
    private var answerTask: Task<Void, Never>?
    var isAnswering: Bool { answerTask != nil }
    /// The answered question shows Close; editing it restores Send.
    private var answeredText: String?
    /// Holds "Done" for a moment before swapping to the close button.
    private var doneTask: Task<Void, Never>?

    init() {
        previous = ChromeButton(symbol: "chevron.up", size: 11, title: "Previous match (⇧⌘G)", action: {})
        next = ChromeButton(symbol: "chevron.down", size: 11, title: "Next match (⌘G)", action: {})
        close = ChromeButton(symbol: "xmark", size: 11, title: "Close Find", action: {})
        moreButton = ChromeButton(symbol: "ellipsis", size: 10, title: "More", action: {})
        findText = PresenceItem(findPlaceholder, shown: true); askText = PresenceItem(askPlaceholder, shown: false)
        controls = PresenceItem(findControls, shown: true); badgeItem = PresenceItem(badge, shown: false)
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        layer?.cornerRadius = PageAppearance.radius; layer?.cornerCurve = .continuous
        isHidden = true

        panel.layer?.cornerCurve = .continuous; panel.layer?.borderWidth = 0.5
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = 0.16
        panel.layer?.shadowRadius = 8; panel.layer?.shadowOffset = NSSize(width: 0, height: -2)
        // The panel keeps its shadow, so an inner view does the clipping.
        content.wantsLayer = true; content.layer?.masksToBounds = true
        content.layer?.cornerRadius = Self.radius; content.layer?.cornerCurve = .continuous
        // Swapped content travels 15 pt; keep it inside the input row, not over the answer.
        row.wantsLayer = true; row.layer?.masksToBounds = true

        input.isBordered = false; input.isBezeled = false; input.drawsBackground = false
        input.focusRingType = .none; input.font = .systemFont(ofSize: 13)
        input.cell?.isScrollable = true; input.cell?.wraps = false; input.cell?.usesSingleLineMode = true
        input.delegate = self; input.setAccessibilityLabel("Find on page")
        // The placeholders are drawn separately so they can swap like the rest of the row.
        [findPlaceholder, askPlaceholder].forEach(placeholders.addSubview)

        previous.actionBlock = { [weak self] in self?.run(.previous) }
        next.actionBlock = { [weak self] in self?.run(.next) }
        close.actionBlock = { [weak self] in self?.dismiss?() }
        count.alignment = .right; count.lineBreakMode = .byClipping
        [count, previous, next, close].forEach(findControls.addSubview)
        badge.action = { [weak self] in
            guard let self else { return }
            if self.badge.caption == .close { self.dismiss?() } else { self.send() }
        }

        answerScroll.drawsBackground = false; answerScroll.borderType = .noBorder
        answerScroll.hasVerticalScroller = true; answerScroll.autohidesScrollers = true; answerScroll.scrollerStyle = .overlay
        answerView.isEditable = false; answerView.isSelectable = true; answerView.drawsBackground = false
        answerView.isRichText = true; answerView.textContainerInset = Self.answerInset
        answerView.textContainer?.lineFragmentPadding = 0; answerView.textContainer?.widthTracksTextView = false
        answerView.textContainer?.containerSize = NSSize(width: Self.width-2*Self.answerInset.width, height: .greatestFiniteMagnitude)
        answerView.isVerticallyResizable = true; answerView.isHorizontallyResizable = false
        answerView.minSize = .zero; answerView.maxSize = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        answerView.frame = NSRect(x: 0, y: 0, width: Self.width, height: 0)
        answerScroll.documentView = answerView
        footerIcon.imageScaling = .scaleNone
        moreButton.actionBlock = { [weak self] in self?.showMoreMenu() }
        [footerIcon, footerLabel, moreButton].forEach(footer.addSubview)

        shimmer.field = input
        [placeholders, input, shimmer, findControls, badge].forEach(row.addSubview)
        [row, separator, answerScroll, footer].forEach(content.addSubview)
        panel.addSubview(content); addSubview(panel)
        slide.configure(response: DownloadMotion.trayInResponse, bounce: DownloadMotion.trayInBounce)
        height.configure(response: FindMotion.swapResponse, bounce: 0)
        inputColor.configure(response: FindMotion.swapResponse, bounce: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
    override func layout() { super.layout(); render() }

    func applyTheme(_ theme: RiseTheme) {
        self.theme = theme
        panel.fill = theme.popup; panel.layer?.borderColor = theme.border.cgColor
        separator.fill = theme.text.withAlphaComponent(theme == .dark ? 0.06 : 0.045)
        [findPlaceholder, askPlaceholder, count].forEach { $0.textColor = theme.muted }
        shimmer.baseColor = theme.muted; shimmer.bandColor = theme.selectedText; badge.applyTheme(theme)
        // jakub.kr’s gray-500 selection: Lab lightness 19.38% dark / 89.212% light.
        let selection = theme == .dark ? NSColor(hex: 0x2F2F2F) : NSColor(hex: 0xE0E0E0)
        input.selectionColor = selection; answerView.selectedTextAttributes = [.backgroundColor: selection]
        [previous, next, close, moreButton].forEach { $0.contentTintColor = theme.muted; $0.hoverColor = theme.text.withAlphaComponent(0.07) }
        footerLabel.textColor = theme.muted; footerIcon.contentTintColor = theme.muted
        renderAnswer()
    }

    // MARK: Presentation

    /// Slides in, starting in find mode with a clean slate; an open bar just takes focus.
    func present() {
        if !isPresented {
            isPresented = true; isHidden = false
            cancelAnswer(); hasSubmittedQuestion = false; conversation = []; answerText = ""; answerFailed = false; stream = TokenStream(); lastQuestion = nil; renderAnswer()
            answeredText = nil; badge.caption = .send; badge.settle()
            setMode(.find, animated: false)
            height.target = Self.rowHeight; height.settle()
            slide.configure(response: DownloadMotion.trayInResponse, bounce: DownloadMotion.trayInBounce)
            slide.target = 1; animate()
            // Reopening keeps the last search, highlighted again, as browsers do.
            if !input.stringValue.isEmpty { run(.restart) }
        }
        window?.makeFirstResponder(input); input.selectText(nil)
    }
    /// Back in the window after its tab was away: at rest, with the page's matches repainted
    /// where they were rather than searched afresh.
    func reattached() {
        link?.invalidate(); link = nil; revealAllTokens(); settle()
        if isPresented && mode == .find && !input.stringValue.isEmpty { run(.refresh) }
    }
    /// Closed without sliding, for a bar whose tab is no longer shown.
    func closeInstantly() {
        isPresented = false; cancelAnswer(); slide.target = 0; settle()
    }
    /// The tab closed.
    func discard() { closeInstantly(); removeFromSuperview() }
    func hide() {
        guard isPresented else { return }
        isPresented = false; cancelAnswer()
        slide.configure(response: FindMotion.outResponse, bounce: DownloadMotion.trayOutBounce)
        slide.target = 0; animate()
    }

    private func setMode(_ new: Mode, animated: Bool) {
        mode = new
        let find = new == .find
        findText.set(find); askText.set(!find); controls.set(find); badgeItem.set(!find)
        if !animated { findText.settle(); askText.settle(); controls.settle(); badgeItem.settle() }
        input.setAccessibilityLabel(find ? "Find on page" : "Ask a model about the page")
        // Leaving find clears the page's highlights; coming back finds the text again.
        if find { finishInputColorTransition(); run(.restart) } else { findGeneration += 1; show(nil, animated: animated && answerTask == nil); Task { _ = await self.find?("", .restart) } }
        // The shimmer belongs to the question being answered, not to a find query.
        if find { shimmer.cancel() } else if answerTask != nil { shimmer.start() }
        updateSend(); retarget(); animate()
    }
    func toggleMode() { setMode(mode == .find ? .ask : .find, animated: true) }
    /// Before submission, Escape returns to the search without losing the draft.
    /// After submission it closes the dialog, including while an answer is streaming.
    func handleEscape() {
        if mode == .ask && !hasSubmittedQuestion {
            setMode(.find, animated: true); window?.makeFirstResponder(input)
        } else { dismiss?() }
    }
    /// Enter on an empty search or one with no matches offers to ask instead.
    private func offerToAsk() { setMode(.ask, animated: true) }

    // MARK: Find

    /// Searches as you type and steps with Enter, the chevrons and ⌘G; the newest request wins.
    func run(_ direction: PageFind.Direction) {
        guard mode == .find, let find else { return }
        findGeneration += 1
        let generation = findGeneration, query = input.stringValue
        Task {
            let matches = await find(query, query.isEmpty ? .restart : direction)
            guard generation == findGeneration, mode == .find else { return }
            show(query.isEmpty ? nil : matches)
        }
    }
    /// The selected tab changed or reloaded; search it for the same text.
    func pageChanged() {
        if isPresented && mode == .find && !input.stringValue.isEmpty { run(.restart) }
    }
    private func show(_ matches: PageFind.Matches?, animated: Bool = false) {
        lastMatches = matches
        let wasRed = input.textColor == .systemRed
        finishInputColorTransition()
        if animated && wasRed && matches?.count != 0 && window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            input.effectiveAppearance.performAsCurrentDrawingAppearance {
                self.inputColorStart = NSColor.systemRed.usingColorSpace(.sRGB)
            }
            inputColor.value = 0; inputColor.velocity = 0; inputColor.target = 1; animate()
        } else { input.textColor = matches?.count == 0 ? .systemRed : .labelColor }
        if let matches, let total = matches.count { count.stringValue = "\(total == 0 ? 0 : matches.index+1)/\(total)" }
        else { count.stringValue = "" }
        let stepping = matches?.count != 0
        previous.isEnabled = stepping; next.isEnabled = stepping
    }
    private func renderInputColor() {
        guard let start = inputColorStart else { return }
        var color = start
        input.effectiveAppearance.performAsCurrentDrawingAppearance {
            let target = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
            color = start.blended(withFraction: min(1, max(0, inputColor.value)), of: target) ?? target
        }
        // Temporary attributes redraw the field editor without restyling its storage every frame.
        if let editor = input.currentEditor() as? NSTextView, let manager = editor.layoutManager {
            manager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        } else { input.textColor = color }
    }
    private func finishInputColorTransition() {
        guard inputColorStart != nil else { return }
        inputColorStart = nil; inputColor.target = 1; inputColor.settle()
        input.textColor = .labelColor
        if let editor = input.currentEditor() as? NSTextView, let manager = editor.layoutManager {
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        placeholders.isHidden = !input.stringValue.isEmpty
        shimmer.needsDisplay = true; updateSend()
        if mode == .find { run(.restart) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): handleEscape(); return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)): toggleMode(); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Enter steps forward through the matches and Shift-Enter back, wrapping at either end.
            if mode == .find {
                if input.stringValue.isEmpty || lastMatches?.count == 0 { offerToAsk() }
                else { run(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .previous : .next) }
            } else { send() }
            return true
        default: return false
        }
    }

    // MARK: Ask

    func send() {
        let question = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .ask, !question.isEmpty else { return }
        ask(question, asked: input.stringValue)
        // The question is asked; the page gets the keyboard back until the input is clicked.
        if window?.firstResponder === input.currentEditor() { window?.makeFirstResponder(nil) }
    }
    /// Asks the last question again, in place of its answer.
    func regenerate() {
        guard let lastQuestion, answerTask == nil else { return }
        if conversation.last?.question == lastQuestion.question { conversation.removeLast() }
        ask(lastQuestion.question, asked: lastQuestion.asked)
    }
    func copyAnswer() {
        pasteboard.clearContents(); pasteboard.setString(answerView.string, forType: .string)
    }
    private func showMoreMenu() {
        let menu = NSMenu()
        let regenerate = NSMenuItem(title: "Regenerate", action: #selector(regenerateFromMenu), keyEquivalent: "")
        let copy = NSMenuItem(title: "Copy", action: #selector(copyFromMenu), keyEquivalent: "")
        [regenerate, copy].forEach { $0.target = self; menu.addItem($0) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.isFlipped ? moreButton.bounds.maxY+4 : -4), in: moreButton)
    }
    @objc private func regenerateFromMenu() { regenerate() }
    @objc private func copyFromMenu() { copyAnswer() }
    private func ask(_ question: String, asked: String) {
        guard let answer else { return }
        hasSubmittedQuestion = true; finishInputColorTransition()
        cancelAnswer()
        lastQuestion = (question, asked)
        let tokens = answer(question, conversation)
        answerText = ""; answerFailed = false; stream = TokenStream(); renderAnswer()
        answeredText = nil; badge.caption = .thinking
        shimmer.start(); animate()
        answerTask = Task { [weak self] in
            var text = ""
            do {
                // An empty token signals the first model output, before visible answer text.
                for try await token in tokens {
                    guard !Task.isCancelled else { return }
                    self?.responded(asked: asked)
                    text += token
                    if !token.isEmpty { self?.showAnswer(text) }
                }
                guard !Task.isCancelled else { return }
                self?.finishAnswer(question: question, asked: asked, answer: text)
            } catch {
                guard !Task.isCancelled else { return }
                self?.failAnswer(error, partial: text)
            }
        }
    }
    /// The model's first output, including snippet metadata or reasoning: "Done", then a close X a moment later.
    private func responded(asked: String) {
        guard badge.caption == .thinking else { return }
        badge.caption = .done; animate()
        doneTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(FindMotion.doneHold))
            guard !Task.isCancelled, let self else { return }
            self.answeredText = asked
            self.badge.caption = self.mode == .ask && self.input.stringValue == asked ? .close : .send
            self.animate()
        }
    }
    /// Back to Send, for a question that didn't get through.
    private func resetSend() {
        doneTask?.cancel(); doneTask = nil; answeredText = nil
        badge.caption = .send
        updateSend(); animate()
    }
    private func cancelAnswer() {
        // A replaced question must not inherit the previous response’s pending Done dismissal.
        doneTask?.cancel(); doneTask = nil
        answerTask?.cancel(); answerTask = nil; shimmer.cancel()
        // A cut-off answer is as long as it gets, so its highlight fades.
        stream.finish()
        if badge.caption == .thinking { resetSend() }
    }
    /// Edited questions get Send back; the answered question keeps its close X.
    private func updateSend() {
        guard badge.caption == .send || badge.caption == .close else { return }
        let caption: SendBadge.Caption = mode == .ask && answeredText != nil && input.stringValue == answeredText ? .close : .send
        guard caption != badge.caption else { return }
        badge.caption = caption; animate()
    }
    /// Lays out what has arrived; the display link shows its words.
    private func showAnswer(_ text: String) {
        stream.receive(text); layOutStream(); animate()
    }
    private func layOutStream() {
        let text = stream.text
        if text != answerText { answerText = text; renderAnswer() }
    }
    private func finishAnswer(question: String, asked: String, answer: String) {
        answerTask = nil; shimmer.finish(); stream.finish(); layOutStream()
        if !answer.isEmpty { conversation.append(Turn(question: question, answer: answer)) }
        else { resetSend(); stream = TokenStream(); answerText = "No answer came back."; answerFailed = true; renderAnswer() }
        animate()
    }
    private func failAnswer(_ error: Error, partial: String) {
        answerTask = nil; shimmer.finish(); resetSend(); stream = TokenStream()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        answerText = partial.isEmpty ? message : partial+"\n\n"+message; answerFailed = partial.isEmpty
        renderAnswer(); animate()
    }
    /// Shows the whole answer so far, for a bar that isn't animating.
    private func revealAllTokens() {
        guard !stream.isEmpty else { return }
        stream.revealAll(at: CACurrentMediaTime()); paintTokens(); followAnswer()
    }
    /// Colors the words still fading in or highlighted, and hides the ones not shown yet.
    /// Temporary attributes redraw them without restyling the answer every frame.
    private func paintTokens() {
        guard let manager = answerView.layoutManager else { return }
        let length = answerView.textStorage?.length ?? 0
        if paintedFrom < length {
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: paintedFrom, length: length-paintedFrom))
        }
        paintedFrom = length
        if let hidden = stream.hiddenFrom, hidden < length {
            manager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: NSRange(location: hidden, length: length-hidden))
            paintedFrom = hidden
        }
        for tint in stream.tints where NSMaxRange(tint.range) <= length {
            manager.addTemporaryAttribute(.foregroundColor, value: tint.color.color, forCharacterRange: tint.range)
            paintedFrom = min(paintedFrom, tint.range.location)
        }
    }
    /// Keeps the newest shown word in view once the panel has stopped growing, then the end of the answer.
    private func followAnswer() {
        guard height.target < contentHeight else { return }
        if !stream.isRevealing { answerView.scrollToEndOfDocument(nil) }
        else if let newest = stream.newest { answerView.scrollRangeToVisible(newest) }
    }
    private var showsAnswer: Bool { mode == .ask && !answerText.isEmpty }
    private var showsFooter: Bool { showsAnswer && !answerFailed }
    private var footerRoom: CGFloat { showsFooter ? Self.footerHeight-Self.answerInset.height : 0 }
    private func renderAnswer() {
        // A touch softer than the question above it.
        let color = answerFailed ? theme.muted : theme.text.blended(withFraction: 0.1, of: theme.popup) ?? theme.text
        answerView.textStorage?.setAttributedString(Self.styled(answerText, color: color))
        stream.base = OKLab(color)
        if !stream.isEmpty { stream.place(in: answerView.string as NSString, at: CACurrentMediaTime()) }
        paintedFrom = 0; paintTokens()
        retarget()
        if answerTask != nil || stream.isRevealing { followAnswer() }
    }

    /// Renders the model's light Markdown: bold, italics, code and links.
    static func styled(_ text: String, color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color, .paragraphStyle: paragraph]
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let markdown = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let result = NSMutableAttributedString()
        for run in markdown.runs {
            var attributes = base
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: 13, weight: intent.contains(.stronglyEmphasized) ? .semibold : .regular)
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 12, weight: .regular) }
            attributes[.font] = font
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
        }
        return result
    }

    // MARK: Layout and motion

    /// The answer's full height, including its insets.
    private var answerHeight: CGFloat {
        guard let container = answerView.textContainer, let manager = answerView.layoutManager else { return 0 }
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)+2*Self.answerInset.height
    }
    private var contentHeight: CGFloat { showsAnswer ? Self.rowHeight+1+answerHeight+footerRoom : Self.rowHeight }
    private var maxHeight: CGFloat { max(Self.rowHeight, bounds.height-topInset-Self.top-Self.bottom) }
    private func retarget() {
        let target = min(contentHeight, maxHeight)
        guard target != height.target else { return }
        height.target = target; animate()
    }
    private var panelOrigin: NSPoint {
        // Above the page's top edge while hidden; it drops straight down into its corner.
        let travel = (1-slide.value)*(topInset+Self.top+height.value+12)
        return NSPoint(x: bounds.width-Self.margin-Self.width, y: topInset+Self.top-travel)
    }
    private func render() {
        renderInputColor()
        let width = Self.width
        panel.frame = NSRect(origin: panelOrigin, size: NSSize(width: width, height: height.value))
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: Self.radius, continuous: true)
        content.frame = panel.bounds
        row.frame = NSRect(x: 0, y: 0, width: width, height: Self.rowHeight)
        placeholders.frame = row.bounds
        let fieldHeight = ceil(input.intrinsicContentSize.height)
        // Find leaves room for the count and buttons; a question can run up to the badge.
        let field = NSRect(x: 12, y: (Self.rowHeight-fieldHeight)/2, width: width-12-140, height: fieldHeight)
        input.frame = mode == .find ? field : NSRect(x: 12, y: field.minY, width: width-12-badge.rightInset-badge.width-10, height: fieldHeight)
        findText.render(at: field); askText.render(at: field)
        controls.render(at: NSRect(x: width-8-124, y: (Self.rowHeight-28)/2, width: 124, height: 28))
        let countHeight = ceil(count.intrinsicContentSize.height)
        count.frame = NSRect(x: 0, y: (28-countHeight)/2, width: 40, height: countHeight)
        previous.frame = NSRect(x: 44, y: 0, width: 26, height: 28)
        next.frame = NSRect(x: 71, y: 0, width: 26, height: 28)
        close.frame = NSRect(x: 98, y: 0, width: 26, height: 28)
        // As far in from the right as the text is from the left.
        badgeItem.render(at: NSRect(x: width-badge.rightInset-badge.width, y: 0, width: badge.width, height: Self.rowHeight))
        badge.renderContents()
        shimmer.frame = input.frame.insetBy(dx: 0, dy: -3)
        // The answer is laid out at its final height and revealed as the panel grows.
        let answerTop = Self.rowHeight+1
        separator.frame = NSRect(x: 12, y: Self.rowHeight, width: width-24, height: 1)
        separator.alphaValue = min(1, max(0, (height.value-Self.rowHeight)/12))
        answerScroll.frame = NSRect(x: 0, y: answerTop, width: width, height: max(0, height.target-answerTop-footerRoom))
        answerScroll.isHidden = !showsAnswer && height.value-Self.rowHeight < 0.5
        footer.isHidden = !showsFooter
        footer.frame = NSRect(x: 0, y: height.target-Self.footerHeight, width: width, height: Self.footerHeight)
        moreButton.frame = NSRect(x: width-Self.answerInset.width-18, y: Self.footerMid-10, width: 22, height: 20)
        let labelSize = footerLabel.intrinsicContentSize
        footerIcon.frame = NSRect(x: Self.answerInset.width-1, y: Self.footerMid-6.5, width: 13, height: 13)
        footerLabel.frame = NSRect(x: footerIcon.frame.maxX+4, y: Self.footerMid-labelSize.height/2, width: moreButton.frame.minX-footerIcon.frame.maxX-8, height: labelSize.height)
    }
    private func animate() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { revealAllTokens(); settle(); return }
        guard link == nil else { return }
        lastTick = CACurrentMediaTime()
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common); self.link = link
    }
    private func settle() {
        slide.settle(); height.settle(); badge.settle(); finishInputColorTransition()
        findText.settle(); askText.settle(); controls.settle(); badgeItem.settle()
        finishIfIdle()
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime(), dt = min(0.05, now-(lastTick ?? now)); lastTick = now
        slide.step(dt); height.step(dt); badge.step(dt); inputColor.step(dt)
        findText.step(dt); askText.step(dt); controls.step(dt); badgeItem.step(dt)
        if stream.step(at: now) { followAnswer() }
        paintTokens()
        let resting = slide.isResting(within: 0.001) && height.isResting(within: 0.05) && badge.isResting
            && findText.isResting && askText.isResting && controls.isResting && badgeItem.isResting && inputColor.isResting(within: 0.002)
            && !stream.needsFrames
        if resting { link.invalidate(); self.link = nil; settle() } else { render() }
    }
    private func finishIfIdle() {
        render()
        if !isPresented && slide.value == 0 { isHidden = true }
    }
}

@MainActor extension BrowserController {
    /// The selected tab's find bar.
    var findBar: FindBar { selectedTab.map(findBar(for:)) ?? tablessFindBar }
    func findBar(for tab: BrowserTab) -> FindBar {
        if let bar = findBars[tab.id] { return bar }
        let bar = FindBar(); bar.applyTheme(theme)
        bar.find = { [weak tab] query, direction in
            guard let webView = tab?.webView else { return PageFind.Matches(count: 0, index: -1) }
            return await PageFind.find(query, direction: direction, in: webView)
        }
        bar.dismiss = { [weak self] in self?.hideFind() }
        configurePageAssistant(bar, for: tab)
        findBars[tab.id] = bar
        return bar
    }
    /// Only the selected tab's bar is in the window. A bar left empty has nothing worth keeping,
    /// so leaving its tab closes it; one with a search or question waits for the tab to return.
    func swapFindBar(from previousID: UUID?) {
        if let previousID, previousID != selectedID, let bar = findBars[previousID] {
            bar.removeFromSuperview()
            if bar.isPresented && bar.input.stringValue.isEmpty && !bar.isAnswering {
                bar.closeInstantly()
                if let webView = tabs.first(where: { $0.id == previousID })?.webView { Task { await PageFind.clearPassage(webView) } }
            }
        }
        let bar = findBar
        if bar.superview !== root { root.addSubview(bar, positioned: .below, relativeTo: linkStatus) }
    }
    /// ⌘F opens the bar, and closes it when it's already open.
    @objc func showFind() { if findBar.isPresented { hideFind() } else { findBar.present() } }
    @objc func findNext() { findAgain(.next) }
    @objc func findPrevious() { findAgain(.previous) }
    /// ⌘G and ⇧⌘G reopen a closed bar on the last search; an open one steps through its matches.
    private func findAgain(_ direction: PageFind.Direction) {
        if findBar.isPresented { findBar.run(direction) } else if !findBar.input.stringValue.isEmpty { findBar.present() }
    }
    func hideFind() {
        findBar.hide()
        if let webView = selectedTab?.webView {
            Task { await PageFind.clear(webView, selectingCurrent: true); await PageFind.clearPassage(webView) }
        }
        window?.makeFirstResponder(selectedTab?.webView)
    }
}
