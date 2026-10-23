import AppKit

/// A tab's full title and rename hint, in a card like the tabs' previews (pull requests, Gmail,
/// Calendar): just right of the sidebar, centred on the tab, coming and going with the same
/// motion out of the middle of its left edge. Beside a pinned tile it starts level with the
/// tile's bottom and comes out of its bottom-right corner, as the previews do. It never takes
/// clicks or delays the row's hover exit.
@MainActor final class TabTitleTooltip: FlippedView {
    static let inset = NSSize(width: 10, height: 8)
    static let maximumWidth: CGFloat = 520
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let hint = label("Double-click to rename", size: 12)
    private let panel = Surface(radius: FindBar.radius)
    /// The tab's frame in the superview, and the card's left edge.
    private var anchor = NSRect.zero, left: CGFloat = 0, pinned = false
    private(set) var isShown = false
    /// Pinned tiles can't be renamed in place, so theirs leaves the hint out.
    var showsHint = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true; wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        panel.layer?.cornerCurve = .continuous; panel.layer?.borderWidth = 0.5
        panel.layer?.shadowColor = NSColor.black.cgColor; panel.layer?.shadowOpacity = 0.12
        panel.layer?.shadowRadius = 10; panel.layer?.shadowOffset = NSSize(width: 0, height: -3)
        panel.clipsToBounds = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        titleLabel.cell?.truncatesLastVisibleLine = true
        addSubview(panel)
        [titleLabel, hint].forEach { $0.setAccessibilityElement(false); addSubview($0) }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Beside `tab` (its frame in the superview), with its left edge at `left`.
    func present(title: String, beside tab: NSRect, left: CGFloat, pinned: Bool, theme: RiseTheme) {
        let appearing = !isShown
        if appearing { CardMotionAnimator.cancelOut(self) }
        anchor = tab; self.left = left; self.pinned = pinned; isShown = true
        update(title: title, theme: theme)
        isHidden = false
        if appearing { CardMotionAnimator.animateIn(self, CardMotion.selected, tab: tabOrigin) }
    }
    /// Where it comes out of: the middle of its left edge, level with the tab's middle, or a pinned tile's corner.
    private var tabOrigin: CGPoint {
        let point = pinned ? NSPoint(x: anchor.maxX, y: anchor.maxY) : NSPoint(x: frame.minX, y: anchor.midY)
        return CGPoint(x: point.x-frame.minX, y: point.y-frame.minY)
    }
    func update(title: String, theme: RiseTheme) {
        guard let host = superview else { return }
        let available = host.bounds.insetBy(dx: 8, dy: 8)
        let font = titleLabel.font!
        let textWidth = max(1, min(Self.maximumWidth, available.maxX-left)-2*Self.inset.width)
        // NSTextField's cell leaves two points on either side of its glyphs.
        let naturalWidth = max((title as NSString).size(withAttributes: [.font: font]).width, showsHint ? hint.intrinsicContentSize.width : 0)+4
        let width = ceil(min(textWidth, naturalWidth))
        let textHeight = ceil((title as NSString).boundingRect(with: NSSize(width: max(1, width-4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height)
        let hintHeight = showsHint ? 1+ceil(hint.intrinsicContentSize.height) : 0
        let titleHeight = max(1, min(textHeight, available.height-2*Self.inset.height-hintHeight))
        let size = NSSize(width: width+2*Self.inset.width, height: titleHeight+hintHeight+2*Self.inset.height)
        let top = pinned ? anchor.maxY : round(anchor.midY-size.height/2)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frame = NSRect(x: left, y: max(available.minY, min(top, available.maxY-size.height)), width: size.width, height: size.height)
        titleLabel.stringValue = title; titleLabel.textColor = theme.text; hint.textColor = theme.muted
        titleLabel.frame = NSRect(origin: NSPoint(x: Self.inset.width, y: Self.inset.height), size: NSSize(width: width, height: titleHeight))
        hint.frame = NSRect(x: Self.inset.width, y: titleLabel.frame.maxY+1, width: width, height: max(0, hintHeight-1))
        hint.isHidden = !showsHint
        panel.frame = bounds
        panel.fill = theme == .dark ? theme.popup : TabAppearance.selectedFill(theme)
        KeroLitEdge.apply(to: panel, theme: theme)
        // A dark page swallows a light shadow; it needs more weight to read at all.
        panel.layer?.shadowOpacity = theme == .dark ? 0.45 : 0.12
        panel.layer?.shadowPath = PageOutline.path(in: panel.bounds, radius: FindBar.radius, continuous: true)
        CATransaction.commit()
    }
    /// Goes with the previews' motion, or at once with `animated: false`.
    func dismiss(animated: Bool = true) {
        guard isShown else { isHidden = true; return }
        isShown = false
        guard animated else { isHidden = true; return }
        CardMotionAnimator.animateOut(self, CardMotion.selected, tab: tabOrigin) { [weak self] in
            if self?.isShown == false { self?.isHidden = true }
        }
    }
}
