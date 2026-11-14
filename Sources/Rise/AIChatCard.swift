import AppKit

/// A single line of a card that's edited where it is: Return keeps what's typed, as does
/// clicking away, and Escape puts back what was there.
@MainActor final class AIChatCardField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    /// What it says while empty; AppKit forgets its own once it's given colour.
    let placeholder: String
    private var before = ""
    init(placeholder: String, weight: NSFont.Weight = .regular) {
        self.placeholder = placeholder
        super.init(frame: .zero)
        isBordered = false; isBezeled = false; drawsBackground = false; focusRingType = .none
        isEditable = true; isSelectable = true; usesSingleLineMode = true
        cell?.wraps = false; cell?.isScrollable = true; lineBreakMode = .byTruncatingTail
        font = AIChatStyle.font(AIChatCard.fontSize, weight: weight)
        placeholderString = placeholder; delegate = self
        setAccessibilityLabel(placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { before = stringValue }
        return took
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        stringValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        onCommit?(stringValue)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            window?.makeFirstResponder(superview); return true
        case #selector(NSResponder.cancelOperation(_:)):
            stringValue = before; window?.makeFirstResponder(superview); return true
        default: return false
        }
    }
    func applyColors(_ colors: AIChatColors) {
        textColor = colors.text
        placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [.font: font ?? AIChatStyle.font(AIChatCard.fontSize), .foregroundColor: colors.placeholder])
    }
}

/// A card's longer text, as an email's body or an event's notes, edited where it is, growing with
/// it, with a grey word in it while it's empty.
@MainActor final class AIChatCardBody: NSTextView {
    var onChange: ((String) -> Void)?
    var placeholder: NSAttributedString? { didSet { needsDisplay = true } }
    init() {
        let storage = NSTextStorage(), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = false; importsGraphics = false; allowsUndo = true; drawsBackground = false
        textContainerInset = .zero; textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        isVerticallyResizable = false; isHorizontallyResizable = false
        isAutomaticQuoteSubstitutionEnabled = false; isAutomaticDashSubstitutionEnabled = false
    }
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) { super.init(frame: frameRect, textContainer: container) }
    required init?(coder: NSCoder) { fatalError() }
    override func didChangeText() { super.didChangeText(); onChange?(string); needsDisplay = true }
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        placeholder.draw(with: NSRect(x: 0, y: 0, width: bounds.width, height: AIChatCard.bodyLineHeight), options: [.usesLineFragmentOrigin])
    }
}

/// What the chat's model makes for the user to use, in the answer as a card styled as the
/// composer's: what it's about and its actions on top, then rows of fields, each label's field the
/// same way from it, and a longer text under them, each edited in place. Once a later card of the
/// same kind takes its place, as when the user asks for an email shorter, it folds up to its
/// header with a chevron that opens it again; the latest stays open. Emails (`AIChatEmail.swift`)
/// and events (`AIChatEvent.swift`) fill it in.
@MainActor class AIChatCard: FlippedView {
    nonisolated static let radius: CGFloat = 16, inset: CGFloat = 16, headerHeight: CGFloat = 44, rowHeight: CGFloat = 40
    static let fontSize: CGFloat = 15
    static let bodyTop: CGFloat = 12, bodyBottom: CGFloat = 16, bodyLineHeight: CGFloat = 22
    /// From a row's label to its field, the same on every row.
    static let labelGap: CGFloat = 8
    static let iconSize: CGFloat = 18, iconStroke: CGFloat = 1.35

    /// A row: its label, if it has one, what's in it, and whether a hairline runs under it.
    struct Row {
        var label: NSTextField?
        var content: NSView
        var dividerBelow = true
        /// Its height, for one whose content wraps (`AIChatCardRowContent`).
        var height: CGFloat = AIChatCard.rowHeight
    }

    /// "Email", "Event": a later card of the same kind folds this one.
    let kind: String
    /// Its height changed, as its text grew or a row came or went.
    var onResize: (() -> Void)?

    let card = Surface(radius: radius)
    let heading = label("", size: 13)
    let chevron = ChromeButton(symbol: "chevron.down", size: 11, title: "Show", action: {})
    let body = AIChatCardBody()
    private var dividers: [Surface] = []
    /// Every view that may be in a row, so those not in one now are hidden.
    private var rowViews: [NSView] = []
    private var rowFrames: [(frame: NSRect, content: NSView)] = []
    private(set) var colors = AIChatColors(.neutral)

    init(kind: String) {
        self.kind = kind
        super.init(frame: .zero)
        card.layer?.cornerCurve = .continuous; card.layer?.borderWidth = 0.5
        heading.lineBreakMode = .byTruncatingTail
        chevron.layer?.cornerRadius = 6; chevron.isHidden = true
        chevron.actionBlock = { [weak self] in guard let self else { return }; self.setCollapsed(!self.isCollapsed) }
        body.font = AIChatStyle.font(Self.fontSize)
        [card, heading, chevron, body].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: What a kind of card fills in

    /// What the header says: the email's subject, the event's title.
    var headingText: String { kind }
    /// The header's buttons, left to right, by its right edge.
    var headerButtons: [NSView] { [] }
    /// The rows as they are now.
    var rows: [Row] { [] }
    /// What the body says while it's empty, if anything: "Notes".
    var bodyPlaceholder: String? { nil }
    /// Puts views that rows use in the card.
    func addRowViews(_ views: [NSView]) { rowViews += views; views.forEach(addSubview) }
    /// What's written in it changed: the header follows, and the answer makes room if it grew.
    func contentChanged(resized: Bool = false) {
        updateHeading(); needsLayout = true
        if resized { onResize?() }
    }

    // MARK: Folding

    /// A later card of its kind took its place: it folds up, and can be opened and folded again.
    var isSuperseded = false {
        didSet {
            guard isSuperseded != oldValue else { return }
            isCollapsed = isSuperseded
            updateHeading(); applyCollapse()
        }
    }
    private(set) var isCollapsed = false
    func setCollapsed(_ collapsed: Bool) {
        guard isSuperseded || !collapsed, collapsed != isCollapsed else { return }
        isCollapsed = collapsed; applyCollapse()
    }
    func updateHeading() {
        let text = headingText.isEmpty ? kind : headingText
        heading.stringValue = isSuperseded ? "Earlier draft · \(text)" : text
    }
    /// Folded, only the header shows, its chevron pointing down; opened, the rest comes back, the
    /// header's buttons too, and the chevron points up.
    private func applyCollapse() {
        if isCollapsed, let responder = window?.firstResponder as? NSView, responder.isDescendant(of: self) { window?.makeFirstResponder(self) }
        (rowViews+dividers+[body]+headerButtons).forEach { $0.isHidden = isCollapsed }
        chevron.isHidden = !isSuperseded
        let title = "\(isCollapsed ? "Show" : "Hide") \(kind)"
        chevron.image = NSImage(systemSymbolName: isCollapsed ? "chevron.down" : "chevron.up", accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        chevron.setAccessibilityLabel(title)
        needsLayout = true; onResize?()
    }

    // MARK: Look

    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        card.fill = colors.composer; card.layer?.borderColor = colors.composerBorder.cgColor
        heading.textColor = colors.muted
        for button in headerButtons.compactMap({ $0 as? ChromeButton })+[chevron] where !(button is AIChatCardPillButton) {
            button.contentTintColor = colors.actionIcon; button.hoverColor = colors.hover
            button.hoverHint?.appearance = NSAppearance(named: colors.dark ? .darkAqua : .aqua)
        }
        for view in rowViews {
            if let field = view as? AIChatCardField { field.applyColors(colors) }
            else if let label = view as? NSTextField { label.textColor = colors.text }
            else if let content = view as? AIChatCardRowContent { content.applyColors(colors) }
        }
        dividers.forEach { $0.fill = colors.hairline }
        body.insertionPointColor = colors.text
        body.selectedTextAttributes = [.backgroundColor: colors.dark ? NSColor(hex: 0x3A3A3A) : NSColor(hex: 0xDADADA)]
        applyBodyStyle()
    }
    /// The body's text in the card's style, its placeholder too.
    func applyBodyStyle() {
        let attributes = AIChatStyle.attributes(AIChatStyle.font(Self.fontSize), color: colors.text, lineHeight: Self.bodyLineHeight)
        body.typingAttributes = attributes
        body.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        if let storage = body.textStorage, storage.length > 0 { storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length)) }
        if let words = bodyPlaceholder {
            var grey = attributes; grey[.foregroundColor] = colors.placeholder
            body.placeholder = NSAttributedString(string: words, attributes: grey)
        }
    }
    /// Sets the body's text from outside, as the model rewrote it.
    func setBody(_ text: String) {
        guard body.string != text else { return }
        body.string = text; applyBodyStyle()
    }

    // MARK: Layout

    private func rowHeight(_ row: Row, width: CGFloat) -> CGFloat {
        guard let content = row.content as? AIChatCardRowContent else { return row.height }
        return content.rowHeight(for: max(1, width-2*Self.inset-labelWidth(row.label)))
    }
    private func labelWidth(_ label: NSTextField?) -> CGFloat {
        guard let label else { return 0 }
        // Measured from the text, with the 2 pt a label draws in from each side.
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font ?? AIChatStyle.font(Self.fontSize)]).width)+4+Self.labelGap
    }
    func height(for width: CGFloat) -> CGFloat {
        if isCollapsed { return Self.headerHeight }
        let rowsHeight = rows.reduce(CGFloat(0)) { $0+rowHeight($1, width: width) }
        let text = max(Self.bodyLineHeight, body.usedSize(width: max(1, width-2*Self.inset)).height)
        return Self.headerHeight+rowsHeight+Self.bodyTop+text+Self.bodyBottom
    }
    override func layout() {
        super.layout()
        let width = bounds.width, inset = Self.inset, inner = width-2*inset
        card.frame = bounds
        // Folded, the header's centred in the card; opened, a little lower, over the rows.
        let mid = isCollapsed ? Self.headerHeight/2 : Self.headerHeight/2+2
        var right = width-10
        for button in ([chevron]+headerButtons.reversed()) where !button.isHidden {
            let buttonWidth = (button as? AIChatCardHeaderSized)?.headerWidth ?? 28
            // A filled pill keeps the card's inset, as an icon's own padding does, and a gap from what's before it.
            if button is AIChatCardPillButton {
                right = min(right, width-12)
                button.frame = NSRect(x: right-buttonWidth, y: round(mid-13), width: buttonWidth, height: 26); right -= buttonWidth+6
            } else {
                button.frame = NSRect(x: right-buttonWidth, y: round(mid-14), width: buttonWidth, height: 28); right -= buttonWidth+2
            }
        }
        let headingHeight = ceil(heading.intrinsicContentSize.height)
        heading.frame = NSRect(x: inset, y: round(mid-headingHeight/2), width: max(0, right-8-inset), height: headingHeight)
        guard !isCollapsed else { return }

        var y = Self.headerHeight
        var used = 0
        func divider() {
            if used == dividers.count { let line = Surface(); line.fill = colors.hairline; dividers.append(line); addSubview(line) }
            dividers[used].frame = NSRect(x: inset, y: y-0.5, width: inner, height: 0.5); dividers[used].isHidden = false; used += 1
        }
        // A hairline under the header and under each row that has one.
        divider()
        rowFrames = []
        let shown = rows
        var visible = Set<ObjectIdentifier>()
        for row in shown {
            let height = rowHeight(row, width: width)
            var x = inset
            if let label = row.label {
                visible.insert(ObjectIdentifier(label))
                let labelHeight = ceil(label.intrinsicContentSize.height)
                label.frame = NSRect(x: inset, y: round(y+Self.rowHeight/2-labelHeight/2), width: labelWidth(label)-Self.labelGap, height: labelHeight)
                x += labelWidth(label)
            }
            visible.insert(ObjectIdentifier(row.content))
            if row.content is NSTextField {
                let fieldHeight = ceil(row.content.intrinsicContentSize.height)
                row.content.frame = NSRect(x: x, y: round(y+height/2-fieldHeight/2), width: width-inset-x, height: fieldHeight)
            } else {
                row.content.frame = NSRect(x: x, y: y, width: width-inset-x, height: height)
            }
            rowFrames.append((NSRect(x: 0, y: y, width: width, height: height), row.content))
            y += height
            if row.dividerBelow { divider() }
        }
        for view in rowViews { view.isHidden = !visible.contains(ObjectIdentifier(view)) }
        for index in used..<dividers.count { dividers[index].isHidden = true }
        let text = max(Self.bodyLineHeight, body.usedSize(width: inner).height)
        body.frame = NSRect(x: inset, y: y+Self.bodyTop, width: inner, height: text)
    }
    /// A click on a row edits its field; under them, the body, its cursor at the end.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // An earlier draft's header opens and folds it.
        if isSuperseded, point.y < Self.headerHeight { setCollapsed(!isCollapsed); return }
        if let row = rowFrames.first(where: { $0.frame.contains(point) }) {
            if let field = row.content as? NSTextField {
                window?.makeFirstResponder(field); field.currentEditor()?.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            } else { window?.makeFirstResponder(self) }
        } else if !body.isHidden, point.y > body.frame.minY-Self.bodyTop {
            window?.makeFirstResponder(body); body.setSelectedRange(NSRange(location: (body.string as NSString).length, length: 0))
        } else { window?.makeFirstResponder(self) }
    }
    override var acceptsFirstResponder: Bool { true }
}

/// A row's content other than a field, as an event's times, which may wrap onto more lines.
@MainActor protocol AIChatCardRowContent: NSView {
    func rowHeight(for width: CGFloat) -> CGFloat
    func applyColors(_ colors: AIChatColors)
}
/// What a card in the answer holds, as a step made it and the user since edited it.
enum AIChatDraft: Equatable, Sendable {
    case email(AIChatEmailDraft), event(AIChatEventDraft)
    /// For the model's follow-ups, so "make it shorter" or "an hour later" works from the edits.
    var modelText: String {
        switch self {
        case .email(let draft): draft.modelText
        case .event(let draft): draft.modelText
        }
    }
}

/// A header button wider than an icon, as a text button.
@MainActor protocol AIChatCardHeaderSized: NSView {
    var headerWidth: CGFloat { get }
}

/// A header button that's words: a menu's choice, with a chevron after it.
@MainActor final class AIChatCardMenuButton: MenuButton, AIChatCardHeaderSized {
    private var colors = AIChatColors(.neutral)
    override init(title: String) {
        super.init(title: title)
        imagePosition = .imageTrailing; imageHugsTitle = true
        image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium))
        alignsMenuTrailing = true
        setTitle(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setTitle(_ text: String) {
        // A thin space puts the chevron a little further from the words than the button's own gap does.
        attributedTitle = NSAttributedString(string: text+"\u{2009}", attributes: [.font: AIChatStyle.font(13), .foregroundColor: colors.muted])
        setAccessibilityLabel(text)
    }
    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        contentTintColor = colors.muted; hoverColor = colors.hover
        setTitle(attributedTitle.string.trimmingCharacters(in: .whitespaces))
    }
    var headerWidth: CGFloat { ceil(attributedTitle.size().width)+12+18 }
}

/// The card's one strong action, filled as the composer's send button is: Add.
@MainActor final class AIChatCardPillButton: ChromeButton, AIChatCardHeaderSized {
    private var colors = AIChatColors(.neutral)
    private var text: String
    init(title: String) {
        text = title
        super.init(symbol: "plus", size: 11, title: title, action: {})
        imagePosition = .noImage; image = nil
        layer?.cornerRadius = 13; layer?.cornerCurve = .continuous
        setTitle(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setTitle(_ title: String, symbol: String? = nil) {
        text = title
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
            imagePosition = .imageLeading
        } else { image = nil; imagePosition = .noImage }
        attributedTitle = NSAttributedString(string: symbol == nil ? title : " "+title, attributes: [.font: AIChatStyle.font(13, weight: .medium), .foregroundColor: colors.sendOnIcon])
        setAccessibilityLabel(title)
    }
    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        baseColor = colors.sendOn; hoverColor = colors.sendOn.blended(withFraction: 0.15, of: colors.dark ? .black : .white) ?? colors.sendOn
        contentTintColor = colors.sendOnIcon
        setTitle(text, symbol: image == nil ? nil : "checkmark")
        refreshHoverState()
    }
    var headerWidth: CGFloat { ceil(attributedTitle.size().width)+(image == nil ? 0 : 12)+24 }
}
