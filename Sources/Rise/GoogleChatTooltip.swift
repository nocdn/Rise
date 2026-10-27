import AppKit

/// Chat's card: between Gmail's and Calendar's in size.
typealias GoogleChatTooltip = ListCard<ChatConversationRow>

/// A conversation: its name and when it last moved, then its last message in as many lines as
/// it takes, up to three. An unread one has a bolder name and a blue dot.
final class ChatConversationRow: NSButton, CardListRow {
    static let inset: CGFloat = 14
    static var cardWidth: CGFloat { 312 }
    static var cardMaximumHeight: CGFloat { 334 }
    static var loadingText: String { "Loading messages" }
    static var loadingMoreText: String { "Loading more messages" }
    static var emptyText: String { "No direct messages" }
    static let top: CGFloat = 10, bottom: CGFloat = 10, gap: CGFloat = 4, lines = 3
    static let dot: CGFloat = 8, dotGap: CGFloat = 8
    static let unreadColor = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.91, alpha: 1)
    let item: ChatConversation
    let name = NSTextField(labelWithString: "")
    let time = NSTextField(labelWithString: "")
    let message = NSTextField(wrappingLabelWithString: "")
    let unreadDot = Surface()
    private let divider = Surface()
    var onOpen: (() -> Void)?
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var theme = RiseTheme.neutral
    override var isFlipped: Bool { true }
    init(_ item: ChatConversation) {
        self.item = item
        super.init(frame: .zero)
        title = ""; isBordered = false; target = self; action = #selector(openConversation)
        name.stringValue = item.name; name.font = .systemFont(ofSize: 14, weight: item.unread ? .medium : .regular)
        name.lineBreakMode = .byTruncatingTail; name.maximumNumberOfLines = 1
        let when = ChatConversation.timeLabel(item.date)
        time.stringValue = when; time.font = .systemFont(ofSize: 12); time.alignment = .right
        message.stringValue = item.message; message.font = .systemFont(ofSize: 12)
        message.maximumNumberOfLines = Self.lines; message.cell?.truncatesLastVisibleLine = true
        unreadDot.fill = Self.unreadColor; unreadDot.layer?.cornerRadius = Self.dot/2; unreadDot.isHidden = !item.unread
        [name, time, message, unreadDot, divider].forEach(addSubview)
        setAccessibilityLabel((item.unread ? "Unread, " : "")+item.name+", "+when)
        setAccessibilityValue(item.message)
    }
    required init?(coder: NSCoder) { fatalError() }
    func applyTheme(_ theme: RiseTheme, last: Bool) {
        self.theme = theme
        name.textColor = item.unread ? theme.text : theme.text.withAlphaComponent(0.82)
        time.textColor = theme.text.withAlphaComponent(0.5)
        message.textColor = theme.text.withAlphaComponent(0.65)
        divider.fill = theme.text.withAlphaComponent(0.12); divider.isHidden = last
        needsDisplay = true
    }
    private static func lineHeight(_ field: NSTextField) -> CGFloat { ceil(NSLayoutManager().defaultLineHeight(for: field.font!)) }
    /// The message's width leaves room for the dot.
    private func messageWidth(_ width: CGFloat) -> CGFloat {
        width-2*(Self.inset-2)-(item.unread ? Self.dot+Self.dotGap : 0)
    }
    private func messageHeight(width: CGFloat) -> CGFloat {
        guard !item.message.isEmpty else { return 0 }
        let line = Self.lineHeight(message)
        let needed = ceil(message.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: messageWidth(width), height: 1000)).height ?? line)
        return min(line*CGFloat(Self.lines), needed)
    }
    func fittingHeight(width: CGFloat) -> CGFloat {
        let text = messageHeight(width: width)
        return Self.top+Self.lineHeight(name)+(text > 0 ? Self.gap+text : 0)+Self.bottom
    }
    override func layout() {
        super.layout()
        let x = Self.inset-2, width = bounds.width-2*x
        let timeWidth = ceil(time.attributedStringValue.size().width)+4
        time.frame = NSRect(x: bounds.width-x-timeWidth, y: Self.top+2, width: timeWidth, height: Self.lineHeight(time))
        name.frame = NSRect(x: x, y: Self.top, width: max(0, width-timeWidth-8), height: Self.lineHeight(name))
        let text = messageHeight(width: bounds.width)
        message.isHidden = text == 0
        message.frame = NSRect(x: x, y: name.frame.maxY+Self.gap, width: messageWidth(bounds.width), height: text)
        // Level with the message's middle, or the name's without one.
        let middle = text > 0 ? message.frame.midY : name.frame.midY
        unreadDot.frame = NSRect(x: bounds.width-Self.inset-Self.dot, y: middle-Self.dot/2, width: Self.dot, height: Self.dot)
        divider.frame = NSRect(x: 0, y: bounds.height-0.5, width: bounds.width, height: 0.5)
    }
    override func draw(_ dirtyRect: NSRect) {
        if isHovered { theme.text.withAlphaComponent(0.04).setFill(); bounds.fill() }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    @objc private func openConversation() { onOpen?() }
}
