import AppKit
import RiseCore

struct AddressSuggestion {
    let title: String
    let subtitle: String
    let symbol: String
    let url: URL?
    let tabID: UUID?
    let command: String?
    var favicon: NSImage? = nil
    var completion: String? = nil
    var fetchFavicon = true
}
@MainActor final class AddressPalette: Surface, NSTextFieldDelegate {
    let input = NSTextField()
    let leadingIcon = NSImageView()
    var suggestions: [AddressSuggestion] = []
    var buttons: [NSButton] = []
    var selectedIndex = 0
    var queryChanged: ((String) -> [AddressSuggestion])?
    var submit: ((String, AddressSuggestion?) -> Void)?
    var dismiss: (() -> Void)?
    var theme: RiseTheme = .neutral
    private var completionRange: NSRange?
    private var completionPrefix = ""
    private var suppressCompletion = false
    private var applyingCompletion = false
    private var restingFrame = NSRect(x: 8, y: 50, width: 350, height: 110)
    var isPresented: Bool { !isHidden }
    init() {
        super.init(color: NSColor(hex: 0xF8F8F8), radius: 12)
        layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor; layer?.borderWidth = 0.5
        shadow = chromeShadow(opacity: 0.22, blur: 24, offset: -8)
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.font = .systemFont(ofSize: 13, weight: .medium); input.textColor = NSColor(hex: 0x3D3D3D)
        input.placeholderString = "Search or Enter URL…"; input.delegate = self
        input.setAccessibilityLabel("Address or search")
        leadingIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        leadingIcon.contentTintColor = .secondaryLabelColor
        addSubview(input); addSubview(leadingIcon)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(text: String, theme: RiseTheme) {
        completionRange = nil; suppressCompletion = false
        applyTheme(theme); isHidden = false; alphaValue = 1; input.stringValue = text
        refresh(); window?.makeFirstResponder(input); input.selectText(nil)
    }
    func applyTheme(_ theme: RiseTheme) {
        self.theme = theme; fill = theme.popup
        layer?.borderColor = theme.border.cgColor
        shadow = chromeShadow(opacity: theme == .dark ? 0.4 : 0.22, blur: 24, offset: -8)
        input.textColor = theme.text
        input.placeholderAttributedString = NSAttributedString(string: "Search or Enter URL…", attributes: [.foregroundColor: theme.muted, .font: input.font!])
        leadingIcon.contentTintColor = theme.muted
    }
    func place(at origin: NSPoint, width: CGFloat) {
        restingFrame.origin = origin; restingFrame.size.width = width
        applyPresentation()
    }
    func hide() { isHidden = true; completionRange = nil }
    private func applyPresentation() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = restingFrame
        CATransaction.commit()
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func refresh(query: String? = nil) {
        suggestions = queryChanged?(query ?? input.stringValue) ?? []; selectedIndex = 0
        render()
    }
    func render() {
        buttons.forEach { $0.removeFromSuperview() }; buttons = []
        for (index, suggestion) in suggestions.enumerated() {
            let button = NSButton(); button.title = ""; button.isBordered = false
            button.wantsLayer = true; button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = (index == selectedIndex ? theme.menuSelection : .clear).cgColor
            button.tag = index; button.target = self; button.action = #selector(choose(_:))
            button.setAccessibilityLabel(suggestion.title)
            let imageView = FaviconView(frame: .zero)
            imageView.image = suggestion.favicon ?? NSImage(systemSymbolName: suggestion.symbol, accessibilityDescription: nil)
            imageView.contentTintColor = suggestion.favicon == nil ? (index == selectedIndex ? .white : theme.muted) : nil
            let text = label(suggestion.title, size: 13, weight: .medium, color: index == selectedIndex ? .white : theme.text)
            button.addSubview(imageView); button.addSubview(text)
            addSubview(button); buttons.append(button)
        }
        restingFrame.size.height = 52 + CGFloat(max(1, suggestions.count))*50 + 8
        applyPresentation()
    }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)
        leadingIcon.frame = NSRect(x: 24, y: (52-17)/2, width: 17, height: 17)
        let inputHeight = input.intrinsicContentSize.height
        input.frame = NSRect(x: 52, y: (52-inputHeight)/2, width: bounds.width-72, height: inputHeight)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: 10, y: 52+CGFloat(i)*50, width: bounds.width-20, height: 46)
            if let icon = button.subviews.first as? NSImageView {
                icon.frame = NSRect(x: 14, y: (button.bounds.height-17)/2, width: 17, height: 17)
            }
            if let text = button.subviews.last as? NSTextField {
                let height = text.intrinsicContentSize.height
                text.frame = NSRect(x: 42, y: (button.bounds.height-height)/2, width: max(0, button.bounds.width-52), height: height)
            }
        }
    }
    func updateFavicon(_ image: NSImage, origin: String) {
        for index in suggestions.indices where SitePermissions.origin(suggestions[index].url) == origin && suggestions[index].symbol == "globe" {
            suggestions[index].favicon = image
            guard buttons.indices.contains(index), let icon = buttons[index].subviews.first as? NSImageView else { continue }
            icon.image = image; icon.contentTintColor = nil
        }
    }
    func removeInlineCompletion() {
        if let editor = input.currentEditor() as? NSTextView, let range = completionRange, editor.selectedRange() == range {
            editor.string = completionPrefix; input.stringValue = completionPrefix
            editor.setSelectedRange(NSRange(location: completionPrefix.utf16.count, length: 0))
        }
        completionRange = nil
    }
    func controlTextDidChange(_ obj: Notification) {
        guard !applyingCompletion else { return }
        completionRange = nil
        let editor = input.currentEditor() as? NSTextView
        let typed = editor?.string ?? input.stringValue
        if editor?.hasMarkedText() == true { refresh(query: typed); return }
        input.stringValue = typed; refresh()
        let suppressed = suppressCompletion; suppressCompletion = false
        guard !suppressed, let editor, !editor.hasMarkedText(),
              editor.selectedRange() == NSRange(location: typed.utf16.count, length: 0),
              let completed = suggestions.first?.completion, completed.hasPrefix(typed), completed != typed else { return }
        applyingCompletion = true
        let range = NSRange(location: typed.utf16.count, length: completed.utf16.count-typed.utf16.count)
        editor.string = completed; input.stringValue = completed; editor.setSelectedRange(range)
        completionPrefix = typed; completionRange = range
        applyingCompletion = false
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): chooseSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss?(); return true
        case #selector(NSResponder.moveDown(_:)): removeInlineCompletion(); selectedIndex = max(0, min(suggestions.count-1, selectedIndex+1)); render(); return true
        case #selector(NSResponder.moveUp(_:)): removeInlineCompletion(); selectedIndex = max(0, selectedIndex-1); render(); return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)):
            suppressCompletion = true; completionRange = nil; return false
        default: return false
        }
    }
    @objc func choose(_ sender: NSButton) { selectedIndex = sender.tag; chooseSelected() }
    func chooseSelected() {
        guard isPresented else { return }
        submit?(input.stringValue, suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil)
    }
}

final class DismissView: FlippedView {
    var dismiss: (() -> Void)?
    override func mouseDown(with event: NSEvent) { dismiss?() }
}
