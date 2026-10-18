import AppKit
import RiseCore

struct AddressSuggestion {
    let title: String
    let subtitle: String
    let symbol: String
    let url: URL?
    var tabID: UUID?
    let command: String?
    var favicon: NSImage? = nil
    var completion: String? = nil
    var fetchFavicon = true
    /// Stands for the typed text itself (its address, its search, or its completion), so Enter
    /// opens it when no row has been picked.
    var isTypedAction = false
    /// Fills in the field (a well-known site) without a row of its own: the field already shows it.
    var isAutofill = false
}
@MainActor final class AddressPalette: Surface, NSTextFieldDelegate {
    let input = AddressInputField(frame: .zero)
    let leadingIcon = NSImageView()
    var suggestions: [AddressSuggestion] = []
    var buttons: [NSButton] = []
    /// The row picked with the pointer or the arrow keys, highlighted; -1 for none, when Enter
    /// opens what's typed.
    var selectedIndex = -1
    /// The selection from before the pointer took it over, which it goes back to once the pointer
    /// leaves the results; the arrow keys make their own choice the one to go back to.
    private var selectionBeforeHover: Int?
    /// The current page's address and icon; while the field still holds that address, the icon
    /// stands in for the magnifying glass.
    var currentPage: (address: String, favicon: NSImage?)?
    private(set) var query = ""
    private var placementCenter: NSPoint?
    var queryChanged: ((String) -> [AddressSuggestion])?
    var submit: ((String, AddressSuggestion?) -> Void)?
    var switchToTab: ((UUID) -> Void)?
    var dismiss: (() -> Void)?
    var theme: RiseTheme = .neutral
    private var completionRange: NSRange?
    private var completionPrefix = ""
    private var suppressCompletion = false
    private var applyingCompletion = false
    private var restingFrame = NSRect(x: 8, y: 50, width: 350, height: 110)
    /// "Search Amazon" and a Tab key at the end of the address, while it's a site with its own search.
    let siteHint = SiteSearchHint()
    private(set) var offeredSite: PopularSite?
    /// Searching a site, after Tab: the hint at the end names it, in its colour, and the field
    /// keeps the address, selected, to type the search over.
    private(set) var siteSearch: PopularSite?
    /// A site's icon, from what's been loaded for the address suggestions.
    var siteFavicon: ((URL) -> NSImage?)?
    /// A site whose search was learned from searching on it.
    var learnedSite: ((String) -> PopularSite?)?
    /// A site set up by hand in Settings, which comes first.
    var customSite: ((String) -> PopularSite?)?
    /// The site the field fills in, behind the rows rather than among them.
    private(set) var autofill: AddressSuggestion?
    /// Everything the address showed before Tab, to step straight back to.
    private struct AddressState {
        let text: String, query: String, selection: NSRange, completionRange: NSRange?, completionPrefix: String
        let suggestions: [AddressSuggestion], autofill: AddressSuggestion?
    }
    private var addressBeforeSiteSearch: AddressState?
    var isPresented: Bool { !isHidden }
    private var createsTab = false
    private var headerHeight: CGFloat { createsTab ? AddressAppearance.newTabHeaderHeight : AddressAppearance.headerHeight }
    init() {
        super.init(color: NSColor(hex: 0xF8F8F8), radius: AddressAppearance.cornerRadius)
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor; layer?.borderWidth = 0.5
        shadow = chromeShadow(opacity: 0.22, blur: 24, offset: -8)
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.font = .systemFont(ofSize: AddressAppearance.textSize, weight: AddressAppearance.textWeight); input.textColor = NSColor(hex: 0x3D3D3D)
        input.placeholderString = "Search or Enter URL…"; input.delegate = self
        input.setAccessibilityLabel("Address or search")
        leadingIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        leadingIcon.contentTintColor = .secondaryLabelColor
        siteHint.alphaValue = 0; siteHint.setAccessibilityElement(false)
        addSubview(input); addSubview(leadingIcon); addSubview(siteHint)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(text: String, theme: RiseTheme, createsTab: Bool = false) {
        self.createsTab = createsTab
        completionRange = nil; suppressCompletion = false
        resetSiteSearch()
        applyTheme(theme); isHidden = false; alphaValue = 1; input.stringValue = text
        refresh(); window?.makeFirstResponder(input); input.selectText(nil)
    }
    func applyTheme(_ theme: RiseTheme) {
        self.theme = theme; fill = AddressAppearance.background(theme)
        layer?.borderColor = theme.border.cgColor
        shadow = chromeShadow(opacity: theme == .dark ? 0.4 : 0.22, blur: 24, offset: -8)
        input.textColor = AddressAppearance.textColor(theme)
        input.selectionColor = AddressAppearance.textSelection(theme)
        applyPlaceholder()
        updateLeadingIcon()
        if let site = siteSearch ?? offeredSite { siteHint.applyTheme(theme, siteColor: color(for: site)) }
    }
    func place(at origin: NSPoint, width: CGFloat) {
        placementCenter = nil
        restingFrame.origin = origin; restingFrame.size.width = width
        applyPresentation()
    }
    func place(centeredAt center: NSPoint, width: CGFloat) {
        placementCenter = center; restingFrame.size.width = width
        applyPresentation()
    }
    func hide() { isHidden = true; completionRange = nil; selectionBeforeHover = nil; resetSiteSearch() }
    private func applyPresentation() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let center = placementCenter {
            restingFrame.origin = NSPoint(x: center.x-restingFrame.width/2, y: center.y-restingFrame.height/2)
        }
        frame = restingFrame
        CATransaction.commit()
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    func refresh(query: String? = nil) {
        self.query = query ?? input.stringValue
        suggestions = takeAutofill(queryChanged?(self.query) ?? []); selectedIndex = -1; selectionBeforeHover = nil
        render()
        updateOffer(); updateLeadingIcon()
    }
    private func takeAutofill(_ list: [AddressSuggestion]) -> [AddressSuggestion] {
        autofill = list.first { $0.isAutofill }
        return list.filter { !$0.isAutofill }
    }
    /// The site the field holds, or is filling in, or is searching: its icon leads the field.
    private var fieldSite: PopularSite? { siteSearch ?? site(forAddress: input.stringValue) }
    /// A well-known site Rise searches itself, or else one whose search it learned.
    private func site(forAddress text: String) -> PopularSite? {
        // A learned path can fill the field while the person is still typing its host.
        // Keep the site's search available until they actually type into that path.
        let address = completionRange.flatMap { _ in (autofill ?? suggestions.first)?.url }
            .flatMap { BrowsingHistory.completion(for: completionPrefix, url: $0) } ?? text
        if let custom = customSite?(address) { return custom }
        let popular = PopularSites.site(forAddress: address)
        if popular?.isSearchable == true { return popular }
        return learnedSite?(address) ?? popular
    }
    private func updateLeadingIcon() {
        let address = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let site = fieldSite, let favicon = siteFavicon?(site.homeURL) {
            leadingIcon.image = favicon; leadingIcon.contentTintColor = nil
        } else if siteSearch != nil {
            leadingIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil); leadingIcon.contentTintColor = theme.muted
        } else if completionRange != nil, let favicon = suggestions.first?.favicon {
            // A visited page filling in shows its icon too.
            leadingIcon.image = favicon; leadingIcon.contentTintColor = nil
        } else if let page = currentPage, !createsTab, !address.isEmpty, address == page.address, let favicon = page.favicon {
            leadingIcon.image = favicon; leadingIcon.contentTintColor = nil
        } else {
            leadingIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil); leadingIcon.contentTintColor = theme.muted
        }
    }
    func replaceSuggestions(_ updated: [AddressSuggestion]) {
        // Late results for the address don't belong to a site's search.
        guard siteSearch == nil else { return }
        let selected = suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
        suggestions = takeAutofill(updated)
        if let selected {
            func matches(_ value: AddressSuggestion) -> Bool {
                value.url == selected.url && value.tabID == selected.tabID && value.command == selected.command && value.title == selected.title
            }
            if !suggestions.contains(where: matches) {
                if suggestions.count >= AddressAppearance.maximumSuggestions { suggestions.removeLast() }
                suggestions.append(selected)
            }
            selectedIndex = suggestions.firstIndex(where: matches) ?? -1
        } else { selectedIndex = -1 }
        if let previous = selectionBeforeHover { selectionBeforeHover = min(previous, max(0, suggestions.count-1)) }
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
            if suggestion.tabID != nil {
                button.setAccessibilityHelp("Open existing tab")
            }
            let imageView = FaviconView(frame: .zero)
            imageView.image = suggestion.command == "Change Theme"
                ? TablerIcon.themeImage(size: 16)
                : suggestion.favicon ?? NSImage(systemSymbolName: suggestion.symbol, accessibilityDescription: nil)
            imageView.contentTintColor = suggestion.favicon == nil ? theme.muted : nil
            let text = label(suggestion.title, size: AddressAppearance.textSize, weight: AddressAppearance.textWeight, color: AddressAppearance.textColor(theme))
            if suggestion.symbol == "globe", suggestion.fetchFavicon, !suggestion.subtitle.isEmpty,
               suggestion.title != suggestion.subtitle {
                let address = suggestion.subtitle.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                let title = NSMutableAttributedString(string: suggestion.title, attributes: [.font: text.font!, .foregroundColor: text.textColor!])
                title.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: AddressAppearance.textSize), .kern: 3]))
                title.append(NSAttributedString(string: address, attributes: [.font: NSFont.systemFont(ofSize: AddressAppearance.textSize), .foregroundColor: theme.muted]))
                let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
                title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
                text.attributedStringValue = title
            }
            button.addSubview(imageView, positioned: .below, relativeTo: button.subviews.first); button.addSubview(text)
            addSubview(button); buttons.append(button)
        }
        let count = CGFloat(suggestions.count)
        // With no rows, nothing to keep a margin below: the field sits as far from the bottom as the top.
        restingFrame.size.height = count == 0 ? headerHeight
            : headerHeight + count*AddressAppearance.rowHeight + max(0, count-1)*AddressAppearance.rowSpacing + AddressAppearance.inset
        updateSelection()
        applyPresentation()
    }
    /// Picks a row, or with -1 none, back to the typed text.
    func selectResult(_ index: Int) {
        guard isPresented, index == -1 || suggestions.indices.contains(index) else { return }
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
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard isPresented else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let index = buttons.firstIndex(where: { $0.frame.contains(point) }) {
            if selectionBeforeHover == nil { selectionBeforeHover = selectedIndex }
            selectResult(index)
        } else if !buttons.reduce(NSRect.null, { $0.union($1.frame) }).contains(point) {
            // Above the results, on the address itself; the gaps between rows still count as hovering.
            pointerLeftResults()
        }
    }
    override func mouseExited(with event: NSEvent) { pointerLeftResults() }
    /// The row the pointer had picked was only for as long as it was there.
    private func pointerLeftResults() {
        guard let previous = selectionBeforeHover else { return }
        selectionBeforeHover = nil
        selectResult(previous)
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
        let icon = NSRect(x: AddressAppearance.inset+9, y: (headerHeight-16)/2, width: 16, height: 16)
        leadingIcon.frame = icon
        let inputHeight = input.intrinsicContentSize.height
        // The hint keeps the end of the row; a long address fades out before it.
        let hintWidth = siteHint.preferredWidth
        siteHint.frame = NSRect(x: bounds.width-AddressAppearance.inset-12-hintWidth, y: 0, width: hintWidth, height: headerHeight)
        let hintRoom = offeredSite == nil && siteSearch == nil ? 0 : hintWidth+12
        input.frame = NSRect(x: AddressAppearance.inset+35, y: (headerHeight-inputHeight)/2, width: bounds.width-AddressAppearance.inset-50-hintRoom, height: inputHeight)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: AddressAppearance.inset, y: headerHeight+CGFloat(i)*(AddressAppearance.rowHeight+AddressAppearance.rowSpacing), width: bounds.width-2*AddressAppearance.inset, height: AddressAppearance.rowHeight)
            if let icon = button.subviews.first as? NSImageView {
                icon.frame = NSRect(x: 9, y: (button.bounds.height-16)/2, width: 16, height: 16)
            }
            if let text = button.subviews.last as? NSTextField {
                let height = text.intrinsicContentSize.height
                text.frame = NSRect(x: 35, y: (button.bounds.height-height)/2, width: max(0, button.bounds.width-44), height: height)
            }
        }
    }
    func updateFavicon(_ image: NSImage, origin: String) {
        if let site = siteSearch ?? offeredSite, SitePermissions.origin(site.homeURL) == origin { siteHint.applyTheme(theme, siteColor: color(for: site)) }
        if SitePermissions.origin(autofill?.url) == origin { autofill?.favicon = image }
        defer { updateLeadingIcon() }
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
        updateOffer(); updateLeadingIcon()
    }
    func controlTextDidBeginEditing(_ obj: Notification) { input.updateFade() }
    func controlTextDidEndEditing(_ obj: Notification) { input.needsLayout = true }
    func controlTextDidChange(_ obj: Notification) {
        guard !applyingCompletion else { return }
        completionRange = nil
        let editor = input.currentEditor() as? NSTextView
        let typed = editor?.string ?? input.stringValue
        // A site's search takes words, not addresses: nothing to match or fill in.
        if siteSearch != nil { input.stringValue = typed; return }
        if editor?.hasMarkedText() == true { refresh(query: typed); return }
        input.stringValue = typed; refresh()
        let suppressed = suppressCompletion; suppressCompletion = false
        guard !suppressed, let editor, !editor.hasMarkedText(),
              editor.selectedRange() == NSRange(location: typed.utf16.count, length: 0),
              let completed = autofill?.completion ?? suggestions.first?.completion, completed.hasPrefix(typed), completed != typed else { updateLeadingIcon(); return }
        applyingCompletion = true
        let range = NSRange(location: typed.utf16.count, length: completed.utf16.count-typed.utf16.count)
        editor.string = completed; input.stringValue = completed; editor.setSelectedRange(range)
        completionPrefix = typed; completionRange = range
        applyingCompletion = false
        updateOffer(); updateLeadingIcon()
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): chooseSelected(); return true
        case #selector(NSResponder.insertTab(_:)):
            if siteSearch == nil, let site = offeredSite { enterSiteSearch(site); return true }
            return siteSearch != nil
        case #selector(NSResponder.insertBacktab(_:)):
            guard siteSearch != nil else { return false }
            leaveSiteSearch(); return true
        // Escape steps back out of a site's search first, then closes.
        case #selector(NSResponder.cancelOperation(_:)): if siteSearch != nil { leaveSiteSearch() } else { dismiss?() }; return true
        case #selector(NSResponder.moveDown(_:)): selectionBeforeHover = nil; selectResult(min(suggestions.count-1, selectedIndex+1)); return true
        case #selector(NSResponder.moveUp(_:)): selectionBeforeHover = nil; selectResult(max(-1, selectedIndex-1)); return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)):
            // Deleting past the start of an empty query goes back to the address.
            if siteSearch != nil, textView.string.isEmpty, commandSelector != #selector(NSResponder.deleteForward(_:)) { leaveSiteSearch(); return true }
            suppressCompletion = true; completionRange = nil; return false
        case #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToBeginningOfParagraph(_:)):
            if siteSearch != nil, textView.string.isEmpty { leaveSiteSearch(); return true }
            // ⌘⌫ clears what's typed along with what it filled in, and nothing fills back in.
            if let range = completionRange, textView.selectedRange() == range { textView.setSelectedRange(NSRange(location: 0, length: range.upperBound)) }
            suppressCompletion = true; completionRange = nil; return false
        default: return false
        }
    }
    @objc func choose(_ sender: NSButton) { selectResult(sender.tag); chooseSelected() }
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        guard isPresented, event.type == .keyDown, [36, 76].contains(event.keyCode),
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              let chosen = chosenSuggestion, let id = chosen.tabID else { return false }
        switchToTab?(id)
        return true
    }
    func chooseSelected() {
        guard isPresented else { return }
        if let site = siteSearch {
            // An empty search, or the address left as it was, goes to the site itself.
            var words = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if input.stringValue == addressBeforeSiteSearch?.text { words = "" }
            let url = words.isEmpty ? site.homeURL : site.searchURL(for: words) ?? site.homeURL
            submit?(input.stringValue, AddressSuggestion(title: "Search \(site.name)", subtitle: "", symbol: "magnifyingglass", url: url,
                                                         tabID: nil, command: nil, isTypedAction: true))
            return
        }
        submit?(input.stringValue, chosenSuggestion)
    }
    /// What Enter opens: the row picked, or with none, the row that stands for the typed text.
    /// An autofill that was deleted no longer stands for it.
    var chosenSuggestion: AddressSuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex]
            : ([autofill].compactMap { $0 }+suggestions).first { $0.isTypedAction && ($0.completion == nil || $0.completion == input.stringValue) }
    }

    // MARK: Site search

    private func applyPlaceholder() {
        input.placeholderAttributedString = NSAttributedString(string: siteSearch.map { "Search \($0.name)…" } ?? "Search or Enter URL…",
                                                               attributes: [.foregroundColor: theme.muted, .font: input.font!])
    }
    /// Offers the site's search while the address is a site that has one.
    private func updateOffer() {
        let site = siteSearch == nil ? site(forAddress: input.stringValue).flatMap { $0.isSearchable ? $0 : nil } : nil
        guard site != offeredSite else { return }
        offeredSite = site
        if let site { siteHint.configure(site: site.name, color: color(for: site), theme: theme) }
        siteHint.setAccessibilityElement(site != nil)
        fadeHint(to: site == nil ? 0 : 1)
        needsLayout = true
    }
    private func fadeHint(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { siteHint.alphaValue = alpha; completion?(); return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = alpha > 0 ? 0.14 : 0.12; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            siteHint.animator().alphaValue = alpha
        }, completionHandler: completion)
    }
    /// The site's name, in the colour picked for it in Settings, or else its icon's main color.
    private func color(for site: PopularSite) -> NSColor {
        if let custom = customSite?(site.domain), custom == site, let hex = custom.color { return NSColor(hex: hex) }
        if let icon = siteFavicon?(site.homeURL), let color = FaviconColor.dominant(icon) { return FaviconColor.readable(color, theme: theme) }
        if let hex = site.color { return FaviconColor.readable(NSColor(hex: hex), theme: theme) }
        return AddressAppearance.textColor(theme)
    }
    /// Tab: the field keeps the address, all selected, so typing replaces it with the search, while
    /// the hint at the end takes the site's colour and slides into the keycap's place.
    func enterSiteSearch(_ site: PopularSite) {
        let address = input.stringValue
        addressBeforeSiteSearch = AddressState(text: address, query: query, selection: (input.currentEditor() as? NSTextView)?.selectedRange() ?? NSRange(location: address.utf16.count, length: 0),
                                               completionRange: completionRange, completionPrefix: completionPrefix, suggestions: suggestions, autofill: autofill)
        siteSearch = site; offeredSite = nil; completionRange = nil; suppressCompletion = false
        if siteHint.siteName != site.name { siteHint.configure(site: site.name, color: color(for: site), theme: theme) }
        siteHint.alphaValue = 1; siteHint.setAccessibilityElement(true)
        siteHint.setSearching(true, animated: true)
        updateLeadingIcon()
        selectAll()
        applyPlaceholder(); input.setAccessibilityLabel("Search \(site.name)")
        suggestions = []; selectedIndex = -1; selectionBeforeHover = nil; render()
    }
    /// Back to the address as it was before Tab, all selected, with the same rows, and the hint
    /// offering the site's search again.
    func leaveSiteSearch() {
        guard let site = siteSearch else { return }
        siteSearch = nil
        let before = addressBeforeSiteSearch; addressBeforeSiteSearch = nil
        setText(before?.text ?? site.domain); selectAll()
        applyPlaceholder(); input.setAccessibilityLabel("Address or search")
        offeredSite = site; siteHint.setSearching(false, animated: true)
        if let before {
            query = before.query; suggestions = before.suggestions; autofill = before.autofill
            completionRange = nil
            selectedIndex = -1; selectionBeforeHover = nil
            render(); updateOffer(); updateLeadingIcon()
        } else { refresh() }
    }
    /// ⌘Z in a site's search steps back: the search first, back to the address, then out.
    func handleUndoKey(_ event: NSEvent) -> Bool {
        guard isPresented, let before = addressBeforeSiteSearch, siteSearch != nil, event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "z" else { return false }
        if input.stringValue == before.text { leaveSiteSearch() } else { setText(before.text); selectAll() }
        return true
    }
    private func setText(_ text: String) {
        if let editor = input.currentEditor() as? NSTextView {
            editor.string = text; editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
        input.stringValue = text
    }
    private func selectAll() {
        (input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: input.stringValue.utf16.count))
    }
    /// Straight back to the address, at rest, for a palette opening or closing.
    private func resetSiteSearch() {
        if siteSearch != nil { siteSearch = nil; applyPlaceholder(); input.setAccessibilityLabel("Address or search") }
        addressBeforeSiteSearch = nil
        offeredSite = nil; siteHint.alphaValue = 0; siteHint.setAccessibilityElement(false)
        siteHint.setSearching(false, animated: false)
        needsLayout = true
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
