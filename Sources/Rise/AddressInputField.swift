import AppKit
import QuartzCore

/// Keep the native field editor's horizontal scrolling, fading only text that
/// continues beyond the right edge rather than truncating the stored value.
final class AddressInputField: NSTextField {
    // Its own field editor, as the find bar's, so its selection (an autofilled address
    // included) can be a quiet gray without restyling every other field's.
    override class var cellClass: AnyClass? { get { AddressInputCell.self } set {} }
    var selectionColor: NSColor {
        get { (cell as? AddressInputCell)?.selectionColor ?? .selectedTextBackgroundColor }
        set { (cell as? AddressInputCell)?.selectionColor = newValue }
    }
    private let fade = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        cell?.usesSingleLineMode = true; cell?.wraps = false; cell?.isScrollable = true
        maximumNumberOfLines = 1; lineBreakMode = .byClipping
        wantsLayer = true; clipsToBounds = true
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        NotificationCenter.default.addObserver(self, selector: #selector(editorChanged(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(editorChanged(_:)), name: NSView.boundsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    override var stringValue: String {
        get { super.stringValue }
        set { super.stringValue = newValue; needsLayout = true }
    }
    @objc private func editorChanged(_ note: Notification) {
        guard let editor = currentEditor() as? NSTextView,
              note.object as? NSTextView === editor || note.object as? NSView === editor.superview else { return }
        updateFade()
    }
    override func layout() {
        super.layout()
        (currentEditor() as? AddressFieldEditor)?.revealTypedPrefix()
        updateFade()
    }
    func anchorInlineCompletion(_ range: NSRange) {
        (currentEditor() as? AddressFieldEditor)?.anchorCompletion(range)
    }
    func updateFade() {
        var overflowing = attributedStringValue.size().width > bounds.width-2
        if let editor = currentEditor() as? NSTextView, let manager = editor.layoutManager, let container = editor.textContainer {
            manager.ensureLayout(for: container)
            let right = manager.usedRect(for: container).maxX + editor.textContainerOrigin.x
            overflowing = right > editor.visibleRect.maxX + 1
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.locations = [0, NSNumber(value: Double(max(0, bounds.width-18)/max(1, bounds.width))), 1]
        layer?.mask = overflowing ? fade : nil
        CATransaction.commit()
    }
}

/// AppKit restyles a field editor each time editing starts, selection color included, so the
/// gray goes back on after that.
final class AddressInputCell: FindInputCell {
    override func makeEditor() -> NSTextView { AddressFieldEditor(usingTextLayoutManager: false) }
    var selectionColor = NSColor.selectedTextBackgroundColor {
        didSet { editor.selectedTextAttributes = [.backgroundColor: selectionColor] }
    }
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        (text as? NSTextView)?.selectedTextAttributes = [.backgroundColor: selectionColor]
        return text
    }
}

/// A selected completion can extend far past the field. AppKit normally scrolls
/// to its far end after insertion; keep the user's prefix in view instead. Once
/// they accept it or move the caret, ordinary native horizontal scrolling resumes.
final class AddressFieldEditor: NSTextView {
    private var completion: (text: String, suffix: NSRange)?
    func anchorCompletion(_ suffix: NSRange) {
        completion = (string, suffix)
        revealTypedPrefix()
    }
    private var activeSuffix: NSRange? {
        guard let completion, completion.text == string, selectedRange() == completion.suffix else { return nil }
        return completion.suffix
    }
    func revealTypedPrefix() {
        guard let suffix = activeSuffix else { return }
        scrollRangeToVisible(NSRange(location: suffix.location, length: 0))
    }
    override func scrollRangeToVisible(_ range: NSRange) {
        guard let suffix = activeSuffix, let manager = layoutManager, let container = textContainer else {
            super.scrollRangeToVisible(range); return
        }
        let prefix = NSRange(location: 0, length: suffix.location)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: prefix, actualCharacterRange: nil)
        let width = manager.boundingRect(forGlyphRange: glyphs, in: container).width
        let fits = width+2*textContainerOrigin.x+8 < visibleRect.width
        super.scrollRangeToVisible(fits ? prefix : NSRange(location: suffix.location, length: 0))
    }
}
