import AppKit
import RiseCore

/// A page mentioned with @ in the question: one character of the text, so Delete and Forward
/// Delete take it out whole, drawn as a pill of its favicon and title.
final class AIChatMentionAttachment: NSTextAttachment {
    let page: AIChatAttachment
    var mentionCell: AIChatMentionCell? { attachmentCell as? AIChatMentionCell }
    init(_ page: AIChatAttachment, style: AIChatMentionCell.Style) {
        self.page = page
        super.init(data: nil, ofType: nil)
        attachmentCell = AIChatMentionCell(page: page, style: style)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A mention's pill: a rounded rectangle a little past its words, washed in its favicon's colour
/// as a pinned tab is (`FaviconColor`, `PinnedLayout.tint`), with the favicon at its left and the
/// title, up to `maximumTextWidth`, beside it.
final class AIChatMentionCell: NSTextAttachmentCell {
    struct Style: Equatable {
        /// Its title's size, and the text's around it, whose capitals it's centred on.
        var fontSize: CGFloat, lineFontSize: CGFloat, height: CGFloat, iconSize: CGFloat
        var text: NSColor, muted: NSColor, dark: Bool
        /// In the composer, on its 24 pt lines of 16 pt text.
        static func composer(_ colors: AIChatColors) -> Style {
            Style(fontSize: 15, lineFontSize: AIChatStyle.inputFontSize, height: 22, iconSize: 14, text: colors.text, muted: colors.muted, dark: colors.dark)
        }
        /// In a sent question's bubble, on its 24 pt lines of 14 pt text.
        static func bubble(_ colors: AIChatColors) -> Style {
            Style(fontSize: 13.5, lineFontSize: AIChatStyle.bubbleFontSize, height: 20, iconSize: 13, text: colors.text, muted: colors.muted, dark: colors.dark)
        }
    }
    static let padding: CGFloat = 5, gap: CGFloat = 4, radius: CGFloat = 6, maximumTextWidth: CGFloat = 170
    let page: AIChatAttachment
    var style: Style
    /// The favicon's colour, worked out once.
    let accent: NSColor?
    init(page: AIChatAttachment, style: Style) {
        self.page = page; self.style = style
        accent = page.favicon.flatMap(FaviconColor.dominant)
        super.init(textCell: "")
    }
    required init(coder: NSCoder) { fatalError() }

    var pageTitle: String { AIChatQuestionPart.title(of: page) }
    var titleFont: NSFont { AIChatStyle.font(style.fontSize) }
    /// The title as shown: whole, or cut short with an ellipsis where it's wider than the pill
    /// allows, so the pill ends as close after it as it starts before.
    private(set) lazy var shownTitle: String = Self.truncated(pageTitle, font: titleFont, width: Self.maximumTextWidth)
    private var textWidth: CGFloat { ceil((shownTitle as NSString).size(withAttributes: [.font: titleFont]).width) }
    static func truncated(_ title: String, font: NSFont, width: CGFloat) -> String {
        func fits(_ text: String) -> Bool { (text as NSString).size(withAttributes: [.font: font]).width <= width }
        guard !fits(title) else { return title }
        let characters = Array(title)
        var low = 0, high = characters.count
        while low < high {
            let middle = (low+high+1)/2
            if fits(String(characters.prefix(middle)).trimmingCharacters(in: .whitespaces)+"…") { low = middle } else { high = middle-1 }
        }
        return String(characters.prefix(low)).trimmingCharacters(in: .whitespaces)+"…"
    }
    /// Its wash: a chosen pinned tab's, in its favicon's colour, or a grey without one.
    var fill: NSColor { PinnedLayout.tint(accent, theme: style.dark ? .dark : .neutral, selected: true, hovered: false) }

    /// The room it takes in its line: centred on the text's capitals and no taller than the text
    /// reaches above and below them, so a line with a mention lies where one without does. The
    /// pill itself is drawn `style.height` tall, past it, inside the line's own height.
    var layoutHeight: CGFloat {
        let text = AIChatStyle.font(style.lineFontSize), middle = text.capHeight/2
        // A point to spare: any closer to the descent and TextKit raises the line (measured).
        return min(style.height, floor(2*min(text.ascender-middle, middle-text.descender)-1))
    }
    override func cellSize() -> NSSize {
        NSSize(width: ceil(Self.padding+style.iconSize+Self.gap+textWidth+Self.padding), height: layoutHeight)
    }
    /// Its middle on the middle of the line's capitals, as the text around it sits.
    override func cellBaselineOffset() -> NSPoint {
        let text = AIChatStyle.font(style.lineFontSize)
        return NSPoint(x: 0, y: text.capHeight/2-layoutHeight/2)
    }
    override func wantsToTrackMouse() -> Bool { false }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let pill = cellFrame.insetBy(dx: 0, dy: -(style.height-cellFrame.height)/2)
        let frame = controlView?.backingAlignedRect(pill, options: .alignAllEdgesNearest) ?? pill
        fill.setFill()
        NSBezierPath(roundedRect: frame, xRadius: Self.radius, yRadius: Self.radius).fill()
        let flipped = controlView?.isFlipped ?? true
        let size = style.iconSize
        let icon = NSRect(x: frame.minX+Self.padding, y: round(frame.midY-size/2), width: size, height: size)
        if let favicon = page.favicon {
            favicon.draw(in: icon, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: flipped, hints: [.interpolation: NSImageInterpolation.high])
        } else if let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size-2, weight: .regular).applying(.init(paletteColors: [style.muted]))) {
            let glyph = NSRect(x: icon.midX-globe.size.width/2, y: icon.midY-globe.size.height/2, width: globe.size.width, height: globe.size.height)
            globe.draw(in: glyph, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: flipped, hints: nil)
        }
        // On a baseline that puts its capitals in the pill's middle.
        let font = titleFont
        let words = NSAttributedString(string: shownTitle, attributes: [.font: font, .foregroundColor: style.text])
        let baseline = flipped ? frame.midY+font.capHeight/2 : frame.midY-font.capHeight/2
        words.draw(with: NSRect(x: icon.maxX+Self.gap, y: baseline, width: textWidth+1, height: 0), options: [])
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

extension NSAttributedString {
    /// The mentions in it, in order, each with its place.
    var mentions: [(range: NSRange, page: AIChatAttachment)] {
        var found: [(NSRange, AIChatAttachment)] = []
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, range, _ in
            if let mention = value as? AIChatMentionAttachment { found.append((range, mention.page)) }
        }
        return found
    }
    /// Words and mentions, as a question's parts, with the whitespace at either end trimmed.
    var questionParts: [AIChatQuestionPart] {
        var parts: [AIChatQuestionPart] = [], text = ""
        let string = self.string as NSString
        var index = 0
        for (range, page) in mentions {
            text += string.substring(with: NSRange(location: index, length: range.location-index))
            if !text.isEmpty { parts.append(.text(text)); text = "" }
            parts.append(.mention(page)); index = NSMaxRange(range)
        }
        text += string.substring(from: index)
        if !text.isEmpty { parts.append(.text(text)) }
        if case .text(let first)? = parts.first {
            let trimmed = String(first.drop(while: { $0.isWhitespace }))
            if trimmed.isEmpty { parts.removeFirst() } else { parts[0] = .text(trimmed) }
        }
        if case .text(let last)? = parts.last {
            let trimmed = String(last.reversed().drop(while: { $0.isWhitespace }).reversed())
            if trimmed.isEmpty { parts.removeLast() } else { parts[parts.count-1] = .text(trimmed) }
        }
        return parts
    }
    /// As plain text, each mention by its title.
    var plainMentionText: String {
        let text = NSMutableString(string: string)
        for (range, page) in mentions.reversed() { text.replaceCharacters(in: range, with: AIChatQuestionPart.title(of: page)) }
        return text as String
    }
}

extension AIChatQuestionPart {
    /// Parts as text with each mention a pill, in `attributes`.
    static func attributed(_ parts: [AIChatQuestionPart], attributes: [NSAttributedString.Key: Any],
                           style: AIChatMentionCell.Style) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for part in parts {
            switch part {
            case .text(let text): result.append(NSAttributedString(string: text, attributes: attributes))
            case .mention(let page):
                var mention = attributes; mention[.attachment] = AIChatMentionAttachment(page, style: style)
                result.append(NSAttributedString(string: "\u{FFFC}", attributes: mention))
            }
        }
        return result
    }
}

/// The open pages to mention, as the + menu lists them, just above the @ as it's typed and
/// narrowing as what follows it is: a card in the chat's own colours, each page with its favicon,
/// its title and its site, the best match chosen. ↑ and ↓ choose, Tab or Return picks, as does a
/// click; Escape leaves what was typed.
@MainActor final class AIChatMentionMenu: FlippedView {
    static let rowHeight: CGFloat = 32, headerHeight: CGFloat = 28, padding: CGFloat = 6
    static let iconSize: CGFloat = 16, radius: CGFloat = 14, rowRadius: CGFloat = 8
    static let maximumRows = 8, minimumWidth: CGFloat = 240, maximumWidth: CGFloat = 340
    static let header = "Open Pages"
    /// Between the menu and the @'s line, and the panel's edges.
    static let gap: CGFloat = 4, margin: CGFloat = 8
    /// The card, in the composer's own colour, clipped to its corners; the shadow is drawn by this view.
    private let card = FlippedView()
    private let headerLabel = NSTextField(labelWithString: AIChatMentionMenu.header)
    private var rows: [Row] = []
    private(set) var pages: [AIChatAttachment] = []
    private(set) var selected = 0
    /// How many rows fit above the @; the best matches are the ones shown.
    var rowLimit = AIChatMentionMenu.maximumRows
    private var colors = AIChatColors(.neutral)
    var onPick: ((AIChatAttachment) -> Void)?
    var isShown: Bool { !isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor; layer?.shadowRadius = 14; layer?.shadowOffset = NSSize(width: 0, height: 6)
        card.wantsLayer = true; card.layer?.cornerRadius = Self.radius; card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true; card.layer?.borderWidth = 0.5
        headerLabel.font = AIChatStyle.font(12, weight: .medium)
        card.addSubview(headerLabel); addSubview(card)
        isHidden = true
        setAccessibilityElement(true); setAccessibilityRole(.menu); setAccessibilityLabel(Self.header)
        applyColors(colors)
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyColors(_ colors: AIChatColors) {
        self.colors = colors
        layer?.shadowOpacity = colors.dark ? 0.45 : 0.12
        card.layer?.backgroundColor = colors.composer.cgColor
        card.layer?.borderColor = colors.composerBorder.cgColor
        headerLabel.textColor = colors.muted
        rows.forEach { $0.applyColors(colors) }
    }

    /// Lists `pages`, keeping the chosen one where it's still listed.
    func show(_ pages: [AIChatAttachment]) {
        let chosen = self.pages.indices.contains(selected) ? self.pages[selected] : nil
        self.pages = Array(pages.prefix(max(1, min(rowLimit, Self.maximumRows))))
        selected = chosen.flatMap { page in self.pages.firstIndex { $0 == page } } ?? 0
        rows.forEach { $0.removeFromSuperview() }
        rows = self.pages.map { page in
            let row = Row(page)
            row.applyColors(colors)
            card.addSubview(row)
            return row
        }
        highlight()
        setFrameSize(preferredSize); needsLayout = true
        if isHidden { isHidden = false; appear() }
    }
    /// Fades in, rising a little from the @ and growing to its size, as a popover does.
    private func appear() {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        layoutSubtreeIfNeeded()
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0; fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform")
        // From its bottom left corner, nearest the @.
        let anchor = CGPoint(x: 0, y: bounds.height)
        var start = CATransform3DMakeTranslation(anchor.x, anchor.y+4, 0)
        start = CATransform3DScale(start, 0.97, 0.97, 1)
        start = CATransform3DTranslate(start, -anchor.x, -anchor.y, 0)
        rise.fromValue = start; rise.toValue = CATransform3DIdentity
        let group = CAAnimationGroup(); group.animations = [fade, rise]
        group.duration = 0.16; group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(group, forKey: "appear")
    }
    func hide() {
        guard !isHidden else { return }
        layer?.removeAnimation(forKey: "appear")
        isHidden = true; pages = []; rows.forEach { $0.removeFromSuperview() }; rows = []
    }
    var preferredSize: NSSize { size(rows: pages.count) }
    func size(rows count: Int) -> NSSize {
        let widest = pages.map { Row.width(of: $0) }.max() ?? 0
        let width = min(Self.maximumWidth, max(Self.minimumWidth, widest+2*Self.padding))
        return NSSize(width: ceil(width), height: 2*Self.padding+Self.headerHeight+Self.rowHeight*CGFloat(count))
    }
    func move(_ step: Int) {
        guard !pages.isEmpty else { return }
        selected = (selected+step+pages.count)%pages.count
        highlight()
    }
    /// Picks the chosen page; false with none listed.
    @discardableResult func pickSelected() -> Bool {
        guard pages.indices.contains(selected) else { return false }
        onPick?(pages[selected])
        return true
    }
    private func highlight() {
        for (index, row) in rows.enumerated() { row.isChosen = index == selected }
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
        let header = ceil(headerLabel.intrinsicContentSize.height)
        headerLabel.frame = NSRect(x: Self.padding+Row.inset-2, y: Self.padding+(Self.headerHeight-header)/2+1,
                                   width: bounds.width-2*Self.padding-Row.inset, height: header)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: Self.padding, y: Self.padding+Self.headerHeight+Self.rowHeight*CGFloat(index),
                               width: bounds.width-2*Self.padding, height: Self.rowHeight)
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
    private func row(at event: NSEvent) -> Int? {
        let point = card.convert(event.locationInWindow, from: nil)
        return rows.firstIndex { $0.frame.contains(point) }
    }
    override func mouseMoved(with event: NSEvent) {
        if let index = row(at: event), index != selected { selected = index; highlight() }
    }
    /// Taken here, so the text keeps the keyboard.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard let index = row(at: event) else { return }
        selected = index; highlight(); pickSelected()
    }

    /// A page's row: its favicon, its title in the chat's text and its site muted after it, on a
    /// soft rounded highlight while it's chosen.
    final class Row: FlippedView {
        /// The favicon's and the text's distance from the row's left.
        static let inset: CGFloat = 10, textX: CGFloat = 36
        static let titleFont = AIChatStyle.font(14), siteFont = AIChatStyle.font(12.5)
        let page: AIChatAttachment
        private let icon = NSImageView(), title = NSTextField(labelWithString: "")
        private let highlight = CALayer()
        private var colors = AIChatColors(.neutral)
        var isChosen = false { didSet { if isChosen != oldValue { update() } } }
        init(_ page: AIChatAttachment) {
            self.page = page
            super.init(frame: .zero)
            wantsLayer = true
            highlight.cornerRadius = AIChatMentionMenu.rowRadius; highlight.cornerCurve = .continuous
            highlight.actions = ["backgroundColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(highlight)
            icon.imageScaling = .scaleProportionallyUpOrDown
            title.lineBreakMode = .byTruncatingTail; title.cell?.truncatesLastVisibleLine = true
            [icon, title].forEach(addSubview)
            setAccessibilityElement(true); setAccessibilityRole(.menuItem); setAccessibilityLabel(AIChatQuestionPart.title(of: page))
            update()
        }
        required init?(coder: NSCoder) { fatalError() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        /// How wide the row would like to be: its favicon, title and site, with room after.
        static func width(of page: AIChatAttachment) -> CGFloat {
            let title = (AIChatQuestionPart.title(of: page) as NSString).size(withAttributes: [.font: titleFont]).width
            let site = page.title.isEmpty ? 0 : (page.subtitle as NSString).size(withAttributes: [.font: siteFont]).width+8
            return textX+ceil(title+site)+14
        }
        func applyColors(_ colors: AIChatColors) { self.colors = colors; update() }
        private func update() {
            highlight.backgroundColor = isChosen ? (colors.dark ? NSColor.white.withAlphaComponent(0.08) : NSColor.black.withAlphaComponent(0.05)).cgColor : nil
            let text = NSMutableAttributedString(string: AIChatQuestionPart.title(of: page), attributes: [.font: Self.titleFont, .foregroundColor: colors.text])
            if !page.title.isEmpty, !page.subtitle.isEmpty {
                text.append(NSAttributedString(string: "  "+page.subtitle, attributes: [.font: Self.siteFont, .foregroundColor: colors.muted]))
            }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            title.attributedStringValue = text
            if let favicon = page.favicon {
                icon.image = favicon; icon.contentTintColor = nil
            } else {
                icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
                icon.contentTintColor = colors.muted
            }
            setAccessibilitySelected(isChosen)
        }
        override func layout() {
            super.layout()
            highlight.frame = bounds
            icon.frame = NSRect(x: Self.inset, y: (bounds.height-AIChatMentionMenu.iconSize)/2, width: AIChatMentionMenu.iconSize, height: AIChatMentionMenu.iconSize)
            let line = ceil(title.intrinsicContentSize.height)
            // A label's own 2 pt inset would put its text right of where it's placed.
            title.frame = NSRect(x: Self.textX-2, y: (bounds.height-line)/2, width: max(0, bounds.width-Self.textX-8), height: line)
        }
    }
}

extension AIChatAttachment {
    /// Open pages to mention for `query`, typed after @: the best matches by title, then address.
    static func mentionable(_ pages: [AIChatAttachment], query: String) -> [AIChatAttachment] {
        FuzzyMatch.ranked(pages, query: query) { [AIChatQuestionPart.title(of: $0), $0.subtitle] }
    }
}
