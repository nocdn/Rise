import UIKit

/// Shared learned links and remote suggestions, with immediate inline completion and site-search mode.
final class SearchPanel: UIView, UITextFieldDelegate {
    static let fieldHeight: CGFloat = 48
    static let rowHeight: CGFloat = 56
    /// Between the field and the first suggestion.
    static let rowsGap: CGFloat = 10
    /// Four rows show above the keyboard; the remaining ranked results scroll beneath it.
    static let visibleSuggestions = 4
    static let maximumSuggestions = 12
    /// A little breathing room below the fourth row; the fifth row's content stays covered.
    static let keyboardClearance: CGFloat = 6
    static let inset: CGFloat = 16
    /// Suggestions sit this far inside the field's left edge, which balances them better than lining up.
    static let rowIndent: CGFloat = 2
    /// How small a suggestion gets while pressed.
    static let pressedScale: CGFloat = 0.97
    /// The field and as many suggestions as show.
    static var height: CGFloat { fieldHeight+rowsGap+CGFloat(visibleSuggestions)*rowHeight+keyboardClearance }
    /// The field's corners: rounded, rather than a capsule.
    static let cornerRadius: CGFloat = 14
    /// The field's fill, as on Arc Search's, translucent over dark pages.
    static let fill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.1) : UIColor(red: 248/255, green: 249/255, blue: 250/255, alpha: 1) }
    /// The fill under a finger: a little darker, or lighter over dark pages.
    static let pressedFill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.16) : UIColor(red: 236/255, green: 237/255, blue: 240/255, alpha: 1) }
    /// The magnifying glass's colour, beside each suggestion.
    static let iconColor = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.5) : UIColor(red: 165/255, green: 167/255, blue: 172/255, alpha: 1) }
    static let iconStrokeWidth: CGFloat = 2.5
    /// Rounded typography for Find and menu controls; address/search fields share the suggestions' font.
    static var fieldFont: UIFont { roundedFont(weight: .semibold) }
    static var font: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
    }
    static func roundedFont(ofSize size: CGFloat = 17, weight: UIFont.Weight, scaled: Bool = true) -> UIFont {
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? font
        return scaled ? UIFontMetrics(forTextStyle: .body).scaledFont(for: rounded) : rounded
    }
    /// The system's bold magnifying glass at 16 points, redrawn with its handle as thick as its ring
    /// and about as long. Drawn rather than a symbol, so the suggestions' buttons don't resize it
    /// to their text.
    static let searchIcon: UIImage = {
        let line = iconStrokeWidth, outerRadius: CGFloat = 7.33
        let centre = CGPoint(x: 7.4, y: 7.4), radius = outerRadius-line/2
        // The handle's tip, round cap included, from the ring's centre; the symbol's reaches 11.8.
        let tip: CGFloat = 11.9, diagonal = 1/CGFloat(2).squareRoot()
        let point = { (distance: CGFloat) in CGPoint(x: centre.x+distance*diagonal, y: centre.y+distance*diagonal) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.black.setStroke()
            let ring = UIBezierPath(arcCenter: centre, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            ring.lineWidth = line
            ring.stroke()
            let handle = UIBezierPath()
            handle.move(to: point(radius))
            handle.addLine(to: point(tip-line/2))
            handle.lineWidth = line
            handle.lineCapStyle = .round
            handle.stroke()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()
    /// A 45-degree arrow toward the field, drawn at the search glyph's size and stroke.
    static let fillIcon: UIImage = {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { _ in
            UIColor.black.setStroke()
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: 11.25, y: 11.25)); arrow.addLine(to: CGPoint(x: 2.25, y: 2.25))
            arrow.move(to: CGPoint(x: 2.25, y: 9.25)); arrow.addLine(to: CGPoint(x: 2.25, y: 2.25))
            arrow.addLine(to: CGPoint(x: 9.25, y: 2.25))
            arrow.lineWidth = iconStrokeWidth
            arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            arrow.stroke()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }()

    let field = SearchField()
    private(set) var editingAddress: AddressBar?
    private(set) var suggestions: [String] = []
    private(set) var candidates: [AddressCandidate] = []
    private(set) var offeredSite: PopularSite?
    private(set) var siteSearch: PopularSite?
    private(set) var query = ""
    private(set) var completionPrefix: String?
    var allowsRemoteSuggestions = true
    private let regularRemote = GoogleSearchSuggestions()
    private var privateRemote: GoogleSearchSuggestions?
    private var remote: GoogleSearchSuggestions {
        guard isPrivateBrowsing else { return regularRemote }
        if let privateRemote { return privateRemote }
        let client = GoogleSearchSuggestions()
        client.onLoad = regularRemote.onLoad
        privateRemote = client
        return client
    }
    private var rows: [AddressSuggestionRow] = []
    let list = SuggestionList()
    var resultRows: [AddressSuggestionRow] { (offeredSite == nil ? [] : [siteRow])+rows }
    var isScrollable: Bool { list.contentSize.height > list.bounds.height+0.5 }
    /// Kept at the full search layout during compact site search, so rows lift up with the sheet.
    var visibleHeight: CGFloat = SearchPanel.height {
        didSet { if visibleHeight != oldValue { setNeedsLayout() } }
    }
    let siteRow = AddressSuggestionRow()
    private var applyingCompletion = false
    private var changingText = false
    private var suppressCompletion = false
    private var active = false
    private var currentAddress: URL?
    private struct SearchDraft {
        let text: String
        let completion: String?
        let completionPrefix: String?
        let selection: NSRange
        let scrollOffset: CGPoint
    }
    private var previousSearch: SearchDraft?
    var source: MobileAddressSuggestions? {
        didSet { source?.icons.onLoad = { [weak self] in self?.refresh() } }
    }
    var openTabs: () -> [AddressSuggestionTab] = { [] }
    var tabIcon: (URL) -> UIImage? = { _ in nil }
    var onSwitchToTab: (UUID) -> Void = { _ in }
    private let click = UIImpactFeedbackGenerator(style: .rigid)
    private let fillFeedback = UIImpactFeedbackGenerator(style: .soft)
    let clearButton = AnimatedSymbolButton(symbol: "xmark", pointSize: 14, weight: .bold)
    let privateButton = AnimatedSymbolButton(symbol: "eye.slash", pointSize: 17, weight: .semibold)
    private(set) var isPrivateBrowsing = false
    var onPrivateBrowsingChanged: (() -> Void)?
    let transcribing = UIActivityIndicatorView(style: .medium)
    var onClose: @MainActor () -> Void = {}
    var onSiteSearchChanged: @MainActor () -> Void = {}
    private var opening = 0
    private var backgroundSelection: (text: String, range: NSRange)?
    var onOpen: @MainActor (URL) -> Void = { _ in }
    var onAsk: @MainActor (AssistantPrompt) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        field.backgroundColor = Self.fill
        field.layer.cornerCurve = .continuous; field.layer.cornerRadius = Self.cornerRadius
        field.placeholder = "Search or enter URL"; field.font = Self.font
        field.adjustsFontForContentSizeCategory = true
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: Self.fieldHeight))
        field.leftViewMode = .always
        field.keyboardType = .webSearch; field.returnKeyType = .go
        field.autocorrectionType = .no; field.autocapitalizationType = .none; field.spellCheckingType = .no
        field.delegate = self
        field.handleDeleteBackward = { [weak self] in
            guard let self else { return false }
            suppressCompletion = true
            guard field.inlineCompletion != nil else { return false }
            UIView.performWithoutAnimation {
                self.field.inlineCompletion = nil
                self.completionPrefix = nil
                self.queryChanged()
            }
            return true
        }
        field.acceptCompletion = { [weak self] in
            guard let self, let completed = field.inlineCompletion else { return }
            UIView.performWithoutAnimation {
                self.applyingCompletion = true
                self.field.inlineCompletion = nil
                self.field.text = completed
                self.completionPrefix = nil
                self.query = completed
                self.updateResults(allowCompletion: false)
                self.applyingCompletion = false
            }
        }
        field.addAction(UIAction { [weak self] _ in self?.queryChanged() }, for: .editingChanged)
        addSubview(field)
        useClearButton()
        clearButton.accessibilityLabel = "Clear"
        clearButton.shrinksWhenPressed(to: AddressBar.pressedScale)
        clearButton.addAction(UIAction { [weak self] _ in self?.clearOrClose() }, for: .primaryActionTriggered)
        addSubview(clearButton)
        privateButton.shrinksWhenPressed(to: AddressBar.pressedScale)
        privateButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setPrivateBrowsing(!self.isPrivateBrowsing)
        }, for: .primaryActionTriggered)
        addSubview(privateButton)
        updatePrivateButton()
        transcribing.hidesWhenStopped = true; transcribing.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
        transcribing.accessibilityLabel = "Transcribing"; addSubview(transcribing)
        list.delaysContentTouches = false
        list.contentInsetAdjustmentBehavior = .never
        list.showsHorizontalScrollIndicator = false
        list.showsVerticalScrollIndicator = false
        list.keyboardDismissMode = .none
        addSubview(list)
        siteRow.alpha = 0; siteRow.isHidden = true
        siteRow.choose = { [weak self] in self?.enterSiteSearch() }
        siteRow.fill = { [weak self] in
            guard let self, let site = offeredSite else { return }
            fillInput(site.homeURL.absoluteString)
        }
        list.addSubview(siteRow)
        remote.onLoad = { [weak self] text in
            guard let self, active, query == text, siteSearch == nil, field.markedTextRange == nil else { return }
            refresh()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func useClearButton() {
        field.clearButtonMode = .never
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 84, height: Self.fieldHeight))
        field.rightViewMode = .always
        clearButton.isHidden = transcribing.isAnimating
    }
    private func clearOrClose() {
        if siteSearch != nil { leaveSiteSearch(); return }
        guard !(field.text ?? "").isEmpty else { onClose(); return }
        field.text = ""; field.inlineCompletion = nil; completionPrefix = nil; suppressCompletion = true
        // The bar provides the X's single haptic on touch-down, including URL editing.
        queryChanged()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width-2*Self.inset)
        let frame = CGRect(x: Self.inset, y: 0, width: width, height: Self.fieldHeight)
        if let editingAddress { editingAddress.frame = frame; editingAddress.layoutIfNeeded() }
        else { field.frame = frame }
        clearButton.bounds = CGRect(x: 0, y: 0, width: AddressBar.buttonWidth, height: Self.fieldHeight)
        clearButton.center = CGPoint(x: frame.maxX-AddressBar.outerCentre, y: frame.midY)
        privateButton.bounds = clearButton.bounds
        privateButton.center = convert(CGPoint(x: clearButton.center.x-40, y: frame.midY), to: privateButton.superview)
        transcribing.center = clearButton.center
        let top = Self.fieldHeight+Self.rowsGap
        list.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, visibleHeight-top))
        let offset = offeredSite == nil ? 0 : 1
        siteRow.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
        siteRow.center = CGPoint(x: bounds.midX, y: Self.rowHeight/2)
        for (index, row) in rows.enumerated() {
            row.bounds = CGRect(x: 0, y: 0, width: width, height: Self.rowHeight)
            row.center = CGPoint(x: bounds.midX, y: (CGFloat(index+offset)+0.5)*Self.rowHeight)
            row.isHidden = false
            row.isUserInteractionEnabled = siteSearch == nil
            row.accessibilityElementsHidden = siteSearch != nil
        }
        list.contentSize = CGSize(width: bounds.width, height: CGFloat(rows.count+offset)*Self.rowHeight)
        list.isScrollEnabled = siteSearch == nil && isScrollable
        list.isUserInteractionEnabled = siteSearch == nil
        siteRow.isUserInteractionEnabled = offeredSite != nil && siteSearch == nil
        siteRow.accessibilityElementsHidden = offeredSite == nil || siteSearch != nil
    }
    func begin(privateBrowsing: Bool = false) {
        backgroundSelection = nil
        remote.cancel()
        isPrivateBrowsing = privateBrowsing
        if !privateBrowsing { privateRemote = nil }
        privateButton.isHidden = false
        updatePrivateButton()
        opening += 1; active = true; changingText = false; stopTranscribing()
        siteSearch = nil; previousSearch = nil; currentAddress = nil; completionPrefix = nil; field.inlineCompletion = nil; query = ""; field.text = ""
        showPlaceholder()
        list.setContentOffset(.zero, animated: false)
        updateResults(allowCompletion: false)
        if allowsRemoteSuggestions { remote.warmUp() }; click.prepare()
    }
    func focus() { _ = field.becomeFirstResponder() }

    /// UIKit can collapse the selection while dismissing/reopening the keyboard. Capture it
    /// before the scene resigns active, and only restore it if the draft still matches.
    func rememberSelectionForBackground() {
        backgroundSelection = field.selectedTextRange.map {
            (field.text ?? "", NSRange(location: field.offset(from: field.beginningOfDocument, to: $0.start),
                                     length: field.offset(from: $0.start, to: $0.end)))
        }
    }

    func resumeFocus() {
        let selection = backgroundSelection
        backgroundSelection = nil
        focus()
        if let selection, selection.text == field.text,
           let start = field.position(from: field.beginningOfDocument, offset: selection.range.location),
           let end = field.position(from: start, offset: selection.range.length) {
            field.selectedTextRange = field.textRange(from: start, to: end)
        }
    }
    func beginTranscribing() -> Int {
        clearButton.isHidden = true; transcribing.startAnimating(); return opening
    }
    func finishTranscribing(_ text: String, for opening: Int) {
        guard opening == self.opening, transcribing.isAnimating else { return }
        stopTranscribing(); guard !text.isEmpty else { return }
        let typed = (completionPrefix ?? field.text ?? "").trimmingCharacters(in: .whitespaces)
        field.inlineCompletion = nil; field.text = typed.isEmpty ? text : typed+" "+text; completionPrefix = nil
        field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        suppressCompletion = true; queryChanged(); click.impactOccurred(intensity: 0.5)
    }
    private func stopTranscribing() {
        guard transcribing.isAnimating else { return }
        transcribing.stopAnimating(); clearButton.isHidden = editingAddress != nil
    }
    func beginEditingAddress(_ address: AddressBar, url: URL?) {
        backgroundSelection = nil
        privateButton.isHidden = true
        remote.cancel(); opening += 1; active = true; changingText = false; stopTranscribing()
        siteSearch = nil; previousSearch = nil; completionPrefix = nil; field.inlineCompletion = nil; currentAddress = url
        showPlaceholder()
        editingAddress = address; addSubview(address); field.text = url?.absoluteString ?? ""; query = field.text ?? ""
        list.setContentOffset(.zero, animated: false)
        address.prepareEditing(field, url: url); clearButton.isHidden = true
        updateResults(allowCompletion: false); if allowsRemoteSuggestions { remote.warmUp() }; click.prepare()
    }
    func focusAddress() {
        guard editingAddress != nil else { return }
        field.isUserInteractionEnabled = true; _ = field.becomeFirstResponder()
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
    }
    func finishAddressTransition() { editingAddress?.finishEditing() }
    func releaseAddress() {
        guard let address = editingAddress else { return }
        editingAddress = nil; address.endEditingAddress()
        addSubview(field); bringSubviewToFront(clearButton); bringSubviewToFront(transcribing)
        field.backgroundColor = Self.fill; useClearButton(); field.alpha = 1; field.isUserInteractionEnabled = true
        setNeedsLayout()
    }
    func clearAddress() {
        editingAddress?.host.text = ""
        clearOrClose(); _ = field.becomeFirstResponder()
    }
    func end() {
        backgroundSelection = nil
        previousSearch = nil
        active = false; remote.cancel(); opening += 1; stopTranscribing(); _ = field.resignFirstResponder()
        privateRemote = nil
    }
    /// Late icons, learned templates and remote results never replace the person's text/selection.
    func refresh() {
        guard active else { return }
        updateResults(allowCompletion: false)
    }
    private func queryChanged() {
        guard active else { return }
        editingAddress?.finishEditing()
        UIView.performWithoutAnimation { self.field.inlineCompletion = nil }
        completionPrefix = nil; query = field.text ?? ""
        list.setContentOffset(.zero, animated: false)
        updateResults(allowCompletion: !suppressCompletion)
        suppressCompletion = false
        changingText = false
    }
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        changingText = true
        let length = (textField.text ?? "").utf16.count
        suppressCompletion = string.isEmpty || string.count > 1 || NSMaxRange(range) < length || textField.markedTextRange != nil
        return true
    }
    func textFieldDidChangeSelection(_ textField: UITextField) {
        // UIKit moves its cursor between shouldChange and editingChanged. That intermediate
        // state must not remove and re-enter a site's row on every additional character.
        guard !applyingCompletion, !changingText, field.inlineCompletion != nil,
              let selection = field.selectedTextRange else { return }
        let end = field.offset(from: field.beginningOfDocument, to: selection.end)
        if !selection.isEmpty || end != (field.text ?? "").utf16.count {
            UIView.performWithoutAnimation { self.field.inlineCompletion = nil }
            completionPrefix = nil; query = field.text ?? ""; refresh()
        }
    }
    private func updateResults(allowCompletion: Bool) {
        guard let source else { candidates = []; suggestions = []; return }
        if siteSearch != nil {
            // Freeze the suggestions from the original query, including their view identities
            // and full-width frames. They are covered by the keyboard in the smaller sheet.
            showPlaceholder()
            return
        }
        let composing = field.markedTextRange != nil
        let local = AddressSuggestionEngine.suggestions(for: query, history: source.history, tabs: openTabs(),
            currentURL: currentAddress, editingCurrentAddress: editingAddress != nil && query == currentAddress?.absoluteString,
            limit: Self.maximumSuggestions+1)
        let terms = composing || !allowsRemoteSuggestions ? [] : remote.suggestions(for: query)
        candidates = AddressSuggestionEngine.merging(terms, into: local, limit: Self.maximumSuggestions+1, tabs: openTabs())
        if allowCompletion || composing {
            let completed = !composing ? candidates.first?.completion : nil
            UIView.performWithoutAnimation {
                self.applyingCompletion = true
                self.field.inlineCompletion = completed
                self.completionPrefix = completed == nil ? nil : self.query
                self.field.layoutIfNeeded()
                self.applyingCompletion = false
            }
        }
        let fieldAddress = field.inlineCompletion ?? field.text ?? ""
        let siteAddress = candidates.first.flatMap { candidate in
            candidate.completion == nil ? nil : candidate.url.flatMap { BrowsingHistory.completion(for: query, url: $0) }
        } ?? fieldAddress
        let site = PopularSites.site(forAddress: siteAddress) ?? source.learner.searches.site(forAddress: siteAddress)
        updateSite(site?.isSearchable == true && !composing ? site : nil)
        let url = (candidates.first?.symbol == "globe" && candidates.first?.isTypedAction == true)
            ? candidates.first?.url : (fieldAddress == currentAddress?.absoluteString ? currentAddress : nil)
        let fetchIcon = candidates.first?.fetchFavicon != false
        if !isPrivateBrowsing { source.icons.previewCandidate(fetchIcon ? nil : url) }
        // Go still uses the typed action; the list only shows actual suggestions and pages.
        let visible = candidates.filter { !$0.isAutofill && !($0.isTypedAction && $0.symbol == "magnifyingglass") }
        suggestions = visible.map(\.title)
        renderRows(Array(visible.prefix(Self.maximumSuggestions-(offeredSite == nil ? 0 : 1))))
    }
    private func image(for url: URL?, fetch: Bool = true) -> UIImage? {
        guard let url else { return nil }
        if let image = tabIcon(url) {
            if !isPrivateBrowsing { source?.icons.remember(image, for: url) }
            return image
        }
        return source?.icons.image(for: url, fetch: fetch && !isPrivateBrowsing)
    }

    func setPrivateBrowsing(_ enabled: Bool) {
        guard editingAddress == nil, isPrivateBrowsing != enabled else { return }
        remote.cancel()
        if !enabled { privateRemote = nil }
        isPrivateBrowsing = enabled
        // The colours and the eye change first; the suggestions refresh after, under the fade.
        onPrivateBrowsingChanged?()
        updatePrivateButton()
        if enabled { source?.icons.previewCandidate(nil) }
        refresh()
        // The colour change is already committed before UIKit refreshes its keyboard appearance.
        if field.isFirstResponder { field.reloadInputViews() }
    }

    private func updatePrivateButton() {
        privateButton.setGlyph(UIImage(named: isPrivateBrowsing ? "PrivateEye" : "PrivateEyeOff"),
                               name: isPrivateBrowsing ? "private-eye" : "private-eye-off")
        privateButton.accessibilityLabel = isPrivateBrowsing ? "Use regular browsing" : "Use private browsing"
        privateButton.accessibilityValue = isPrivateBrowsing ? "Private browsing on" : "Private browsing off"
        privateButton.accessibilityTraits = isPrivateBrowsing ? [.button, .selected] : [.button]
        field.keyboardAppearance = isPrivateBrowsing ? .dark : .default
        field.textContentType = isPrivateBrowsing ? nil : .URL
    }
    private func renderRows(_ values: [AddressCandidate]) {
        while rows.count > values.count { rows.removeLast().removeFromSuperview() }
        while rows.count < values.count { let row = AddressSuggestionRow(); rows.append(row); list.addSubview(row) }
        for (row, value) in zip(rows, values) {
            row.show(value, image: value.symbol == "globe" ? image(for: value.url, fetch: value.fetchFavicon) : nil)
            row.choose = { [weak self] in self?.choose(value) }
            let text = value.symbol == "magnifyingglass" ? (value.isTypedAction ? query : value.title)
                : value.url?.absoluteString ?? value.title
            row.fill = { [weak self] in self?.fillInput(text) }
        }
        setNeedsLayout()
    }
    /// Refine a suggestion in place, without submitting it or switching to an existing tab.
    private func fillInput(_ text: String) {
        guard active, siteSearch == nil else { return }
        fillFeedback.impactOccurred(intensity: 0.4)
        UIView.performWithoutAnimation {
            applyingCompletion = true
            field.inlineCompletion = nil
            field.text = text
            _ = field.becomeFirstResponder()
            field.selectedTextRange = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
            suppressCompletion = true
            queryChanged()
            field.layoutIfNeeded()
            applyingCompletion = false
        }
    }
    private func updateSite(_ site: PopularSite?) {
        let changed = offeredSite?.domain != site?.domain
        offeredSite = site
        if let site {
            let icon = image(for: site.homeURL)
            siteRow.showSite(site, image: icon, color: brandColor(for: site, icon: icon))
        }
        guard changed else { return }
        let visible = site != nil
        UIView.performWithoutAnimation {
            self.siteRow.alpha = visible ? 1 : 0
            self.siteRow.transform = .identity
            self.siteRow.isHidden = !visible
            self.siteRow.isUserInteractionEnabled = visible
            self.siteRow.accessibilityElementsHidden = !visible
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
    }
    private func brandColor(for site: PopularSite, icon: UIImage?) -> UIColor? {
        MobileSuggestionFavicons.color(in: icon)
            ?? site.color.map { UIColor(red: CGFloat(($0 >> 16)&255)/255, green: CGFloat(($0 >> 8)&255)/255, blue: CGFloat($0&255)/255, alpha: 1) }
    }
    private func showPlaceholder() {
        guard let siteSearch else {
            field.attributedPlaceholder = nil
            field.placeholder = "Search or enter URL"
            return
        }
        let font = field.font ?? Self.font
        let title = NSMutableAttributedString(string: siteSearch.assistant == nil ? "Search in " : "Ask ", attributes: [.font: font, .foregroundColor: UIColor.placeholderText])
        let brand = brandColor(for: siteSearch, icon: image(for: siteSearch.homeURL))
        let muted = brand?.withAlphaComponent(0.45) ?? .placeholderText
        title.append(NSAttributedString(string: siteSearch.name, attributes: [.font: font, .foregroundColor: muted]))
        field.attributedPlaceholder = title
    }
    func enterSiteSearch() {
        guard siteSearch == nil, let site = offeredSite else { return }
        // Complete any layout requested by the final keystroke before the sheet's spring starts.
        UIView.performWithoutAnimation { self.layoutIfNeeded() }
        let text = field.text ?? ""
        let selection = field.selectedTextRange.map { range in
            NSRange(location: field.offset(from: field.beginningOfDocument, to: range.start),
                    length: field.offset(from: range.start, to: range.end))
        } ?? NSRange(location: text.utf16.count, length: 0)
        previousSearch = SearchDraft(text: text, completion: field.inlineCompletion,
                                     completionPrefix: completionPrefix, selection: selection, scrollOffset: list.contentOffset)
        click.impactOccurred(intensity: 0.5); remote.cancel(); siteSearch = site
        completionPrefix = nil; field.inlineCompletion = nil; query = ""; field.text = ""
        showPlaceholder()
        updateResults(allowCompletion: false); _ = field.becomeFirstResponder()
        setNeedsLayout()
        onSiteSearchChanged()
    }
    private func leaveSiteSearch() {
        let draft = previousSearch
        previousSearch = nil
        siteSearch = nil; showPlaceholder()
        UIView.performWithoutAnimation {
            applyingCompletion = true
            field.inlineCompletion = nil
            field.text = draft?.text ?? ""
            query = field.text ?? ""
            completionPrefix = draft?.completionPrefix
            field.inlineCompletion = draft?.completion
            if let selection = draft?.selection,
               let start = field.position(from: field.beginningOfDocument, offset: selection.location),
               let end = field.position(from: start, offset: selection.length) {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
            changingText = false; suppressCompletion = false
            // The original rows are still here. Preserve their content and geometry during
            // expansion instead of rebuilding them from a possibly different remote answer.
            setNeedsLayout()
            layoutIfNeeded()
            if let draft { list.setContentOffset(draft.scrollOffset, animated: false) }
            field.layoutIfNeeded()
            applyingCompletion = false
        }
        if allowsRemoteSuggestions { _ = remote.suggestions(for: query) }
        onSiteSearchChanged()
    }
    func choose(_ value: AddressCandidate) {
        guard let url = value.url else { return }
        if let id = value.tabID { remember(url); click.impactOccurred(intensity: 0.5); onSwitchToTab(id) }
        else { open(url) }
    }
    func choose(_ suggestion: String) { if let url = Self.searchURL(for: suggestion) { open(url) } }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let siteSearch {
            let terms = (field.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !terms.isEmpty, let assistant = siteSearch.assistant {
                click.impactOccurred(intensity: 0.5)
                onAsk(AssistantPrompt(service: assistant, text: terms))
            } else if !terms.isEmpty, let url = siteSearch.searchURL(for: terms) { open(url) }
        } else if let completed = field.inlineCompletion {
            if let value = candidates.first(where: { $0.completion == completed }) { choose(value) }
            else if let url = Self.destination(for: completed) { open(url) }
        }
        else if let url = Self.destination(for: field.text ?? "") {
            if let tab = AddressSuggestionEngine.openTab(for: url, in: openTabs()), editingAddress == nil { remember(url); onSwitchToTab(tab.id) }
            else { open(url) }
        }
        return false
    }
    func textFieldShouldClear(_ textField: UITextField) -> Bool { click.impactOccurred(intensity: 0.5); return true }
    private func open(_ url: URL) {
        remember(url)
        click.impactOccurred(intensity: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.07) { [click] in click.impactOccurred(intensity: 0.5) }
        onOpen(url)
    }
    private func remember(_ url: URL) {
        guard url.host != Self.searchURL(for: query)?.host else { return }
        source?.selected(url, privateBrowsing: isPrivateBrowsing)
    }
    static func searchURL(for query: String) -> URL? { SearchEngine.google.searchURL(for: query) }
    static func destination(for text: String) -> URL? {
        guard let url = AddressResolver.resolve(text), ["http","https"].contains(url.scheme ?? "") else { return nil }
        return url
    }
    // Kept for fixture compatibility; production uses the shared bounded remote client.
    static func suggestionsURL(for query: String) -> URL? {
        var url = URLComponents(string: "https://suggestqueries.google.com/complete/search")
        url?.queryItems = [URLQueryItem(name: "client", value: "firefox"), URLQueryItem(name: "q", value: query)]
        return url?.url
    }
    static func suggestions(from data: Data) -> [String] {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [Any], values.count > 1 else { return [] }
        return values[1] as? [String] ?? []
    }
}

/// Rows retain their immediate press feedback while a drag hands control to native scrolling.
final class SuggestionList: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }

    /// A downward pull at the top moves the sheet; every other drag scrolls results.
    func canPullToClose(velocity: CGPoint) -> Bool {
        velocity.y > abs(velocity.x) && contentOffset.y <= -adjustedContentInset.top+1
    }
}

/// The search field, with its clear button as far from the right end as from the top and bottom.
/// Shaking the phone while it's focused clears it, with two sharp taps, rather than offering to
/// undo the typing.
final class SearchField: UITextField {
    private let shake = UIImpactFeedbackGenerator(style: .rigid)
    private let completionClip = UIView()
    private let completionLabel = UILabel()
    private var completionTint: UIColor?
    /// The full completed address. `text` always remains exactly what the person typed.
    var inlineCompletion: String? {
        didSet {
            if inlineCompletion != nil, oldValue == nil {
                completionTint = tintColor
                tintColor = .clear
            } else if inlineCompletion == nil {
                tintColor = completionTint ?? tintColor
                completionTint = nil
            }
            completionClip.isHidden = inlineCompletion == nil
            setNeedsLayout()
        }
    }
    var acceptCompletion: (() -> Void)?
    #if DEBUG
    var inlineCompletionFrame: CGRect { completionLabel.convert(completionLabel.bounds, to: self) }
    #endif
    override init(frame: CGRect) {
        super.init(frame: frame)
        completionClip.isUserInteractionEnabled = false
        completionClip.clipsToBounds = true
        completionClip.isHidden = true
        completionLabel.isAccessibilityElement = false
        completionLabel.lineBreakMode = .byClipping
        completionLabel.textColor = .label
        completionLabel.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18)
        completionClip.addSubview(completionLabel)
        addSubview(completionClip)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let completed = inlineCompletion, let text, completed.hasPrefix(text), completed.count > text.count else {
            completionClip.isHidden = true; return
        }
        let rect = super.editingRect(forBounds: bounds)
        // During editingChanged the native caret can still describe the previous key.
        // Measuring the current prefix keeps the suffix in place on the same frame.
        let prefixWidth = (text as NSString).size(withAttributes: [.font: font ?? UIFont.systemFont(ofSize: 17)]).width
        completionClip.frame = rect
        completionLabel.font = font
        completionLabel.text = String(completed.dropFirst(text.count))
        let width = completionLabel.intrinsicContentSize.width
        let height = ceil(completionLabel.font.lineHeight)
        completionLabel.frame = CGRect(x: prefixWidth, y: (rect.height-height)/2, width: width, height: height)
        completionClip.isHidden = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if inlineCompletion != nil { acceptCompletion?() }
        super.touchesBegan(touches, with: event)
    }
    override var keyCommands: [UIKeyCommand]? {
        guard inlineCompletion != nil else { return super.keyCommands }
        let right = UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(acceptInlineCompletion))
        right.wantsPriorityOverSystemBehavior = true
        return [right]
    }
    @objc private func acceptInlineCompletion() { acceptCompletion?() }
    var handleDeleteBackward: (() -> Bool)?
    override func deleteBackward() {
        if handleDeleteBackward?() != true { super.deleteBackward() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            UIApplication.shared.applicationSupportsShakeToEdit = false
            shake.prepare()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { UIApplication.shared.applicationSupportsShakeToEdit = true }
        return resigned
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake, isFirstResponder else { return super.motionEnded(motion, with: event) }
        guard !(text ?? "").isEmpty else { return }
        text = ""
        // As typing would, so the suggestions clear too.
        sendActions(for: .editingChanged)
        shake.impactOccurred(intensity: 1)
        DispatchQueue.main.asyncAfter(deadline: .now()+0.1) { [shake] in shake.impactOccurred(intensity: 1) }
    }

    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        let button = super.clearButtonRect(forBounds: bounds)
        let padding = (bounds.height-button.height)/2
        return CGRect(x: bounds.maxX-padding-button.width, y: bounds.minY+padding, width: button.width, height: button.height)
    }

    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        var rect = super.editingRect(forBounds: bounds)
        guard clearButtonMode != .never, isEditing, !(text ?? "").isEmpty else { return rect }
        rect.size.width = min(rect.width, clearButtonRect(forBounds: bounds).minX-6-rect.minX)
        return rect
    }
}
