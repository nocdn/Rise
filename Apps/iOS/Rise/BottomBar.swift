import UIKit

/// The toolbar along the bottom edge, as in Arc Search: white, or dark grey in dark mode, with
/// a stack of page previews for Tabs, a rounded button for New Page and a circle for the menu.
/// Scrolling down collapses it to a thin, empty strip; scrolling back up opens it again. New Page
/// grows it into a panel with rounded top corners for a search; More grows it a little, into the
/// page's address and a few actions, whose Find turns it into a find field above the keyboard.
/// Either way the bar's contents swap with a quick, blurred crossfade.
final class BottomBar: UIView {
    enum Panel { case search, menu, find }

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
    let moreButton = UIButton(type: .custom)
    /// The bar's own contents: its row of buttons.
    let home = UIView()
    /// New Page's panel: a search.
    let search = SearchPanel()
    /// More's panel: the page's address, with large buttons under it.
    let menu = MenuPanel()
    /// More's Find: a find field.
    let find = FindPanel()
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
    /// Whichever of the row, the search and the menu is showing, if any.
    private(set) var shown: UIView?
    private var contents: [UIView] { [home, search, menu, find] }
    /// Collapsed, only the strip remains; set it inside an animation to animate.
    var isCollapsed = false {
        didSet {
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

    /// More's panel's height: the address, then a row of square buttons above the safe area.
    static func menuHeight(width: CGFloat, safeBottom: CGFloat) -> CGFloat {
        searchTop+MenuPanel.height(width: width)+max(safeBottom, 16)
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
        moreButton.setImage(UIImage(systemName: "ellipsis", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
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

        for button in [tabsButton, newPageButton, moreButton] { row.addSubview(button) }
        for button in [tabsButton, newPageButton, moreButton]+menu.address.buttons+menu.tiles+find.buttons+[find.modeButton, find.sendButton] {
            // A light, crisp tap as the finger lands, rather than a soft thud; actions wait for it to lift.
            button.addAction(UIAction { [weak self] _ in self?.tap.impactOccurred(intensity: 0.5) }, for: .touchDown)
        }
        tap.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the row of buttons, or a panel's contents, swapping them with a quick crossfade, each
    /// softly blurred as it passes.
    func showContents(of panel: Panel?, animated: Bool = true) {
        let view: UIView? = switch panel {
        case .search: search
        case .menu: menu
        case .find: find
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
        for view in contents {
            view.isUserInteractionEnabled = view === search
            view.accessibilityElementsHidden = view !== search
        }
        search.alpha = 1
        search.transform = .identity
        BlurCrossfade.stop(in: self)
        if UIAccessibility.isReduceMotionEnabled { menu.alpha = 0 }
        else { BlurCrossfade.swap(from: menu, to: nil) }
    }

    func restoreAddress() {
        search.releaseAddress()
        if menu.address.superview !== menu { menu.addSubview(menu.address) }
        menu.setNeedsLayout()
    }

    private func show(_ next: UIView?, animated: Bool) {
        guard next !== shown else { return }
        let previous = shown
        shown = next
        for view in contents {
            view.isUserInteractionEnabled = view === next
            view.accessibilityElementsHidden = view !== next
        }
        layoutIfNeeded()
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            previous?.alpha = 0
            next?.alpha = 1
            next?.transform = .identity
            return
        }
        BlurCrossfade.swap(from: previous, to: next)
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
        moreButton.bounds = CGRect(x: 0, y: 0, width: menuSide, height: menuSide)
        moreButton.center = CGPoint(x: bounds.width-centre, y: midY)
        // The panels' contents keep their place from the top as the bar grows beneath them. By
        // bounds and center, as they scale as they swap.
        let place = { (view: UIView, top: CGFloat, height: CGFloat) in
            view.bounds = CGRect(x: 0, y: 0, width: self.bounds.width, height: height)
            view.center = CGPoint(x: self.bounds.midX, y: top+height/2)
        }
        place(home, 0, Self.rowTop+Self.rowHeight)
        place(search, Self.searchTop, SearchPanel.height)
        place(menu, Self.searchTop, MenuPanel.height(width: bounds.width))
        place(find, Self.searchTop, SearchPanel.fieldHeight+find.answerHeight)
    }
}

extension UIControl {
    /// Shrinks the control a little under the finger, and springs it back as it lifts. Lay it
    /// out by bounds and center, as frames ignore the scale. `filled` controls take the search
    /// field's fill, a little darker while pressed, as native buttons do.
    func shrinksWhenPressed(to scale: CGFloat, filled: Bool = false) {
        if filled { backgroundColor = SearchPanel.fill }
        let press = { [weak self] (pressed: Bool) in
            guard let self else { return }
            // Darkens at once under the finger, and fades back as it lifts.
            if filled, pressed { backgroundColor = SearchPanel.pressedFill }
            if filled, !pressed {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.backgroundColor = SearchPanel.fill
                }
            }
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
