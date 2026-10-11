import UIKit

/// The page's address at the top of More's panel, styled like the search field, with the Mac's
/// controls: Back and Forward close together, each only if there's a page that way, the host behind a padlock on secure pages, then
/// Reload.
final class AddressBar: UIControl {
    static let buttonWidth: CGFloat = 30
    /// The centres of the outer buttons from the ends, and of the inner ones from the outer.
    static let outerCentre: CGFloat = 22
    static let pairSpacing: CGFloat = 30
    /// How small a button gets while pressed.
    static let pressedScale: CGFloat = 0.85

    let backButton = AddressBar.button("chevron.left", size: 15, label: "Back")
    let forwardButton = AddressBar.button("chevron.right", size: 15, label: "Forward")
    let reloadButton = AnimatedSymbolButton(symbol: "arrow.clockwise", pointSize: 14, weight: .bold)
    let lock = UIImageView(image: UIImage(systemName: "lock.fill", withConfiguration:
        UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    let host = UILabel()
    var buttons: [UIButton] { [backButton, forwardButton, reloadButton] }
    private(set) var isEditingURL = false
    private var editor: SearchField?
    private var editingContentsAligned = false
    private var url: URL?
    private var canGoBack = false, canGoForward = false

    private static func button(_ symbol: String, size: CGFloat, weight: UIImage.SymbolWeight = .semibold,
                               label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration:
            UIImage.SymbolConfiguration(pointSize: size, weight: weight)), for: .normal)
        button.tintColor = .label
        button.accessibilityLabel = label
        button.shrinksWhenPressed(to: pressedScale)
        return button
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = SearchPanel.fill
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = SearchPanel.cornerRadius
        lock.tintColor = .systemGreen
        lock.isAccessibilityElement = false
        host.font = SearchPanel.fieldFont
        host.adjustsFontForContentSizeCategory = true
        host.textColor = .label
        host.lineBreakMode = .byTruncatingHead
        host.adjustsFontSizeToFitWidth = true
        host.minimumScaleFactor = 0.85
        host.accessibilityTraits = .staticText
        host.isUserInteractionEnabled = false
        reloadButton.accessibilityLabel = "Reload"
        reloadButton.shrinksWhenPressed(to: Self.pressedScale)
        accessibilityLabel = "Edit Address"
        for view in [lock, host] { addSubview(view) }
        buttons.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows a page's host, without `www.` as Safari does, behind a padlock if it's HTTPS.
    func show(_ url: URL?, canGoBack: Bool, canGoForward: Bool) {
        self.url = url
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        guard !isEditingURL else { return }
        var name = url?.host() ?? ""
        if name.hasPrefix("www.") { name.removeFirst(4) }
        host.text = name
        host.accessibilityLabel = url?.scheme == "https" ? "Secure, \(name)" : name
        lock.isHidden = url?.scheme?.lowercased() != "https" || name.isEmpty
        // Only the ways there are to go show, from the left.
        backButton.isHidden = !canGoBack
        forwardButton.isHidden = !canGoForward
        setNeedsLayout()
    }

    /// Keep the bar intact: its label moves with the sheet while the editor already owns keyboard focus.
    func prepareEditing(_ field: SearchField, url: URL?) {
        isEditingURL = true
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
        reloadButton.setSymbol("xmark")
        reloadButton.accessibilityLabel = "Clear Address"
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
        host.alpha = 1
        host.lineBreakMode = .byTruncatingHead
        host.adjustsFontSizeToFitWidth = true
        lock.alpha = 1
        backButton.alpha = 1
        forwardButton.alpha = 1
        backButton.isUserInteractionEnabled = true
        forwardButton.isUserInteractionEnabled = true
        reloadButton.setSymbol("arrow.clockwise")
        reloadButton.accessibilityLabel = "Reload"
        show(url, canGoBack: canGoBack, canGoForward: canGoForward)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // By bounds and center, as pressed buttons are scaled.
        let width = Self.buttonWidth, height = bounds.height
        let centres = [Self.outerCentre, Self.outerCentre+Self.pairSpacing, bounds.width-Self.outerCentre]
        let forwardCentre = backButton.isHidden ? centres[0] : centres[1]
        for (button, x) in zip(buttons, [centres[0], forwardCentre, centres[2]]) {
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
        let spacing: CGFloat = 5
        let lockWidth = lock.isHidden ? 0 : lock.intrinsicContentSize.width+spacing
        let room = max(0, bounds.width-2*(centres[1]+width/2+4))
        let textWidth = min(host.intrinsicContentSize.width, max(0, room-lockWidth))
        let start = bounds.midX-(lockWidth+textWidth)/2
        lock.frame = CGRect(origin: CGPoint(x: start, y: bounds.midY-lock.intrinsicContentSize.height/2),
                            size: lock.intrinsicContentSize)
        host.frame = CGRect(x: start+lockWidth, y: 0, width: textWidth, height: height)
    }
}

/// More's panel: the page's address where the search field would be, with large square buttons
/// under it.
final class MenuPanel: UIView {
    static let inset: CGFloat = SearchPanel.inset
    static let spacing: CGFloat = 10
    /// Between the address and the tiles.
    static let top: CGFloat = 14
    static let cornerRadius: CGFloat = 20
    static let pressedScale: CGFloat = 0.94
    /// The address and the tiles.
    static func height(width: CGFloat) -> CGFloat { SearchPanel.fieldHeight+top+tileSide(width: width) }

    let address = AddressBar()
    let shareTile = MenuTile(symbol: "square.and.arrow.up", title: "Share")
    let summariseTile = MenuTile(symbol: "text.line.3.summary", title: "Summarise")
    let findTile = MenuTile(symbol: "doc.text.magnifyingglass", title: "Find", label: "Find on Page")
    let copyTile = MenuTile(symbol: "link", title: "Copy", label: "Copy Link")
    var tiles: [MenuTile] { [shareTile, summariseTile, findTile, copyTile] }

    /// Four square tiles across the panel.
    static func tileSide(width: CGFloat) -> CGFloat {
        let count = 4.0
        return max(0, ((width-2*inset-(count-1)*spacing)/count).rounded(.down))
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(address)
        tiles.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if address.superview === self {
            address.frame = CGRect(x: Self.inset, y: 0, width: bounds.width-2*Self.inset, height: SearchPanel.fieldHeight)
        }
        let side = Self.tileSide(width: bounds.width)
        let used = CGFloat(tiles.count)*side+CGFloat(tiles.count-1)*Self.spacing
        var x = (bounds.width-used)/2
        for tile in tiles {
            // By bounds and center, as a pressed tile is scaled.
            tile.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            tile.center = CGPoint(x: x+side/2, y: SearchPanel.fieldHeight+Self.top+side/2)
            x += side+Self.spacing
        }
    }
}

/// A square in More's panel: a symbol over a short title, filled like the search field.
final class MenuTile: UIButton {
    private let symbol = UIImageView()
    private let title = UILabel()

    init(symbol name: String, title text: String, label: String? = nil) {
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
        layer.cornerRadius = MenuPanel.cornerRadius
        symbol.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        symbol.tintColor = .label
        symbol.contentMode = .center
        title.text = text
        // Rounded, like the field's text, and fixed in size, as the tile is.
        title.font = SearchPanel.roundedFont(ofSize: 12, weight: .medium, scaled: false)
        title.textColor = .label
        title.textAlignment = .center
        title.adjustsFontSizeToFitWidth = true
        title.minimumScaleFactor = 0.75
        for view in [symbol, title] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        accessibilityLabel = label ?? text
        shrinksWhenPressed(to: MenuPanel.pressedScale, filled: true)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { alpha = isEnabled ? 1 : 0.4 } }

    override func layoutSubviews() {
        super.layoutSubviews()
        let titleHeight = ceil(title.font.lineHeight)
        symbol.frame = CGRect(x: 0, y: bounds.height*0.2, width: bounds.width, height: bounds.height*0.38)
        title.frame = CGRect(x: 6, y: bounds.height*0.64, width: bounds.width-12, height: titleHeight)
    }
}
