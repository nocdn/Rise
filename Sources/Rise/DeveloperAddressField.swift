import AppKit

/// Updates from the page must never replace an address while the user edits it.
final class DeveloperAddressField: FadingTextField, NSTextFieldDelegate {
    override class var cellClass: AnyClass? { get { DeveloperAddressCell.self } set {} }
    private(set) var displayedURL = ""
    private(set) var isEditingAddress = false
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = true; isSelectable = true; focusRingType = .none
        delegate = self
        setAccessibilityLabel("Developer address")
        toolTip = "Edit address; Return to navigate, Escape to cancel"
    }
    required init?(coder: NSCoder) { fatalError() }

    func updateURL(_ value: String) {
        displayedURL = value
        if currentEditor() == nil && !isEditingAddress { stringValue = value }
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        isEditingAddress = true; layer?.mask = nil
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        isEditingAddress = false; stringValue = displayedURL; needsLayout = true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let value = textView.string
            window?.makeFirstResponder(nil)
            onSubmit?(value)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            textView.string = displayedURL; stringValue = displayedURL
            window?.makeFirstResponder(nil)
            onCancel?()
            return true
        default: return false
        }
    }
}

/// The address on one line in the middle of the field, which is as tall as the bar so no tail is
/// cut off; its capitals centred, as the page bar's are, so the two share a baseline, rather than
/// its line, which has room above for accents. It's drawn with TextKit 1 as the field
/// editor lays it out, and editing puts the editor's baseline on the drawn one, so a click to
/// edit doesn't move it: AppKit's editing otherwise sets its line a point lower.
final class DeveloperAddressCell: FindInputCell {
    /// The baseline where the capitals' middle is the field's, on a whole pixel. A notice in the
    /// address's place sits on it too (`BarNotice`), so nothing hops as the two change places.
    static func baseline(of font: NSFont, middle: CGFloat) -> CGFloat { ceil((middle+font.capHeight/2)*2)/2 }
    private func line(in rect: NSRect) -> NSRect {
        var line = super.drawingRect(forBounds: rect)
        guard let font else { return line }
        let manager = NSLayoutManager()
        line.origin.y = Self.baseline(of: font, middle: rect.midY)-manager.defaultBaselineOffset(for: font)
        line.size.height = manager.defaultLineHeight(for: font)
        return line
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { line(in: rect) }
    /// Lays the address out as its field editor does: TextKit 1, with a field editor's padding.
    private let drawer: NSTextView = {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isFieldEditor = true; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 2
        view.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        return view
    }()
    /// Where the drawn address's baseline is in the field.
    private func drawnBaseline(in rect: NSRect) -> CGFloat? {
        guard let manager = drawer.layoutManager, manager.numberOfGlyphs > 0 else { return nil }
        return line(in: rect).minY+manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY+manager.location(forGlyphAt: 0).y
    }
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if (controlView as? NSTextField)?.currentEditor() != nil { return }
        guard let manager = drawer.layoutManager, let container = drawer.textContainer else { return }
        drawer.textStorage?.setAttributedString(attributedStringValue)
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: line(in: cellFrame).origin)
    }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: line(in: rect), in: controlView, editor: textObj, delegate: delegate, event: event)
        align(textObj, in: controlView, bounds: rect)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: line(in: rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
        align(textObj, in: controlView, bounds: rect)
    }
    /// Moves the editor so its baseline is the drawn address's.
    private func align(_ text: NSText, in controlView: NSView, bounds: NSRect) {
        drawer.textStorage?.setAttributedString(attributedStringValue)
        guard let editor = text as? NSTextView, let holder = editor.superview, let drawn = drawnBaseline(in: bounds),
              let manager = editor.layoutManager, let container = editor.textContainer, manager.numberOfGlyphs > 0 else { return }
        manager.ensureLayout(for: container)
        let baseline = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY+manager.location(forGlyphAt: 0).y+editor.textContainerOrigin.y
        // The clip view AppKit holds it in is moved: it would scroll back a moved editor.
        guard let clip = holder.superview else { return }
        let live = editor.convert(NSPoint(x: 0, y: baseline), to: clip), target = controlView.convert(NSPoint(x: 0, y: drawn), to: clip)
        holder.frame.origin.y += target.y-live.y
    }
}
