import UIKit

/// The toolbar along the bottom edge, as in Arc Search: white, or dark grey in dark mode, with
/// a stack of page previews for Tabs, a rounded button for New Page and a circle for the menu.
/// Scrolling down collapses it to a thin, empty strip; scrolling back up opens it again. New Page
/// grows it into a panel with rounded top corners for a search; More grows it a little, into the
/// page's address and a few actions, whose Find turns it into a find field above the keyboard.
/// Either way the bar's contents swap with a quick, blurred crossfade.
final class BottomBar: UIView {
    enum Panel { case search, menu, tabMenu, find, siteSettings, appSettings, privacyPolicy, downloads, history }

    /// The buttons' row, and the space above it.
    static let rowHeight: CGFloat = 42
    static let rowTop: CGFloat = 10
    /// The Tabs button's and the menu's centres, from the window's sides, as in Arc.
    static let sideCentre: CGFloat = 44
    static let newPageSize = CGSize(width: 76, height: 38)
    static let menuSize: CGFloat = 36
    static let springDuration = 0.3
    /// White, and in dark mode a dark grey rather than black, so its buttons and panels stand out.
    static let background = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 1) : .white }
    /// The top corners' radius once the bar has grown into its panel, as on Peek's card.
    static let panelCornerRadius: CGFloat = PeekPresentationController.cornerRadius

    let tabsButton = TabsPreviewButton()
    let newPageButton = UIButton(type: .custom)
    /// New Page's plus, which holding the button swaps for a waveform of the voice.
    private let plusGlyph = UIImageView(image: UIImage(systemName: "plus", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)))
    let waveform = VoiceWaveform()
    private(set) var isListening = false
    let moreButton = AnimatedSymbolButton(symbol: "ellipsis", pointSize: 14)
    /// The download's landing kick stays independent of the button's normal press scale.
    let moreLanding = UIView()
    private(set) var translationHint: PageTranslationHint?

    func announceTranslation(documentID: String) {
        cancelTranslationHint()
        let hint = PageTranslationHint(documentID: documentID, landing: moreLanding, in: home)
        translationHint = hint
        home.insertSubview(hint, belowSubview: row)
        hint.start { [weak self, weak hint] in
            guard let self, translationHint === hint else { return }
            translationHint = nil
        }
    }
    func cancelTranslationHint() { translationHint?.cancel(); translationHint = nil }
    private(set) var translationStatus: PageTranslationStatus?
    var showTranslationProgress: ((UIView) -> Void)?
    var configureTranslationSpinner: ((UIView) -> Void)?

    func updateTranslationStatus(_ state: MobilePageTranslation.State, visible: Bool) {
        guard visible, state.available, state.enabled, let documentID = state.documentID else {
            cancelTranslationStatus(); return
        }
        if translationStatus?.documentID != documentID { cancelTranslationStatus() }
        if state.busy {
            cancelTranslationHint()
            if let translationStatus { translationStatus.showLoading(); return }
            let status = PageTranslationStatus(documentID: documentID)
            configureTranslationSpinner?(status)
            status.addAction(UIAction { [weak self, weak status] _ in
                guard let status, status.phase == .translating else { return }
                self?.showTranslationProgress?(status)
            }, for: .primaryActionTriggered)
            translationStatus = status
            row.insertSubview(status, belowSubview: moreLanding)
            setNeedsLayout(); layoutIfNeeded()
            status.start { [weak self, weak status] in
                guard let self, translationStatus === status else { return }
                translationStatus = nil
            }
        } else { translationStatus?.showTranslated() }
    }
    func cancelTranslationStatus() { translationStatus?.cancel(); translationStatus = nil }
    /// The bar's own contents: its row of buttons.
    let home = UIView()
    /// New Page's panel: a search.
    let search = SearchPanel()
    private let privacyAppearance = PrivatePanelAppearance()
    private(set) var isPrivateBrowsing = false
    #if DEBUG
    var privateFade: Float? { privacyAppearance.shownFade }
    #endif

    func setPrivateBrowsing(_ enabled: Bool, animated: Bool) {
        guard isPrivateBrowsing != enabled else {
            if !animated { privacyAppearance.finish(on: self) }
            return
        }
        isPrivateBrowsing = enabled
        privacyAppearance.apply(enabled, to: self, animated: animated)
    }
    /// More's panel: the page's address, with large buttons under it.
    let menu = MenuPanel()
    let tabMenu = TabMenuPanel()
    /// More's Find: a find field.
    let find = FindPanel()
    /// Site protections, currently a visual preview.
    let siteSettings = SiteSettingsPanel()
    let appSettings = AppSettingsPanel()
    let privacyPolicy = PrivacyPolicyPanel()
    /// More's Downloads: the list of downloads.
    let downloads = DownloadsPanel()
    let history = HistoryPanel()
    /// Which panel the bar grows into.
    var panel = Panel.search
    /// The search's, and the address's, distance from the panel's top.
    static let searchTop: CGFloat = 20
    /// New Page's plus and More's dots, softer than full text colour; pressed, they darken, or
    /// lighten in dark mode.
    static let plusTint = UIColor.label.withAlphaComponent(0.7)
    static let pressedPlusTint = UIColor.label.withAlphaComponent(0.85)
    /// How small New Page and More get while pressed.
    static let pressedScale: CGFloat = 0.94
    private let separator = UIView()
    private let row = UIView()
    private let tap = UIImpactFeedbackGenerator(style: .rigid)
    private let successFeedback = UINotificationFeedbackGenerator()
    #if DEBUG
    private(set) var translationSuccessFeedbackCount = 0
    private(set) var translationCancellationFeedbackCount = 0
    #endif
    private var copySuccessTask: Task<Void, Never>?
    /// Whichever of the row, the search and the menu is showing, if any.
    private(set) var shown: UIView?
    private var contents: [UIView] { [home, search, menu, tabMenu, find, siteSettings, appSettings, privacyPolicy, downloads, history] }
    /// Collapsed, only the strip remains; set it inside an animation to animate.
    var isCollapsed = false {
        didSet {
            if isCollapsed { cancelTranslationHint(); cancelTranslationStatus() }
            row.alpha = isCollapsed ? 0 : 1
            row.transform = isCollapsed ? CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.92, y: 0.92) : .identity
            row.isUserInteractionEnabled = !isCollapsed
        }
    }
    /// How far the bar has grown into its panel: its top corners round and its hairline fades.
    var panelExpansion: CGFloat = 0 {
        didSet {
            let amount = min(1, max(0, panelExpansion))
            layer.cornerRadius = Self.panelCornerRadius*amount
            separator.alpha = 1-amount
        }
    }

    /// The bar's height over a window with this bottom safe area. Collapsed, it's a strip lower
    /// than the safe area, just clearing the home indicator.
    static func height(collapsed: Bool, safeBottom: CGFloat) -> CGFloat {
        collapsed ? max(safeBottom-14, 14) : rowTop+rowHeight+max(safeBottom-rowTop, 8)
    }

    /// Find's panel's height: the field, just above the keyboard, or the safe area without one.
    static func findHeight(keyboard: CGFloat, safeBottom: CGFloat, answer: CGFloat = 0) -> CGFloat {
        searchTop+SearchPanel.fieldHeight+answer+(keyboard > 0 ? keyboard+12 : max(safeBottom, 16))
    }

    /// More's panel's height: the address, icon tiles, Settings and Downloads above the safe area.
    static func menuHeight(width: CGFloat, safeBottom: CGFloat) -> CGFloat {
        searchTop+MenuPanel.height(width: width)+max(safeBottom, 16)
    }

    static func tabMenuHeight(safeBottom: CGFloat) -> CGFloat {
        searchTop+TabMenuPanel.height+max(safeBottom, 16)
    }

    static func siteSettingsHeight(width: CGFloat, safeBottom: CGFloat) -> CGFloat {
        max(menuHeight(width: width, safeBottom: safeBottom)+48,
            searchTop+SiteSettingsPanel.height+max(safeBottom, 16))
    }

    static func appSettingsHeight(width: CGFloat, safeBottom: CGFloat) -> CGFloat {
        searchTop+AppSettingsPanel.height+max(safeBottom, 16)
    }

    static func privacyPolicyHeight(safeBottom: CGFloat) -> CGFloat {
        searchTop+PrivacyPolicyPanel.height+max(safeBottom, 16)
    }

    static func historyHeight(screenHeight: CGFloat, safeTop: CGFloat) -> CGFloat {
        min(screenHeight*0.8, screenHeight-safeTop-12).rounded()
    }

    /// As Site settings, growing for a longer list.
    static func downloadsHeight(width: CGFloat, safeBottom: CGFloat, rows: Int) -> CGFloat {
        max(menuHeight(width: width, safeBottom: safeBottom)+48,
            searchTop+DownloadsPanel.height(rows: rows)+max(safeBottom, 16))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.background
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.cornerCurve = .continuous
        clipsToBounds = true
        separator.backgroundColor = .separator
        addSubview(separator)
        home.addSubview(row)
        for view in contents {
            addSubview(view)
            view.alpha = 0
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }
        show(home, animated: false)

        newPageButton.layer.cornerCurve = .continuous
        // Rounded like the search field it opens, in proportion.
        newPageButton.layer.cornerRadius = (SearchPanel.cornerRadius*Self.newPageSize.height/SearchPanel.fieldHeight).rounded()
        for glyph in [plusGlyph, waveform] as [UIView] {
            glyph.contentMode = .center
            glyph.isUserInteractionEnabled = false
            newPageButton.addSubview(glyph)
        }
        waveform.alpha = 0
        newPageButton.accessibilityLabel = "New Page"
        moreButton.layer.cornerRadius = Self.menuSize/2
        moreButton.accessibilityLabel = "More"
        for button in [newPageButton, moreButton] {
            button.shrinksWhenPressed(to: Self.pressedScale, filled: true)
            // Softer symbols, deepening under the finger as the fill does.
            button.tintColor = Self.plusTint
            button.addAction(UIAction { [weak button] _ in button?.tintColor = Self.pressedPlusTint },
                             for: [.touchDown, .touchDragEnter])
            button.addAction(UIAction { [weak button] _ in
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    button?.tintColor = Self.plusTint
                }
            }, for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        }

        for button in [tabsButton, newPageButton] { row.addSubview(button) }
        row.addSubview(moreLanding)
        moreLanding.addSubview(moreButton)
        for button in [tabsButton, newPageButton, moreButton]+menu.address.buttons+[search.clearButton, search.privateButton, tabMenu.incognitoRow, tabMenu.historyButton, history.closeButton]+menu.buttons+siteSettings.buttons+appSettings.buttons+privacyPolicy.buttons+downloads.buttons+find.buttons+[find.modeButton, find.sendButton] {
            // A light, crisp tap as the finger lands, rather than a soft thud; actions wait for it to lift.
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self else { return }
                // A running translation reserves its one click for the recognised hold.
                if button === menu.address.translateButton, menu.address.translateButton.symbolName == "page-translation-loading" { return }
                tap.impactOccurred(intensity: 0.5)
            }, for: .touchDown)
        }
        downloads.onTouchDown = { [weak self] in self?.tap.impactOccurred(intensity: 0.5) }
        tap.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A successful copy briefly acknowledges the action in More, using Send/Stop's icon swap.
    func showCopySuccess() {
        successFeedback.notificationOccurred(.success)
        copySuccessTask?.cancel()
        moreButton.setSymbol("checkmark")
        moreButton.accessibilityValue = "Link copied"
        copySuccessTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch { return }
            guard let self else { return }
            moreButton.setSymbol("ellipsis")
            moreButton.accessibilityValue = nil
            copySuccessTask = nil
        }
    }

    func showTranslationSuccess() {
        successFeedback.notificationOccurred(.success)
        #if DEBUG
        translationSuccessFeedbackCount += 1
        #endif
    }

    func showTranslationCancellation() {
        tap.impactOccurred(intensity: 1)
        #if DEBUG
        translationCancellationFeedbackCount += 1
        #endif
    }

    /// Shows the row of buttons, or a panel's contents, swapping them with a quick crossfade, each
    /// softly blurred as it passes.
    func showContents(of panel: Panel?, animated: Bool = true) {
        let view: UIView? = switch panel {
        case .search: search
        case .menu: menu
        case .tabMenu: tabMenu
        case .find: find
        case .siteSettings: siteSettings
        case .appSettings: appSettings
        case .privacyPolicy: privacyPolicy
        case .downloads: downloads
        case .history: history
        case nil: home
        }
        show(view, animated: animated)
    }

    /// Swaps New Page's plus for the waveform while a hold listens, and back, as icons swap elsewhere.
    func setListening(_ listening: Bool, level: (() -> Float)? = nil) {
        guard listening != isListening else { return }
        isListening = listening
        waveform.level = level
        waveform.listen(listening)
        newPageButton.accessibilityLabel = listening ? "Listening" : "New Page"
        let previous: UIView = listening ? plusGlyph : waveform, next: UIView = listening ? waveform : plusGlyph
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else {
            BlurCrossfade.stop(in: newPageButton)
            previous.alpha = 0
            next.alpha = 1
            return
        }
        BlurCrossfade.swap(from: previous, to: next, style: .symbol)
    }

    /// Fades out whatever the bar shows.
    func hideContents(animated: Bool = true) { show(nil, animated: animated) }

    /// The same address surface rides upward with the sheet; only More's tiles swap away.
    func expandAddress(_ url: URL?) {
        search.beginEditingAddress(menu.address, url: url)
        panel = .search
        shown = search
        let earlier = prepareContents(for: search).filter { $0 !== menu }
        search.alpha = 1
        search.transform = .identity
        if UIAccessibility.isReduceMotionEnabled {
            for view in [menu]+earlier { view.alpha = 0; view.transform = .identity }
        } else { BlurCrossfade.swap(from: menu, to: nil, alsoHiding: earlier) }
    }

    func restoreAddress() {
        search.releaseAddress()
        if menu.address.superview !== menu { menu.addSubview(menu.address) }
        menu.setNeedsLayout()
    }

    private func show(_ next: UIView?, animated: Bool) {
        if next !== home { cancelTranslationHint(); cancelTranslationStatus() }
        guard next !== shown else { return }
        let previous = shown
        if previous === history { history.cancelSwipe() }
        shown = next
        let earlier = prepareContents(for: next).filter { $0 !== previous }
        layoutIfNeeded()
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            for view in [previous].compactMap({ $0 })+earlier { view.alpha = 0; view.transform = .identity }
            next?.alpha = 1
            next?.transform = .identity
            return
        }
        BlurCrossfade.swap(from: previous, to: next, alsoHiding: earlier)
    }

    /// Freeze the current poses before starting another swap, and keep every visible outgoing
    /// surface in that swap. Only the incoming surface accepts taps, even during rapid changes.
    private func prepareContents(for next: UIView?) -> [UIView] {
        BlurCrossfade.stop(in: self)
        for view in contents {
            view.isUserInteractionEnabled = view === next
            view.accessibilityElementsHidden = view !== next
            if view !== next, view.alpha == 0 { view.transform = .identity }
        }
        return contents.filter { $0 !== next && $0.alpha > 0 }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        separator.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1/max(1, traitCollection.displayScale))
        // The row keeps its expanded place, so collapsing only fades it as the strip slides down.
        row.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: Self.rowHeight)
        row.center = CGPoint(x: bounds.midX, y: Self.rowTop+Self.rowHeight/2)
        let midY = Self.rowHeight/2, centre = Self.sideCentre
        tabsButton.frame = CGRect(x: centre-22, y: midY-22, width: 44, height: 44)
        // By bounds and center, as pressed buttons are scaled.
        newPageButton.bounds = CGRect(origin: .zero, size: Self.newPageSize)
        newPageButton.center = CGPoint(x: bounds.midX, y: midY)
        // By bounds and center, as they scale as they swap.
        for glyph in [plusGlyph, waveform] as [UIView] {
            glyph.bounds = newPageButton.bounds
            glyph.center = CGPoint(x: newPageButton.bounds.midX, y: newPageButton.bounds.midY)
        }
        let menuSide = Self.menuSize
        moreLanding.bounds = CGRect(x: 0, y: 0, width: menuSide, height: menuSide)
        moreLanding.center = CGPoint(x: bounds.width-centre, y: midY)
        translationStatus?.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        translationStatus?.center = CGPoint(x: moreLanding.center.x-PageTranslationHint.leadingDistance, y: midY)
        moreButton.bounds = CGRect(x: 0, y: 0, width: menuSide, height: menuSide)
        moreButton.center = CGPoint(x: menuSide/2, y: menuSide/2)
        // The panels' contents keep their place from the top as the bar grows beneath them. By
        // bounds and center, as they scale as they swap.
        let place = { (view: UIView, top: CGFloat, height: CGFloat) in
            view.bounds = CGRect(x: 0, y: 0, width: self.bounds.width, height: height)
            view.center = CGPoint(x: self.bounds.midX, y: top+height/2)
        }
        place(home, 0, Self.rowTop+Self.rowHeight)
        // Compact site search only moves the sheet. Its result rows keep their full layout
        // beneath the keyboard, so expanding carries them up rather than resizing each row.
        place(search, Self.searchTop, SearchPanel.height)
        place(menu, Self.searchTop, MenuPanel.height(width: bounds.width))
        place(tabMenu, Self.searchTop, TabMenuPanel.height)
        place(find, Self.searchTop, SearchPanel.fieldHeight+find.answerHeight)
        place(siteSettings, Self.searchTop, SiteSettingsPanel.height)
        place(appSettings, Self.searchTop, AppSettingsPanel.height)
        let safeBottom = window?.safeAreaInsets.bottom ?? 0
        place(privacyPolicy, Self.searchTop, max(0, bounds.height-Self.searchTop-max(safeBottom,16)))
        let historyHeight = Self.historyHeight(screenHeight: superview?.bounds.height ?? bounds.height,
                                               safeTop: window?.safeAreaInsets.top ?? 0)
        place(history, Self.searchTop, max(0, historyHeight-Self.searchTop-max(safeBottom,16)))
        let compact = Self.downloadsHeight(width: bounds.width, safeBottom: safeBottom, rows: downloads.rowCount)
        let base = DownloadsPanel.height(rows: downloads.rowCount)
        // Keep the outgoing collection's viewport until its blurred crossfade has left.
        // Shrinking it immediately would recycle lower cells while they are still visible.
        let desired = panel == .downloads ? base+max(0,bounds.height-compact) : max(base,downloads.bounds.height)
        let available = max(0,bounds.height-Self.searchTop-max(safeBottom,16))
        place(downloads, Self.searchTop, panel == .downloads ? min(desired,available) : desired)
    }
}

extension UIControl {
    /// Darkens at once under the finger, and fades back as it lifts, without scaling.
    func darkensWhenPressed(restingFill: UIColor = SearchPanel.fill, pressedFill: UIColor = SearchPanel.pressedFill,
                            fillView: UIView? = nil) {
        let background = fillView ?? self
        background.backgroundColor = restingFill
        addAction(UIAction { [weak background] _ in
            background?.backgroundColor = pressedFill
        }, for: [.touchDown, .touchDragEnter])
        addAction(UIAction { [weak background] _ in
            guard let background else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                background.backgroundColor = restingFill
            }
        }, for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
    }

    /// Shrinks the control a little under the finger, and springs it back as it lifts. Lay it
    /// out by bounds and center, as frames ignore the scale. `filled` controls take the search
    /// field's fill by default, a little darker while pressed, as native buttons do.
    func shrinksWhenPressed(to scale: CGFloat, filled: Bool = false, restingFill: UIColor = SearchPanel.fill,
                            pressedFill: UIColor = SearchPanel.pressedFill, fillView: UIView? = nil) {
        if filled { darkensWhenPressed(restingFill: restingFill, pressedFill: pressedFill, fillView: fillView) }
        let press = { [weak self] (pressed: Bool) in
            guard let self else { return }
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            UIView.animate(springDuration: pressed ? 0.2 : 0.3, bounce: pressed ? 0 : 0.3, initialSpringVelocity: 0,
                           delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = pressed ? CGAffineTransform(scaleX: scale, y: scale) : .identity
            }
        }
        addAction(UIAction { _ in press(true) }, for: [.touchDown, .touchDragEnter])
        addAction(UIAction { _ in press(false) }, for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
    }
}

/// Tabs, shown as Arc does: a small preview of the page on top of a card tilted behind it.
final class TabsPreviewButton: UIButton {
    static let cardSize = CGSize(width: 26, height: 26)
    /// With the tab switcher open, a rounded square filled like New Page and More, showing how
    /// many tabs there are.
    static let squareSize: CGFloat = 36
    private let back = UIView(), front = UIImageView()
    private let square = UIView()
    let countLabel = UILabel()
    private(set) var showsSwitcher = false
    var count = 1 {
        didSet {
            countLabel.text = "\(count)"
            accessibilityValue = count == 1 ? "1 tab" : "\(count) tabs"
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Tabs"
        for (card, angle, offset) in [(back as UIView, -0.26, CGPoint(x: -4, y: 2)), (front, 0.16, CGPoint(x: 4, y: -2))] {
            card.isUserInteractionEnabled = false
            card.bounds = CGRect(origin: .zero, size: Self.cardSize)
            card.backgroundColor = card === back ? .tertiarySystemFill : .systemBackground
            card.layer.cornerRadius = 3.5
            card.layer.cornerCurve = .continuous
            card.layer.borderWidth = 0.75
            card.layer.borderColor = UIColor.separator.cgColor
            card.layer.shadowColor = UIColor.black.cgColor
            card.layer.shadowOpacity = 0.15
            card.layer.shadowRadius = 2
            card.layer.shadowOffset = CGSize(width: 0, height: 1)
            card.transform = CGAffineTransform(translationX: offset.x, y: offset.y).rotated(by: angle)
            addSubview(card)
        }
        front.contentMode = .scaleToFill
        front.clipsToBounds = true
        front.layer.masksToBounds = true
        square.isUserInteractionEnabled = false
        square.backgroundColor = SearchPanel.fill
        square.layer.cornerCurve = .continuous
        square.layer.cornerRadius = (SearchPanel.cornerRadius*Self.squareSize/SearchPanel.fieldHeight).rounded()
        square.alpha = 0
        square.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        addSubview(square)
        countLabel.font = SearchPanel.roundedFont(ofSize: 15, weight: .semibold, scaled: false)
        countLabel.textColor = BottomBar.plusTint
        countLabel.textAlignment = .center
        countLabel.adjustsFontSizeToFitWidth = true
        countLabel.minimumScaleFactor = 0.6
        countLabel.text = "\(count)"
        countLabel.isAccessibilityElement = false
        square.addSubview(countLabel)
        accessibilityValue = "1 tab"
    }

    /// Swaps the page previews for the empty square as the tab switcher opens, and back as it closes,
    /// with the switcher's quick spring.
    func setShowsSwitcher(_ shows: Bool, animated: Bool) {
        guard shows != showsSwitcher else { return }
        showsSwitcher = shows
        accessibilityLabel = shows ? "Close Tabs" : "Tabs"
        let change = { [self] in
            square.alpha = shows ? 1 : 0
            square.transform = shows ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
            for card in [back, front] { card.alpha = shows ? 0 : 1 }
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { change(); return }
        UIView.animate(springDuration: TabSwitcherView.spring.duration, bounce: 0.2, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A quick side-to-side shake, for a tap that can't be done.
    func shake() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -7, 6, -4, 2.5, -1, 0]
        shake.keyTimes = [0, 0.15, 0.33, 0.5, 0.67, 0.84, 1]
        shake.duration = 0.36
        // Added to the press's shrink, rather than replacing it.
        shake.isAdditive = true
        layer.add(shake, forKey: "refusal-shake")
    }

    /// The current page, as the top card.
    var preview: UIImage? {
        get { front.image }
        set { front.image = newValue }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        square.bounds = CGRect(x: 0, y: 0, width: Self.squareSize, height: Self.squareSize)
        square.center = CGPoint(x: bounds.midX, y: bounds.midY)
        countLabel.frame = square.bounds.insetBy(dx: 4, dy: 0)
        for card in [back, front] {
            card.center = CGPoint(x: bounds.midX, y: bounds.midY)
            card.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        }
    }
}
