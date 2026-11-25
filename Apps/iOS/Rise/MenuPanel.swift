import UIKit

/// The page's address at the top of More's panel, styled like the search field, with the Mac's
/// controls: Back and Forward close together, each only if there's a page that way, the host behind a transport padlock, then
/// Reload.
final class AddressBar: UIControl {
    static let buttonWidth: CGFloat = 30
    /// The centres of the outer buttons from the ends, and of the inner ones from the outer.
    static let outerCentre: CGFloat = 22
    static let pairSpacing: CGFloat = 30
    static let translationSpacing: CGFloat = 34
    /// How small a button gets while pressed.
    static let pressedScale: CGFloat = 0.85

    let backButton = HistoryChevronButton(.back)
    let forwardButton = HistoryChevronButton(.forward)
    let translateButton = AnimatedSymbolButton(symbol: "translate", pointSize: 14, weight: .bold)
    let reloadButton = AnimatedSymbolButton(symbol: "arrow.clockwise", pointSize: 14, weight: .bold)
    let lock = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    let host = UILabel()
    var buttons: [UIButton] { [backButton, forwardButton, translateButton, reloadButton] }
    private var offersTranslation = false
    private var pageIsLoading = false
    func showLoading(_ loading: Bool) {
        pageIsLoading = loading
        guard !isEditingURL else { return }
        reloadButton.setSymbol(loading ? "xmark" : "arrow.clockwise")
        reloadButton.accessibilityLabel = loading ? "Stop Loading" : "Reload"
    }
    private(set) var isEditingURL = false
    private var editor: SearchField?
    private var editingContentsAligned = false
    private var url: URL?
    private var canGoBack = false, canGoForward = false
    private var shownHistory = (back: false, forward: false)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = SearchPanel.fill
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = SearchPanel.cornerRadius
        lock.tintColor = .systemGreen
        lock.isAccessibilityElement = false
        host.font = SearchPanel.font
        host.adjustsFontForContentSizeCategory = true
        host.textColor = .label
        host.lineBreakMode = .byTruncatingHead
        host.adjustsFontSizeToFitWidth = true
        host.minimumScaleFactor = 0.85
        host.accessibilityTraits = .staticText
        host.isUserInteractionEnabled = false
        reloadButton.accessibilityLabel = "Reload"
        reloadButton.shrinksWhenPressed(to: Self.pressedScale)
        translateButton.setGlyph(UIImage(named: "MenuTranslate"), name: "page-translation")
        translateButton.shrinksWhenPressed(to: Self.pressedScale)
        translateButton.isHidden = true
        translateButton.accessibilityLabel = "Translate to English"
        accessibilityLabel = "Edit Address"
        // Hidden until there's a page that way, as `shownHistory` starts out.
        backButton.isHidden = true
        forwardButton.isHidden = true
        for view in [lock, host] { addSubview(view) }
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A quick tap as More springs open can lift on the address where it's drawn yet further from
    /// where it's laid out than UIKit allows for a touch up inside; it still edits the address.
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        super.endTracking(touch, with: event)
        guard let touch, !isTouchInside, let window, let drawn = layer.presentation() else { return }
        let point = drawn.convert(touch.location(in: window), from: window.layer.presentation() ?? window.layer)
        if drawn.bounds.contains(point) { sendActions(for: .primaryActionTriggered) }
    }

    func showTranslation(_ state: MobilePageTranslation.State) {
        offersTranslation = state.available
        translateButton.isHidden = !offersTranslation || isEditingURL
        translateButton.isSelected = state.enabled
        // Off is a synchronous colour change. Only the glyph ↔ spinner swaps animate.
        translateButton.tintColor = state.enabled && !state.busy ? .systemBlue : .label
        if state.busy { translateButton.setLoading(name: "page-translation-loading") }
        else { translateButton.setGlyph(UIImage(named: "MenuTranslate"), name: "page-translation") }
        translateButton.accessibilityLabel = state.busy ? "Translation progress" : state.enabled ? "Show Original" : "Translate to English"
        translateButton.accessibilityHint = state.busy ? "Tap for status. Hold to cancel translation." : nil
        translateButton.accessibilityValue = state.busy ? "Translating to English" : state.enabled ? "Translated to English" : nil
    }

    /// Shows the host and its transport: green/closed for HTTPS, red/open for HTTP.
    func show(_ url: URL?, canGoBack: Bool, canGoForward: Bool) {
        self.url = url
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        guard !isEditingURL else { return }
        var name = url?.host() ?? ""
        if name.hasPrefix("www.") { name.removeFirst(4) }
        host.text = name
        let connection = PageConnection(url)
        host.accessibilityLabel = connection.map { "\($0.accessibilityLabel), \(name)" } ?? name
        lock.image = connection?.image(pointSize: 12)
        lock.tintColor = connection?.tint
        lock.isHidden = connection == nil || name.isEmpty
        setNeedsLayout()
    }

    /// WebKit delivers Back and Forward availability separately. Resolve them together during
    /// layout so a temporary neither/both state cannot break the sole chevron's turn.
    private func updateHistoryButtons() {
        guard shownHistory.back != canGoBack || shownHistory.forward != canGoForward else { return }
        let was = shownHistory
        shownHistory = (canGoBack, canGoForward)
        let previous = was.back != was.forward ? (was.back ? backButton : forwardButton) : nil
        let next = canGoBack != canGoForward ? (canGoBack ? backButton : forwardButton) : nil
        let animates = window != nil && (superview?.alpha ?? 0) > 0 && !UIAccessibility.isReduceMotionEnabled
        if let previous, let next, previous !== next, animates {
            settleHistoryButtons()
            next.turn(from: previous)
            return
        }
        backButton.resetDirection()
        forwardButton.resetDirection()
        let changes = [(backButton, was.back, canGoBack), (forwardButton, was.forward, canGoForward)].filter { $0.1 != $0.2 }
        let entering = changes.filter { $0.2 }.map(\.0), leaving = changes.filter { !$0.2 }.map(\.0)
        guard animates, entering.count < 2 else { settleHistoryButtons(); return }
        // Otherwise a chevron comes and goes as Ask's Send does, and Forward makes room for Back,
        // or takes its place, as Ask's button moves over for Send.
        for button in entering where button.isHidden {
            button.alpha = 0
            button.isHidden = false
        }
        BlurCrossfade.swap(from: leaving.first, to: entering.first, alsoHiding: Array(leaving.dropFirst()),
                           style: .symbol) { [weak self] in
            guard let self else { return }
            for (button, shown) in [(backButton, shownHistory.back), (forwardButton, shownHistory.forward)]
                where !shown && button.alpha == 0 {
                button.isHidden = true
                button.alpha = 1
            }
        }
        UIView.animate(springDuration: 0.3, bounce: 0.25, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.forwardButton.center.x = self.forwardCentre
        }
    }

    /// Shows just the chevrons there are pages for, cutting short any fade.
    private func settleHistoryButtons() {
        BlurCrossfade.stop(in: self)
        for (button, shown) in [(backButton, shownHistory.back), (forwardButton, shownHistory.forward)] {
            button.isHidden = !shown
            guard !shown || button.alpha < 1 else { continue }
            button.alpha = 1
            button.transform = .identity
        }
    }

    /// The centres of the outer buttons from the ends, and of the inner ones from the outer.
    private var centres: [CGFloat] {
        [Self.outerCentre, Self.outerCentre+Self.pairSpacing, bounds.width-Self.outerCentre]
    }
    /// Forward sits beside Back, or in its place when there's no page back.
    private var forwardCentre: CGFloat { shownHistory.back ? centres[1] : centres[0] }

    /// Keep the bar intact: its label moves with the sheet while the editor already owns keyboard focus.
    func prepareEditing(_ field: SearchField, url: URL?) {
        isEditingURL = true
        translateButton.isHidden = true
        editingContentsAligned = false
        editor = field
        field.frame = bounds
        field.backgroundColor = .clear
        field.clearButtonMode = .never
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: SearchPanel.fieldHeight))
        field.rightViewMode = .always
        field.alpha = 0
        field.isUserInteractionEnabled = false
        insertSubview(field, belowSubview: host)
        host.text = url?.absoluteString ?? ""
        host.lineBreakMode = .byTruncatingTail
        host.adjustsFontSizeToFitWidth = false
        settleHistoryButtons()
        reloadButton.setSymbol("xmark")
        reloadButton.accessibilityLabel = "Clear Address"
        // While the address is being edited, the button is X, which only clears.
        reloadButton.isContextMenuInteractionEnabled = false
        backButton.isUserInteractionEnabled = false
        forwardButton.isUserInteractionEnabled = false
        setNeedsLayout()
    }

    /// Defer the target layout until the sheet's animation block; UIKit can lay out a reparented
    /// field early, which otherwise makes its label jump to the left before the spring starts.
    func alignEditingContents() {
        editingContentsAligned = true
        setNeedsLayout()
        layoutIfNeeded()
    }

    func finishEditing() {
        guard let editor else { return }
        host.alpha = 0
        lock.isHidden = true
        backButton.isHidden = true
        forwardButton.isHidden = true
        editor.alpha = 1
        editor.isUserInteractionEnabled = true
    }

    func endEditingAddress() {
        editor = nil
        editingContentsAligned = false
        isEditingURL = false
        reloadButton.isContextMenuInteractionEnabled = true
        translateButton.isHidden = !offersTranslation
        host.alpha = 1
        host.lineBreakMode = .byTruncatingHead
        host.adjustsFontSizeToFitWidth = true
        lock.alpha = 1
        settleHistoryButtons()
        backButton.isUserInteractionEnabled = true
        forwardButton.isUserInteractionEnabled = true
        showLoading(pageIsLoading)
        show(url, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !isEditingURL { updateHistoryButtons() }
        // By bounds and center, as pressed buttons are scaled.
        let width = Self.buttonWidth, height = bounds.height
        for (button, x) in zip(buttons, [centres[0], forwardCentre, centres[2]-Self.translationSpacing, centres[2]]) {
            button.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            button.center = CGPoint(x: x, y: bounds.midY)
        }
        if let editor {
            editor.frame = bounds
            if editingContentsAligned {
                host.frame = editor.textRect(forBounds: bounds)
                lock.alpha = 0
                backButton.alpha = 0
                forwardButton.alpha = 0
            }
            return
        }
        // The host and padlock together sit in the middle, as far as the buttons allow.
        let spacing: CGFloat = 7
        let lockWidth = lock.isHidden ? 0 : lock.intrinsicContentSize.width+spacing
        let room = max(0, bounds.width-2*(centres[1]+width/2+4))
        let textWidth = min(host.intrinsicContentSize.width, max(0, room-lockWidth))
        let start = bounds.midX-(lockWidth+textWidth)/2
        lock.frame = CGRect(origin: CGPoint(x: start, y: bounds.midY-lock.intrinsicContentSize.height/2),
                            size: lock.intrinsicContentSize)
        host.frame = CGRect(x: start+lockWidth, y: 0, width: textWidth, height: height)
    }
}

/// More's panel: the page's address where the search field would be, with large buttons under it,
/// a little less tall than wide.
final class MenuPanel: UIView {
    static let inset: CGFloat = SearchPanel.inset
    static let spacing: CGFloat = 10
    /// Between the address and the tiles.
    static let top: CGFloat = 14
    static let cornerRadius: CGFloat = 20
    static let pressedScale: CGFloat = 0.94
    private static let copyIconGreen = UIColor { traits in
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor.systemGreen.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return UIColor(red: red*0.92, green: green*0.92, blue: blue*0.92, alpha: alpha)
    }
    static let settingsButtonHeight: CGFloat = 52
    /// Between the tiles and Settings and Downloads, a little more than between the tiles.
    static let settingsGap: CGFloat = 14
    /// The address, icon tiles, then Settings and Downloads side by side.
    static func height(width: CGFloat) -> CGFloat {
        SearchPanel.fieldHeight+top+tileSize(width: width).height+settingsGap+settingsButtonHeight
    }

    let address = AddressBar()
    let shareTile = MenuTile(symbol: "square.and.arrow.up", label: "Share", symbolOffsetY: -1)
    let summariseTile = MenuTile(image: MenuIcons.summarise, label: "Summarise")
    let findTile = MenuTile(image: MenuIcons.findOnPage, label: "Find on Page", symbolOffsetY: 1, symbolOpacity: 0.9)
    let copyTile = MenuTile(symbol: "link", label: "Copy Link")
    let siteSettingsButton = MenuTile(image: MenuIcons.siteSettings, label: "Settings", showsLabel: true)
    let downloadsButton = MenuTile(image: MenuIcons.downloads, label: "Downloads", showsLabel: true)
    let downloadProgress = DownloadButtonProgress()
    var tiles: [MenuTile] { [shareTile, summariseTile, findTile, copyTile] }
    var buttons: [UIButton] { tiles+[siteSettingsButton, downloadsButton] }
    /// The tiles' height, as a share of their width.
    static let tileProportion: CGFloat = 0.85

    /// Four tiles across the panel.
    static func tileSize(width: CGFloat) -> CGSize {
        let count = 4.0
        let side = max(0, ((width-2*inset-(count-1)*spacing)/count).rounded(.down))
        return CGSize(width: side, height: (side*tileProportion).rounded())
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(address)
        buttons.forEach(addSubview)
        downloadsButton.clipsToBounds = true
        downloadsButton.insertSubview(downloadProgress, at: 0)
        shareTile.pressedIconColor = .systemBlue
        summariseTile.pressedIconColor = .systemRed
        findTile.pressedIconColor = .systemPurple
        copyTile.pressedIconColor = Self.copyIconGreen
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateDownloadProgress(_ items: [MobileDownloads.Item]) {
        switch downloadProgress.update(items) {
        case .running(_, let count): downloadsButton.accessibilityValue = count == 1 ? "1 download in progress" : "\(count) downloads in progress"
        case .ended: downloadsButton.accessibilityValue = nil
        case .idle: break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if address.superview === self {
            address.frame = CGRect(x: Self.inset, y: 0, width: bounds.width-2*Self.inset, height: SearchPanel.fieldHeight)
        }
        let size = Self.tileSize(width: bounds.width)
        let used = CGFloat(tiles.count)*size.width+CGFloat(tiles.count-1)*Self.spacing
        var x = (bounds.width-used)/2
        for tile in tiles {
            // By bounds and center, as a pressed tile is scaled.
            tile.bounds = CGRect(origin: .zero, size: size)
            tile.center = CGPoint(x: x+size.width/2, y: SearchPanel.fieldHeight+Self.top+size.height/2)
            x += size.width+Self.spacing
        }
        // Settings and Downloads side by side, each as wide as two tiles.
        let half = 2*size.width+Self.spacing, start = (bounds.width-used)/2
        let y = SearchPanel.fieldHeight+Self.top+size.height+Self.settingsGap+Self.settingsButtonHeight/2
        for (index, button) in [siteSettingsButton, downloadsButton].enumerated() {
            button.bounds = CGRect(x: 0, y: 0, width: half, height: Self.settingsButtonHeight)
            button.center = CGPoint(x: start+CGFloat(index)*(half+Self.spacing)+half/2, y: y)
        }
        downloadProgress.frame = downloadsButton.bounds
    }
}

/// More in the tab switcher: Incognito mode's switch, then History and Archived Tabs, using the address row's
/// geometry and the usual button feedback.
final class TabMenuPanel: UIView {
    static let incognitoRowHeight: CGFloat = 52
    let incognitoRow = SettingsToggleRow("Incognito mode", icon: nil, colour: .label, on: false)
    let historyButton = MenuTile(image: MenuIcons.history, label: "History", showsLabel: true, labelFont: SearchPanel.fieldFont)
    let archivedButton = MenuTile(image: UIImage(systemName: "archivebox", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)),
                                  label: "Archived Tabs", showsLabel: true, labelFont: SearchPanel.fieldFont)
    static var height: CGFloat { incognitoRowHeight+2*(MenuPanel.spacing+SearchPanel.fieldHeight) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        incognitoRow.layer.cornerCurve = .continuous
        incognitoRow.layer.cornerRadius = SearchPanel.cornerRadius
        incognitoRow.clipsToBounds = true
        incognitoRow.toggle.onTintColor = SiteSettingsPanel.switchBlue
        historyButton.layer.cornerRadius = SearchPanel.cornerRadius
        archivedButton.layer.cornerRadius = SearchPanel.cornerRadius
        addSubview(incognitoRow)
        addSubview(historyButton)
        addSubview(archivedButton)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(0, bounds.width-2*MenuPanel.inset)
        // By bounds and center, as a pressed row is scaled.
        incognitoRow.bounds = CGRect(x: 0, y: 0, width: width, height: Self.incognitoRowHeight)
        incognitoRow.center = CGPoint(x: bounds.midX, y: Self.incognitoRowHeight/2)
        historyButton.bounds = CGRect(x: 0, y: 0, width: width, height: SearchPanel.fieldHeight)
        historyButton.center = CGPoint(x: bounds.midX, y: Self.incognitoRowHeight+MenuPanel.spacing+SearchPanel.fieldHeight/2)
        archivedButton.bounds = historyButton.bounds
        archivedButton.center = CGPoint(x: bounds.midX, y: historyButton.center.y+MenuPanel.spacing+SearchPanel.fieldHeight)
    }
}

/// A button in More's panel: a symbol, filled like the search field.
final class MenuTile: UIButton {
    private let symbol = UIImageView()
    private let symbolOffsetY: CGFloat
    private let title: UILabel?
    var pressedIconColor: UIColor = .label

    convenience init(symbol name: String, label: String, symbolOffsetY: CGFloat = 0) {
        self.init(image: UIImage(systemName: name, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)), label: label, symbolOffsetY: symbolOffsetY)
    }

    init(image: UIImage?, label: String, symbolOffsetY: CGFloat = 0, showsLabel: Bool = false, symbolOpacity: CGFloat = 1,
         labelFont: UIFont? = nil) {
        self.symbolOffsetY = symbolOffsetY
        title = showsLabel ? UILabel() : nil
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
        layer.cornerRadius = MenuPanel.cornerRadius
        symbol.image = image
        symbol.tintColor = .label
        symbol.alpha = symbolOpacity
        symbol.contentMode = .center
        symbol.isUserInteractionEnabled = false
        addSubview(symbol)
        if let title {
            title.text = label
            title.font = labelFont ?? SearchPanel.roundedFont(ofSize: 16, weight: .semibold)
            title.adjustsFontForContentSizeCategory = true
            title.textColor = .label
            title.isUserInteractionEnabled = false
            title.isAccessibilityElement = false
            addSubview(title)
        }
        accessibilityLabel = label
        shrinksWhenPressed(to: MenuPanel.pressedScale, filled: true)
        addAction(UIAction { [weak self] _ in
            guard let self, isEnabled else { return }
            symbol.tintColor = pressedIconColor
        }, for: [.touchDown, .touchDragEnter])
        addAction(UIAction { [weak self] _ in
            guard let self else { return }
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.symbol.tintColor = .label
            }
        }, for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIconColor(_ color: UIColor) { symbol.tintColor = color }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.4
            if !isEnabled { symbol.tintColor = .label }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let title else { symbol.frame = bounds.offsetBy(dx: 0, dy: symbolOffsetY); return }
        let iconSide: CGFloat = 28, gap: CGFloat = 10
        let size = title.sizeThatFits(CGSize(width: max(0, bounds.width-iconSide-gap-32), height: bounds.height))
        let x = bounds.midX-(iconSide+gap+size.width)/2
        symbol.frame = CGRect(x: x, y: bounds.midY-iconSide/2+symbolOffsetY, width: iconSide, height: iconSide)
        title.frame = CGRect(x: x+iconSide+gap, y: bounds.midY-size.height/2, width: size.width, height: size.height)
    }
}
