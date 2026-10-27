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
    var assistantPrompt: AssistantPrompt? = nil
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
    /// Styled after Kero's palette (`CenteredPaletteStyle`), centred over a veil: always, but in
    /// the palette lab, whose values are for the palette as it was.
    private(set) var isCentered = false
    /// The first row the centred palette shows, when there are more than fit.
    private(set) var firstRow = 0
    /// The centred style's tight shadow at the edge; the palette's own layer casts the wide one.
    private let edgeShadow = CALayer()
    private var headerHeight: CGFloat {
        isCentered ? CenteredPaletteStyle.fieldHeight : createsTab ? AddressAppearance.newTabHeaderHeight : AddressAppearance.headerHeight
    }
    init() {
        super.init(color: NSColor(hex: 0xF8F8F8), radius: AddressAppearance.cornerRadius)
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.black.withAlphaComponent(0.16).cgColor; layer?.borderWidth = 0.5
        shadow = chromeShadow(opacity: 0.22, blur: 24, offset: -8)
        input.isBordered = false; input.drawsBackground = false; input.focusRingType = .none
        input.font = AddressAppearance.textFont; input.textColor = NSColor(hex: 0x3D3D3D)
        input.placeholderString = "Search or Enter URL…"; input.delegate = self
        input.setAccessibilityLabel("Address or search")
        leadingIcon.image = AddressAppearance.searchIcon; leadingIcon.imageScaling = .scaleProportionallyUpOrDown
        leadingIcon.contentTintColor = .secondaryLabelColor
        siteHint.alphaValue = 0; siteHint.setAccessibilityElement(false)
        edgeShadow.cornerCurve = .continuous; edgeShadow.isHidden = true; layer?.insertSublayer(edgeShadow, at: 0)
        addSubview(input); addSubview(leadingIcon); addSubview(siteHint)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func show(text: String, theme: RiseTheme, createsTab: Bool = false, centered: Bool = false) {
        self.createsTab = createsTab; isCentered = centered
        siteHint.fontOverride = centered ? CenteredPaletteStyle.siteSearchFont : nil
        siteHint.applyFont()
        completionRange = nil; suppressCompletion = false
        resetSiteSearch()
        applyTheme(theme); isHidden = false; alphaValue = 1; input.stringValue = text
        refresh(); window?.makeFirstResponder(input); input.selectText(nil)
    }
    func applyTheme(_ theme: RiseTheme) {
        self.theme = theme
        if isCentered { applyCenteredStyle() } else {
            fill = AddressAppearance.background(theme); cornerRadius = AddressAppearance.cornerRadius
            layer?.borderColor = AddressAppearance.border(theme).cgColor; layer?.borderWidth = AddressAppearance.tuning.borderWidth
            edgeShadow.isHidden = true; shadow = AddressAppearance.shadow(theme)
            input.font = AddressAppearance.textFont
            input.textColor = AddressAppearance.textColor(theme)
        }
        input.selectionColor = AddressAppearance.textSelection(theme)
        applyPlaceholder()
        updateLeadingIcon()
        if let site = siteSearch ?? offeredSite { siteHint.applyTheme(theme, siteColor: color(for: site)) }
    }
    private func applyCenteredStyle() {
        let style = CenteredPaletteStyle.self, background = style.background(theme)
        fill = background; cornerRadius = style.cornerRadius
        let border = style.border(theme); layer?.borderColor = border.color.cgColor; layer?.borderWidth = border.width
        let shadows = style.shadows(theme)
        // Two shadows, as one NSShadow can't: CSS blurs, whose spread is twice a layer's radius.
        shadow = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (target, (y, blur, color)) in [(layer, shadows.wide), (edgeShadow, shadows.tight)] {
            target?.shadowColor = color.cgColor; target?.shadowOpacity = 1
            // Down the window: the palette's layer is flipped, as the view is.
            target?.shadowRadius = blur/2; target?.shadowOffset = CGSize(width: 0, height: y)
        }
        edgeShadow.isHidden = false; edgeShadow.backgroundColor = background.cgColor; edgeShadow.cornerRadius = style.cornerRadius
        CATransaction.commit()
        input.font = style.fieldFont; input.textColor = style.fieldText(theme)
    }
    /// Takes up changed values (`AddressAppearance.tuning`): fonts, colours, sizes and spacing.
    func applyTuning() {
        applyTheme(theme); siteHint.applyFont(); render()
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
        suggestions = takeAutofill(queryChanged?(self.query) ?? []); selectedIndex = -1; selectionBeforeHover = nil; typedField = nil
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
        if let list = choice {
            leadingIcon.image = list.symbol == "paintbrush" ? TablerIcon.themeImage(size: 16) : NSImage(systemSymbolName: list.symbol, accessibilityDescription: nil)
            leadingIcon.contentTintColor = fieldIconColor; return
        }
        if isCentered, typedField != nil, suggestions.indices.contains(selectedIndex), let command = suggestions[selectedIndex].command {
            // The picked command's own icon, not a page's the words might name.
            leadingIcon.image = Self.isThemeCommand(command) ? TablerIcon.themeImage(size: 16)
                : NSImage(systemSymbolName: suggestions[selectedIndex].symbol, accessibilityDescription: nil)
            leadingIcon.contentTintColor = fieldIconColor; return
        }
        let address = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let site = fieldSite, let favicon = siteFavicon?(site.homeURL) {
            leadingIcon.image = favicon; leadingIcon.contentTintColor = nil
        } else if siteSearch != nil {
            leadingIcon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil); leadingIcon.contentTintColor = fieldIconColor
        } else if completionRange != nil, let favicon = suggestions.first?.favicon {
            // A visited page filling in shows its icon too.
            leadingIcon.image = favicon; leadingIcon.contentTintColor = nil
        } else if let page = currentPage, !createsTab, !address.isEmpty, address == page.address, let favicon = page.favicon {
            leadingIcon.image = favicon; leadingIcon.contentTintColor = nil
        } else {
            leadingIcon.image = isCentered ? CenteredPaletteStyle.searchIcon : AddressAppearance.searchIcon; leadingIcon.contentTintColor = fieldIconColor
        }
    }
    private var fieldIconColor: NSColor { isCentered ? CenteredPaletteStyle.fieldIcon(theme) : AddressAppearance.iconColor(theme) }
    func replaceSuggestions(_ updated: [AddressSuggestion]) {
        // Late results for the address don't belong to a site's search.
        guard siteSearch == nil, !isChoosing else { return }
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
        if isCentered { renderCentered(); return }
        for (index, suggestion) in suggestions.enumerated() {
            let button = NSButton(); button.title = ""; button.isBordered = false
            button.wantsLayer = true; button.layer?.cornerRadius = AddressAppearance.tuning.rowRadius; button.layer?.cornerCurve = .continuous
            button.layer?.backgroundColor = (index == selectedIndex ? AddressAppearance.selection(theme) : .clear).cgColor
            button.tag = index; button.target = self; button.action = #selector(choose(_:))
            button.setAccessibilityLabel(suggestion.title)
            if suggestion.tabID != nil {
                button.setAccessibilityHelp("Open existing tab")
            }
            let imageView = FaviconView(frame: .zero)
            imageView.image = Self.isThemeCommand(suggestion.command)
                ? TablerIcon.themeImage(size: 16)
                : suggestion.favicon ?? (suggestion.symbol == "magnifyingglass" ? AddressAppearance.searchIcon
                    : NSImage(systemSymbolName: suggestion.symbol, accessibilityDescription: nil))
            // Search rows' glyphs sit a shade lighter than the field's own.
            imageView.contentTintColor = suggestion.favicon != nil ? nil
                : suggestion.symbol == "magnifyingglass" ? AddressAppearance.iconColor(theme).withAlphaComponent(0.75) : AddressAppearance.iconColor(theme)
            // A page without its icon gets the sidebar's empty square, until its icon loads.
            if suggestion.favicon == nil, suggestion.symbol == "globe", suggestion.command != "Change Theme" {
                imageView.showEmptyPlaceholder(theme: theme)
            }
            let text = label(suggestion.title, size: AddressAppearance.textSize, weight: AddressAppearance.textWeight, color: AddressAppearance.textColor(theme))
            text.font = AddressAppearance.rowFont
            let truncating = NSMutableParagraphStyle(); truncating.lineBreakMode = .byTruncatingTail
            text.attributedStringValue = NSAttributedString(string: suggestion.title, attributes: [.font: AddressAppearance.rowFont, .foregroundColor: AddressAppearance.textColor(theme),
                                                                                                  .kern: AddressAppearance.rowKern, .paragraphStyle: truncating])
            if suggestion.symbol == "globe", suggestion.fetchFavicon, !suggestion.subtitle.isEmpty,
               suggestion.title != suggestion.subtitle {
                let address = AddressDisplay.text(suggestion.subtitle)
                let title = NSMutableAttributedString(string: suggestion.title, attributes: [.font: AddressAppearance.rowFont, .foregroundColor: AddressAppearance.textColor(theme), .kern: AddressAppearance.rowKern])
                title.append(NSAttributedString(string: " ", attributes: [.font: AddressAppearance.rowFont, .kern: AddressAppearance.tuning.addressGap]))
                title.append(NSAttributedString(string: address, attributes: [.font: AddressAppearance.addressFont, .kern: AddressAppearance.rowKern, .foregroundColor: AddressAppearance.secondary(theme)]))
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
            : headerHeight + AddressAppearance.tuning.rowsTop + count*AddressAppearance.rowHeight + max(0, count-1)*AddressAppearance.rowSpacing + AddressAppearance.inset
        updateSelection()
        applyPresentation()
    }
    /// Kero's rows: a symbol or the site's icon, the title, and its address beside it, fainter.
    private func renderCentered() {
        let style = CenteredPaletteStyle.self
        for (index, suggestion) in suggestions.enumerated() {
            let button = NSButton(); button.title = ""; button.isBordered = false
            button.wantsLayer = true; button.layer?.cornerRadius = style.rowRadius; button.layer?.cornerCurve = .continuous
            button.tag = index; button.target = self; button.action = #selector(choose(_:))
            button.setAccessibilityLabel(suggestion.title)
            if suggestion.tabID != nil { button.setAccessibilityHelp("Open existing tab") }
            let imageView = FaviconView(frame: .zero)
            imageView.image = Self.isThemeCommand(suggestion.command) ? TablerIcon.themeImage(size: style.rowIconSize)
                : suggestion.favicon ?? (suggestion.symbol == "magnifyingglass" ? style.searchIcon
                    : NSImage(systemSymbolName: suggestion.symbol, accessibilityDescription: nil))
            imageView.contentTintColor = suggestion.favicon != nil ? nil : style.detail(theme)
            if suggestion.favicon == nil, suggestion.symbol == "globe", suggestion.command != "Change Theme" {
                imageView.showEmptyPlaceholder(theme: theme)
            }
            button.addSubview(imageView)
            let title = NSTextField(labelWithString: suggestion.title)
            title.font = style.titleFont; title.textColor = style.title(theme); title.lineBreakMode = .byTruncatingTail
            title.identifier = Self.titleID; button.addSubview(title)
            if suggestion.symbol == "globe", suggestion.fetchFavicon, !suggestion.subtitle.isEmpty, suggestion.title != suggestion.subtitle {
                let address = NSTextField(labelWithString: AddressDisplay.text(suggestion.subtitle))
                address.font = style.detailFont; address.textColor = style.detail(theme); address.lineBreakMode = .byTruncatingTail
                address.identifier = Self.detailID; button.addSubview(address)
            }
            addSubview(button); buttons.append(button)
        }
        restingFrame.size.height = style.height(rows: suggestions.count)
        firstRow = 0
        updateSelection()
        applyPresentation()
    }
    /// The field as typed, kept while the arrow keys fill in the rows they pick, to put back past
    /// the first row.
    private struct TypedField { let text: String, selection: NSRange, completionRange: NSRange?, completionPrefix: String }
    private var typedField: TypedField?
    /// The arrow keys: down from the field to the first row and on, up past the first back to
    /// none. Each row picked fills in the field, the cursor at its end, to edit; none puts back
    /// what was typed, and what it filled in.
    private func moveCentered(by step: Int) {
        let next = max(-1, min(suggestions.count-1, selectedIndex+step))
        guard next != selectedIndex, let editor = input.currentEditor() as? NSTextView else { return }
        if typedField == nil {
            typedField = TypedField(text: editor.string, selection: editor.selectedRange(), completionRange: completionRange, completionPrefix: completionPrefix)
        }
        selectedIndex = next
        applyingCompletion = true
        if next >= 0 {
            completionRange = nil
            // A command leaves what was typed, without the address that was filling in after it.
            setText(Self.fieldText(for: suggestions[next]) ?? typedField.map { $0.completionRange == nil ? $0.text : $0.completionPrefix } ?? editor.string)
        } else if let typed = typedField {
            typedField = nil
            editor.string = typed.text; input.stringValue = typed.text; editor.setSelectedRange(typed.selection)
            completionRange = typed.completionRange; completionPrefix = typed.completionPrefix
        }
        applyingCompletion = false
        updateOffer(); updateLeadingIcon(); updateSelection()
    }
    /// What a row puts in the field: a search's words or a page's address; a command leaves it.
    static func fieldText(for suggestion: AddressSuggestion) -> String? {
        guard suggestion.command == nil else { return nil }
        if suggestion.symbol == "magnifyingglass" {
            // "Search Kagi for “x”" is a search for x.
            if let open = suggestion.title.range(of: " for “"), suggestion.title.hasSuffix("”") {
                return String(suggestion.title[open.upperBound..<suggestion.title.index(before: suggestion.title.endIndex)])
            }
            return suggestion.title
        }
        guard let url = suggestion.url else { return nil }
        var address = AddressDisplay.text(url.absoluteString)
        // A site's own page reads as the site.
        if url.path.isEmpty || url.path == "/", url.query == nil, url.fragment == nil, address.hasSuffix("/") { address.removeLast() }
        return address
    }
    private static let titleID = NSUserInterfaceItemIdentifier("title"), detailID = NSUserInterfaceItemIdentifier("detail")
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
        scrollToSelection()
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedIndex
            if isCentered {
                // One gray, under the pointer or the arrow keys alike.
                button.layer?.backgroundColor = (selected ? CenteredPaletteStyle.hover(theme) : .clear).cgColor
                continue
            }
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
        super.updateTrackingAreas(); removeOwnTrackingAreas()
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard isPresented else { return }
        let point = convert(event.locationInWindow, from: nil)
        if isCentered { pointerMovedCentered(to: point); return }

        if let index = buttons.firstIndex(where: { $0.frame.contains(point) }) {
            if selectionBeforeHover == nil { selectionBeforeHover = selectedIndex }
            selectResult(index)
        } else if !buttons.reduce(NSRect.null, { $0.union($1.frame) }).contains(point) {
            // Above the results, on the address itself; the gaps between rows still count as hovering.
            pointerLeftResults()
        }
    }
    override func mouseExited(with event: NSEvent) { pointerLeftResults() }
    /// The row under the pointer is the one picked, for Enter too, while the pointer's on it;
    /// what the field filled in stays. Off the rows, the pick goes back to the arrow keys'.
    private func pointerMovedCentered(to point: NSPoint) {
        if let index = buttons.firstIndex(where: { !$0.isHidden && $0.frame.contains(point) }) {
            if selectionBeforeHover == nil { selectionBeforeHover = selectedIndex }
            guard selectedIndex != index else { return }
            selectedIndex = index; updateSelection()
        } else if !buttons.filter({ !$0.isHidden }).reduce(NSRect.null, { $0.union($1.frame) }).contains(point) {
            pointerLeftResults()
        }
    }
    /// A list longer than fits scrolls a row at a time, under the pointer or to keep the row the
    /// arrow keys pick in view.
    override func scrollWheel(with event: NSEvent) {
        guard isCentered, isPresented, suggestions.count > CenteredPaletteStyle.visibleRows else { super.scrollWheel(with: event); return }
        scrollAmount += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY*CenteredPaletteStyle.rowHeight
        let rows = Int(scrollAmount/CenteredPaletteStyle.rowHeight)
        guard rows != 0 else { return }
        scrollAmount -= CGFloat(rows)*CenteredPaletteStyle.rowHeight
        scroll(to: firstRow-rows)
        // What's under the pointer now is what it picks.
        pointerMovedCentered(to: convert(event.locationInWindow, from: nil))
    }
    private var scrollAmount: CGFloat = 0
    private func scroll(to row: Int) {
        let first = max(0, min(row, suggestions.count-CenteredPaletteStyle.visibleRows))
        guard first != firstRow else { return }
        firstRow = first; needsLayout = true; layoutSubtreeIfNeeded()
    }
    /// The picked row in view, the list moving as little as it can.
    private func scrollToSelection() {
        let visible = CenteredPaletteStyle.visibleRows
        guard isCentered, suggestions.indices.contains(selectedIndex) else { return }
        if selectedIndex < firstRow { scroll(to: selectedIndex) } else if selectedIndex >= firstRow+visible { scroll(to: selectedIndex-visible+1) }
    }
    /// The row the pointer had picked was only for as long as it was there.
    private func pointerLeftResults() {
        guard let previous = selectionBeforeHover else { return }
        selectionBeforeHover = nil
        // The centred palette's pointer never took back what the field filled in.
        if isCentered { if selectedIndex != previous { selectedIndex = previous; updateSelection() }; return }
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
        if isCentered { layoutCentered(); return }
        let tuning = AddressAppearance.tuning, inset = tuning.inset
        let iconSize = tuning.fieldIconSize
        leadingIcon.frame = NSRect(x: inset+tuning.fieldIconInset, y: (headerHeight-iconSize)/2, width: iconSize, height: iconSize)
        let inputHeight = input.intrinsicContentSize.height
        // The hint keeps the end of the row; a long address fades out before it.
        let hintWidth = siteHint.preferredWidth, trailing = inset+tuning.fieldTrailingInset
        siteHint.frame = NSRect(x: bounds.width-trailing-hintWidth, y: 0, width: hintWidth, height: headerHeight)
        let hintRoom = offeredSite == nil && siteSearch == nil ? 0 : hintWidth+12
        let inputX = inset+tuning.fieldTextInset
        input.frame = NSRect(x: inputX, y: (headerHeight-inputHeight)/2, width: max(0, bounds.width-inputX-(trailing-4)-hintRoom), height: inputHeight)
        for (i, button) in buttons.enumerated() {
            button.frame = NSRect(x: inset, y: headerHeight+tuning.rowsTop+CGFloat(i)*(tuning.rowHeight+tuning.rowSpacing), width: bounds.width-2*inset, height: tuning.rowHeight)
            if let icon = button.subviews.first as? NSImageView {
                icon.frame = NSRect(x: tuning.rowIconInset, y: (button.bounds.height-tuning.rowIconSize)/2, width: tuning.rowIconSize, height: tuning.rowIconSize)
            }
            if let text = button.subviews.last as? NSTextField {
                let height = text.intrinsicContentSize.height
                text.frame = NSRect(x: tuning.rowTextInset, y: (button.bounds.height-height)/2, width: max(0, button.bounds.width-tuning.rowTextInset-tuning.rowTrailingInset), height: height)
            }
        }
    }
    private func layoutCentered() {
        let style = CenteredPaletteStyle.self, padding = style.fieldPadding, icon = style.fieldIconSize
        CATransaction.begin(); CATransaction.setDisableActions(true); edgeShadow.frame = bounds; CATransaction.commit()
        leadingIcon.frame = NSRect(x: padding, y: (headerHeight-icon)/2, width: icon, height: icon)
        let hintWidth = siteHint.preferredWidth
        siteHint.frame = NSRect(x: bounds.width-padding-hintWidth, y: 0, width: hintWidth, height: headerHeight)
        let hintRoom = offeredSite == nil && siteSearch == nil ? 0 : hintWidth+style.gap
        let inputX = padding+icon+style.gap, inputHeight = input.intrinsicContentSize.height
        input.frame = NSRect(x: inputX, y: (headerHeight-inputHeight)/2, width: max(0, bounds.width-inputX-padding-hintRoom), height: inputHeight)
        let list = style.listPadding
        for (i, button) in buttons.enumerated() {
            button.isHidden = i < firstRow || i >= firstRow+style.visibleRows
            button.frame = NSRect(x: list, y: headerHeight+list+CGFloat(i-firstRow)*style.rowHeight, width: bounds.width-2*list, height: style.rowHeight)
            let rowIcon = style.rowIconSize, inner = button.bounds
            button.subviews.first { $0 is NSImageView }?.frame = NSRect(x: style.rowPadding, y: (inner.height-rowIcon)/2, width: rowIcon, height: rowIcon)
            var x = style.rowPadding+rowIcon+style.gap
            let end = inner.width-style.rowPadding
            for case let text as NSTextField in button.subviews {
                let size = text.intrinsicContentSize
                // Measured from the text itself: a truncating label's own measure falls short.
                let natural = ceil(text.attributedStringValue.size().width)+4
                let width = text.identifier == Self.titleID ? min(natural, style.titleMaximumWidth, end-x) : end-x
                text.frame = NSRect(x: x, y: (inner.height-size.height)/2, width: max(0, width), height: size.height)
                x += width+style.gap
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
        updateOffer(); updateLeadingIcon(); if isCentered { updateSelection() }
    }
    func controlTextDidBeginEditing(_ obj: Notification) { input.updateFade() }
    func controlTextDidEndEditing(_ obj: Notification) { input.needsLayout = true }
    func controlTextDidChange(_ obj: Notification) {
        guard !applyingCompletion else { return }
        completionRange = nil; typedField = nil
        let editor = input.currentEditor() as? NSTextView
        let typed = editor?.string ?? input.stringValue
        if isChoosing { input.stringValue = typed; showChoices(matching: typed); return }
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
        updateOffer(); updateLeadingIcon(); if isCentered { updateSelection() }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)): chooseSelected(); return true
        case #selector(NSResponder.insertTab(_:)):
            if isChoosing { return true }
            if siteSearch == nil, let site = offeredSite { enterSiteSearch(site); return true }
            return siteSearch != nil
        case #selector(NSResponder.insertBacktab(_:)):
            guard siteSearch != nil else { return false }
            leaveSiteSearch(); return true
        // Escape steps back out of a site's search first, then closes.
        case #selector(NSResponder.cancelOperation(_:)):
            if isChoosing { leaveChoice() } else if siteSearch != nil { leaveSiteSearch() } else { dismiss?() }
            return true
        case #selector(NSResponder.moveDown(_:)):
            selectionBeforeHover = nil
            if isCentered { moveCentered(by: 1) } else { selectResult(min(suggestions.count-1, selectedIndex+1)) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            selectionBeforeHover = nil
            if isCentered { moveCentered(by: -1) } else { selectResult(max(-1, selectedIndex-1)) }
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordBackward(_:)):
            // Deleting past the start of an empty query goes back to the address.
            if isChoosing, textView.string.isEmpty, commandSelector != #selector(NSResponder.deleteForward(_:)) { leaveChoice(); return true }
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
    func handleKeyEquivalent(_ event: NSEvent, shortcuts: KeyboardShortcuts? = nil) -> Bool {
        guard isPresented, event.type == .keyDown,
              shortcuts?.matches("activateSuggestedTab", event) ?? (KeyboardShortcut(event: event) == KeyboardShortcut("Command+Enter")),
              let chosen = chosenSuggestion, let id = chosen.tabID else { return false }
        switchToTab?(id)
        return true
    }
    func chooseSelected() {
        guard isPresented else { return }
        if isChoosing {
            // The row picked, or the first left by what's typed.
            guard let row = suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : suggestions.first else { return }
            submit?(input.stringValue, row); return
        }
        if let command = chosenSuggestion?.command, let list = choices?(command) { enterChoice(list); return }
        if let site = siteSearch {
            // An empty search, or the address left as it was, goes to the site itself.
            var words = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if input.stringValue == addressBeforeSiteSearch?.text { words = "" }
            let request = words.isEmpty ? nil : site.assistant.map { AssistantPrompt(service: $0, text: words) }
            let url = request?.service.entryURL ?? (words.isEmpty ? site.homeURL : site.searchURL(for: words) ?? site.homeURL)
            submit?(input.stringValue, AddressSuggestion(title: "\(site.action) \(site.name)", subtitle: "", symbol: "magnifyingglass", url: url,
                                                         tabID: nil, command: nil, isTypedAction: true, assistantPrompt: request))
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

    // MARK: Choosing from a list

    /// A command's list to pick from, such as the themes: its rows in place of the suggestions.
    struct Choice {
        let placeholder: String
        /// The field's icon while it shows: an SF Symbol, or "paintbrush" for the theme brush.
        let symbol: String
        let rows: [AddressSuggestion]
        /// The row to start on: the setting in use.
        var picked: Int?
    }
    /// A command that opens a list rather than running, and its list.
    var choices: ((String) -> Choice?)?
    /// A theme row's command: this, then the theme's raw value, or "automatic".
    static let themeCommandPrefix = "Theme:"
    static func isThemeCommand(_ command: String?) -> Bool { command == "Change Theme" || command?.hasPrefix(themeCommandPrefix) == true }
    /// The list showing, after its command; typing narrows it.
    private(set) var choice: Choice?
    var isChoosing: Bool { choice != nil }
    private var addressBeforeChoice: AddressState?
    /// The list in place of the rows, the setting in use picked; the field empties to narrow it.
    func enterChoice(_ list: Choice) {
        let address = input.stringValue
        addressBeforeChoice = AddressState(text: address, query: query, selection: (input.currentEditor() as? NSTextView)?.selectedRange() ?? NSRange(location: address.utf16.count, length: 0),
                                           completionRange: completionRange, completionPrefix: completionPrefix, suggestions: suggestions, autofill: autofill)
        choice = list; completionRange = nil; typedField = nil
        updateOffer()
        setText(""); applyPlaceholder(); input.setAccessibilityLabel(list.placeholder)
        showChoices(matching: "")
    }
    private func showChoices(matching text: String) {
        guard let list = choice else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestions = list.rows.filter { words.isEmpty || $0.title.localizedCaseInsensitiveContains(words) }
        autofill = nil; selectionBeforeHover = nil; typedField = nil
        selectedIndex = words.isEmpty ? list.picked.flatMap { list.rows.indices.contains($0) ? $0 : nil } ?? -1 : suggestions.isEmpty ? -1 : 0
        render(); updateLeadingIcon()
    }
    /// Back to what was typed before the command, as it was, with its rows.
    func leaveChoice() {
        guard choice != nil else { return }
        choice = nil
        let before = addressBeforeChoice; addressBeforeChoice = nil
        setText(before?.text ?? "")
        if let before, let editor = input.currentEditor() as? NSTextView, NSMaxRange(before.selection) <= (editor.string as NSString).length {
            editor.setSelectedRange(before.selection)
        }
        applyPlaceholder(); input.setAccessibilityLabel("Address or search")
        guard let before else { refresh(); return }
        query = before.query; suggestions = before.suggestions; autofill = before.autofill
        completionRange = before.completionRange; completionPrefix = before.completionPrefix
        selectedIndex = -1; selectionBeforeHover = nil; typedField = nil
        render(); updateOffer(); updateLeadingIcon()
    }

    // MARK: Site search

    private func applyPlaceholder() {
        input.placeholderAttributedString = NSAttributedString(string: choice?.placeholder ?? siteSearch.map { "\($0.action) \($0.name)…" } ?? "Search or Enter URL…",
                                                               attributes: [.foregroundColor: isCentered ? CenteredPaletteStyle.placeholder(theme) : AddressAppearance.secondary(theme),
                                                                            .font: isCentered ? CenteredPaletteStyle.fieldFont : AddressAppearance.placeholderFont])
    }
    /// Offers the site's search while the address is a site that has one.
    private func updateOffer() {
        let site = siteSearch == nil && !isChoosing ? site(forAddress: input.stringValue).flatMap { $0.isSearchable ? $0 : nil } : nil
        guard site != offeredSite else { return }
        offeredSite = site
        if let site { siteHint.configure(site: site.name, action: site.action, color: color(for: site), theme: theme) }
        siteHint.setAccessibilityElement(site != nil)
        fadeHint(to: site == nil ? 0 : 1)
        needsLayout = true
    }
    private func fadeHint(to alpha: CGFloat, completion: (() -> Void)? = nil) {
        // The centred palette's offer shows and goes at once.
        guard window != nil, !isCentered, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            siteHint.alphaValue = alpha; completion?(); return
        }
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
    /// Tab: the field empties for the search, from scratch, while the hint at the end takes the
    /// site's colour and slides into the keycap's place. Escape brings the address back as it was.
    func enterSiteSearch(_ site: PopularSite) {
        let address = input.stringValue
        addressBeforeSiteSearch = AddressState(text: address, query: query, selection: (input.currentEditor() as? NSTextView)?.selectedRange() ?? NSRange(location: address.utf16.count, length: 0),
                                               completionRange: completionRange, completionPrefix: completionPrefix, suggestions: suggestions, autofill: autofill)
        siteSearch = site; offeredSite = nil; completionRange = nil; suppressCompletion = false
        if siteHint.siteName != site.name || siteHint.action != site.action { siteHint.configure(site: site.name, action: site.action, color: color(for: site), theme: theme) }
        siteHint.alphaValue = 1; siteHint.setAccessibilityElement(true)
        siteHint.setSearching(true, animated: true)
        updateLeadingIcon()
        setText("")
        applyPlaceholder(); input.setAccessibilityLabel("\(site.action) \(site.name)")
        suggestions = []; selectedIndex = -1; selectionBeforeHover = nil; render()
    }
    /// Back to the address as it was before Tab, selected as it was, with the same rows, and the
    /// hint offering the site's search again.
    func leaveSiteSearch() {
        guard let site = siteSearch else { return }
        siteSearch = nil
        let before = addressBeforeSiteSearch; addressBeforeSiteSearch = nil
        setText(before?.text ?? site.domain)
        // As it was: what the field had filled in, still filled in and selected, so its site's
        // search is offered again.
        if let before, let editor = input.currentEditor() as? NSTextView, NSMaxRange(before.selection) <= (editor.string as NSString).length {
            editor.setSelectedRange(before.selection)
        } else { selectAll() }
        applyPlaceholder(); input.setAccessibilityLabel("Address or search")
        offeredSite = site; siteHint.setSearching(false, animated: true)
        if let before {
            query = before.query; suggestions = before.suggestions; autofill = before.autofill
            completionRange = before.completionRange; completionPrefix = before.completionPrefix
            selectedIndex = -1; selectionBeforeHover = nil
            render(); updateOffer(); updateLeadingIcon()
        } else { refresh() }
    }
    /// ⌘Z in a site's search steps back: what's typed first, back to the empty search, then out.
    func handleUndoKey(_ event: NSEvent, shortcuts: KeyboardShortcuts? = nil) -> Bool {
        guard isPresented, let before = addressBeforeSiteSearch, siteSearch != nil, event.type == .keyDown,
              shortcuts?.matches("undo:", event) ?? (KeyboardShortcut(event: event) == KeyboardShortcut("Command+Z")) else { return false }
        if input.stringValue.isEmpty { leaveSiteSearch() } else { setText("") }
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
        if choice != nil { choice = nil; addressBeforeChoice = nil; applyPlaceholder(); input.setAccessibilityLabel("Address or search") }
        if siteSearch != nil { siteSearch = nil; applyPlaceholder(); input.setAccessibilityLabel("Address or search") }
        addressBeforeSiteSearch = nil
        offeredSite = nil; siteHint.alphaValue = 0; siteHint.setAccessibilityElement(false)
        siteHint.setSearching(false, animated: false)
        needsLayout = true
    }
}

/// Seen and never clicked: what's under it takes the pointer.
final class PassThroughView: FlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
