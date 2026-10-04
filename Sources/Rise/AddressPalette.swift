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
    let input = AddressInputField(frame: .zero)
    let leadingIcon = NSImageView()
    var suggestions: [AddressSuggestion] = []
    var buttons: [NSButton] = []
    var selectedIndex = 0
    private(set) var query = ""
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
        super.init(color: NSColor(hex: 0xF8F8F8), radius: AddressAppearance.cornerRadius)
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor; layer?.borderWidth = 0.5
        shadow = chromeShadow(opacity: 0.22, blur: 24, offset: -8)
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.font = .systemFont(ofSize: 13, weight: AddressAppearance.textWeight); input.textColor = NSColor(hex: 0x3D3D3D)
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
        self.theme = theme; fill = AddressAppearance.background(theme)
        layer?.borderColor = theme.border.cgColor
        shadow = chromeShadow(opacity: theme == .dark ? 0.4 : 0.22, blur: 24, offset: -8)
        input.textColor = AddressAppearance.textColor(theme)
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
        self.query = query ?? input.stringValue
        suggestions = queryChanged?(self.query) ?? []; selectedIndex = 0
        render()
    }
    func replaceSuggestions(_ updated: [AddressSuggestion]) {
        let selected = suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
        suggestions = updated
        if let selected {
            func matches(_ value: AddressSuggestion) -> Bool {
                value.url == selected.url && value.tabID == selected.tabID && value.command == selected.command && value.title == selected.title
            }
            if selectedIndex > 0, !suggestions.contains(where: matches) {
                if suggestions.count >= AddressAppearance.maximumSuggestions { suggestions.removeLast() }
                suggestions.append(selected)
            }
            selectedIndex = suggestions.firstIndex(where: matches) ?? 0
        } else { selectedIndex = 0 }
        render()
    }
    func render() {
        buttons.forEach { $0.removeFromSuperview() }; buttons = []
        for (index, suggestion) in suggestions.enumerated() {
            let button = NSButton(); button.title = ""; button.isBordered = false
            button.wantsLayer = true; button.layer?.cornerRadius = 6; button.layer?.cornerCurve = .continuous
            button.layer?.backgroundColor = (index == selectedIndex ? AddressAppearance.selection(theme) : .clear).cgColor
            button.tag = index; button.target = self; button.action = #selector(choose(_:))
            button.setAccessibilityLabel(suggestion.title)
            let imageView = FaviconView(frame: .zero)
            imageView.image = suggestion.favicon ?? NSImage(systemSymbolName: suggestion.symbol, accessibilityDescription: nil)
            imageView.contentTintColor = suggestion.favicon == nil ? theme.muted : nil
            let text = label(suggestion.title, size: 13, weight: AddressAppearance.textWeight, color: AddressAppearance.textColor(theme))
            if suggestion.symbol == "globe", suggestion.fetchFavicon, !suggestion.subtitle.isEmpty,
               suggestion.title != suggestion.subtitle {
                let address = suggestion.subtitle.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                let title = NSMutableAttributedString(string: suggestion.title, attributes: [.font: text.font!, .foregroundColor: text.textColor!])
                title.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 13), .kern: 3]))
                title.append(NSAttributedString(string: address, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: theme.muted]))
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
                text.attributedStringValue = title
            }
            button.addSubview(imageView); button.addSubview(text)
            addSubview(button); buttons.append(button)
        }
        let count = CGFloat(suggestions.count)
        restingFrame.size.height = AddressAppearance.headerHeight + count*AddressAppearance.rowHeight + max(0, count-1)*AddressAppearance.rowSpacing + AddressAppearance.inset
        updateSelection()
        applyPresentation()
    }
    func selectResult(_ index: Int) {
        guard isPresented, suggestions.indices.contains(index) else { return }
        removeInlineCompletion()
        guard selectedIndex != index else { return }
        selectedIndex = index
        updateSelection()
    }
    private func updateSelection() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedIndex
            button.layer?.backgroundColor = (selected ? AddressAppearance.selection(theme) : .clear).cgColor
            guard suggestions.indices.contains(index), let text = button.subviews.last as? NSTextField else { continue }
            let title = NSMutableAttributedString(attributedString: text.attributedStringValue)
            let range = NSRange(location: 0, length: min(title.length, suggestions[index].title.utf16.count))
            title.addAttribute(.foregroundColor, value: AddressAppearance.textColor(theme), range: range)
            text.attributedStringValue = title
        }
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = buttons.firstIndex(where: { $0.frame.contains(point) }) { selectResult(index) }
    }
    // Padding belongs to the popup. Do not forward its clicks down the
    // responder chain to the outside-click dismissal surface.
    override func mouseDown(with event: NSEvent) {}
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor, bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }
    override func layout() {
        super.layout()
        // Derive the shadow from the layer's continuous corners as well.
        layer?.shadowPath = nil
        leadingIcon.frame = NSRect(x: AddressAppearance.inset+10, y: (AddressAppearance.headerHeight-16)/2, width: 16, height: 16)
        let inputHeight = input.intrinsicContentSize.height
        input.frame = NSRect(x: AddressAppearance.inset+36, y: (AddressAppearance.headerHeight-inputHeight)/2, width: bounds.width-AddressAppearance.inset-52, height: inputHeight)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: AddressAppearance.inset, y: AddressAppearance.headerHeight+CGFloat(i)*(AddressAppearance.rowHeight+AddressAppearance.rowSpacing), width: bounds.width-2*AddressAppearance.inset, height: AddressAppearance.rowHeight)
            if let icon = button.subviews.first as? NSImageView {
                icon.frame = NSRect(x: 10, y: (button.bounds.height-16)/2, width: 16, height: 16)
            }
            if let text = button.subviews.last as? NSTextField {
                let height = text.intrinsicContentSize.height
                text.frame = NSRect(x: 36, y: (button.bounds.height-height)/2, width: max(0, button.bounds.width-46), height: height)
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
    func controlTextDidBeginEditing(_ obj: Notification) { input.updateFade() }
    func controlTextDidEndEditing(_ obj: Notification) { input.needsLayout = true }
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
        case #selector(NSResponder.moveDown(_:)): selectResult(min(suggestions.count-1, selectedIndex+1)); return true
        case #selector(NSResponder.moveUp(_:)): selectResult(max(0, selectedIndex-1)); return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)):
            suppressCompletion = true; completionRange = nil; return false
        default: return false
        }
    }
    @objc func choose(_ sender: NSButton) { selectResult(sender.tag); chooseSelected() }
    func chooseSelected() {
        guard isPresented else { return }
        submit?(input.stringValue, suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil)
    }
}

final class DismissView: FlippedView {
    var dismiss: (() -> Void)?
    weak var protectedView: NSView?
    override func mouseDown(with event: NSEvent) {
        if let view = protectedView, !view.isHiddenOrHasHiddenAncestor,
           view.bounds.contains(view.convert(event.locationInWindow, from: nil)) { return }
        dismiss?()
    }
}
