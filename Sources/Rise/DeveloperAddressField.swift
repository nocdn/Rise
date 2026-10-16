import AppKit

/// Updates from the page must never replace an address while the user edits it.
final class DeveloperAddressField: FadingTextField, NSTextFieldDelegate {
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
