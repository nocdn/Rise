import ImageIO
import UIKit
import WebKit

/// A tab: its page, the pages a Peek replaced in it (held for Back), how it last looked, and its icon.
@MainActor final class BrowserTab {
    var webView: WKWebView
    var previousPages: [WKWebView] = []
    /// The page, strip included, as it was when last left, for its card in the tab switcher.
    var snapshot: UIImage?
    /// The page's icon, or nil for the blank square.
    private(set) var favicon: UIImage? { didSet { onFaviconChange?() } }
    var onFaviconChange: (() -> Void)?
    /// The page the icon was looked up for, so it's looked up once a page.
    private var faviconPage: URL?
    private static var icons: [URL: UIImage] = [:]

    init(webView: WKWebView) { self.webView = webView }

    var title: String {
        if let title = webView.title, !title.isEmpty { return title }
        return webView.url?.host() ?? "New Page"
    }

    /// The icons the page declares, as bitmaps can be drawn here, in the page's own order.
    private static let iconScript = """
    (() => {
      const links = Array.from(document.querySelectorAll('link[rel][href]'));
      const rels = link => link.rel.toLowerCase().split(/\\s+/);
      const usable = link => !/svg/i.test(link.type) && !/\\.svg([?#]|$)/i.test(link.href)
        && (!link.media || matchMedia(link.media).matches);
      const icons = links.filter(link => rels(link).includes('icon') && usable(link));
      const touch = links.filter(link => rels(link).some(rel => rel.startsWith('apple-touch-icon')) && usable(link));
      return icons.concat(touch).map(link => link.href);
    })()
    """

    /// Looks up the page's icon: the first it declares that loads, else the site's favicon.ico.
    func loadFavicon() {
        let web = webView
        guard let page = web.url, page != faviconPage else { return }
        faviconPage = page
        guard ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { favicon = nil; return }
        web.evaluateJavaScript(Self.iconScript) { [weak self] result, _ in
            guard let self, webView === web, faviconPage == page else { return }
            var candidates = ((result as? [String]) ?? []).compactMap(URL.init(string:))
                .filter { ["http", "https", "data"].contains($0.scheme?.lowercased() ?? "") }
            if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL { candidates.append(fallback) }
            Task { [weak self] in
                for url in candidates {
                    guard let image = await Self.icon(at: url) else { continue }
                    if let self, faviconPage == page { favicon = image }
                    return
                }
                if let self, faviconPage == page { favicon = nil }
            }
        }
    }

    private static func icon(at url: URL) async -> UIImage? {
        if let icon = icons[url] { return icon }
        guard let loaded = try? await URLSession.shared.data(from: url),
              (loaded.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let icon = decode(loaded.0) else { return nil }
        icons[url] = icon
        return icon
    }

    /// The largest of the icon's sizes, as a .ico holds several.
    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let largest = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }
            .max { $0.width < $1.width }
        return largest.map { UIImage(cgImage: $0) }
    }
}

/// A page's icon, its corners clipped a little as the Mac app's are, so square icons round off and
/// transparent or round ones keep their shape; without one, the Mac app's blank square.
final class FaviconView: UIView {
    static let size: CGFloat = 16
    private let imageView = UIImageView()
    private let placeholder = UIView()
    var image: UIImage? {
        didSet {
            imageView.image = image
            placeholder.isHidden = image != nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        imageView.contentMode = .scaleAspectFit
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)
        placeholder.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0x66/255, alpha: 1) : UIColor(white: 0xD5/255, alpha: 1) }
        placeholder.layer.cornerCurve = .continuous
        addSubview(placeholder)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // As on the Mac: 4 points in 16 for the clip, and a 14-point square with 3-point corners.
        let scale = min(bounds.width, bounds.height)/Self.size
        layer.cornerRadius = 4*scale
        imageView.frame = bounds
        let side = 14*scale
        placeholder.frame = CGRect(x: bounds.midX-side/2, y: bounds.midY-side/2, width: side, height: side)
        placeholder.layer.cornerRadius = 3*scale
    }
}

/// A page's picture on a card, as wide as the card and from the top. `crop` takes the status bar's
/// strip off as the page settles into a card.
final class TabCard: UIView {
    let image = UIImageView()
    /// The page's size in the window, strip included, and the strip's height.
    var pageSize = CGSize(width: 1, height: 1) { didSet { setNeedsLayout() } }
    var stripHeight: CGFloat = 0 { didSet { setNeedsLayout() } }
    /// 0 shows the page whole, as in the window; 1 crops its strip off, as on a card.
    var crop: CGFloat = 1 { didSet { setNeedsLayout() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        backgroundColor = .systemBackground
        image.contentMode = .scaleToFill
        addSubview(image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = bounds.width/max(1, pageSize.width)
        image.frame = CGRect(x: 0, y: -stripHeight*scale*crop, width: bounds.width, height: pageSize.height*scale)
    }
}

/// A tab in the switcher: its card, with a close button on it, and its icon and title under it.
final class TabCell: UIView {
    let card = TabCard()
    let closeButton = UIButton(type: .system)
    /// The icon and title, side by side and centred, revealed together.
    let caption = UIView()
    let favicon = FaviconView()
    let title = UILabel()
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    private static let iconGap: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.layer.cornerRadius = TabSwitcherView.cornerRadius
        card.isAccessibilityElement = true
        card.accessibilityTraits = .button
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(cardTapped)))
        addSubview(card)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration:
            UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)), for: .normal)
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        closeButton.layer.cornerRadius = TabSwitcherView.closeSize/2
        closeButton.accessibilityLabel = "Close Tab"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose() }, for: .primaryActionTriggered)
        addSubview(closeButton)
        title.font = SearchPanel.roundedFont(ofSize: 13, weight: .semibold, scaled: false)
        title.textColor = .label
        title.lineBreakMode = .byTruncatingTail
        title.isAccessibilityElement = false
        caption.isUserInteractionEnabled = false
        caption.addSubview(favicon)
        caption.addSubview(title)
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func cardTapped() { onSelect() }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height-TabSwitcherView.titleHeight)
        card.accessibilityLabel = title.text
        let close = TabSwitcherView.closeSize
        closeButton.frame = CGRect(x: card.frame.maxX-7-close, y: 7, width: close, height: close)
        caption.bounds = CGRect(x: 0, y: 0, width: bounds.width-12, height: TabSwitcherView.titleHeight-10)
        caption.center = CGPoint(x: bounds.midX, y: card.frame.maxY+7+caption.bounds.height/2)
        let icon = FaviconView.size, lead = icon+Self.iconGap
        let text = min(ceil(title.sizeThatFits(caption.bounds.size).width), caption.bounds.width-lead)
        let left = ((caption.bounds.width-lead-text)/2).rounded()
        favicon.frame = CGRect(x: left, y: ((caption.bounds.height-icon)/2).rounded(), width: icon, height: icon)
        title.frame = CGRect(x: left+lead, y: 0, width: text, height: caption.bounds.height)
    }
}

/// The tabs as cards in two columns over a blur of the page, as in Safari. The current page shrinks
/// into its card as the blur comes in and the other cards fade, grow and sharpen in around it, their
/// titles last; choosing a card grows it back into the page. A swipe up the bottom bar shrinks the
/// page with the finger, and drops it into its card when let go. Every move can be turned around
/// partway: Tabs again, a tap on the landing page, or a swipe up as it grows back.
final class TabSwitcherView: UIView {
    static let inset: CGFloat = 16
    static let spacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    /// The cards' height for their width.
    static let cardAspect: CGFloat = 1.42
    static let titleHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 18
    static let closeSize: CGFloat = 24
    /// As quick as the app's other springs, with a little bounce as the page lands in its card.
    static let spring = (duration: 0.3, bounce: 0.14)
    /// Growing back into the page, without overshoot, which would fall outside the screen.
    static let returnSpring = (duration: 0.28, bounce: 0.0)
    static let blur = UIBlurEffect(style: .systemMaterial)
    /// How far up the swipe goes, as a share of the height, for the page to shrink all it will.
    static let swipeTravel: CGFloat = 0.45
    /// How far the finger moves for a page caught partway to come under it.
    static let catchTravel: CGFloat = 120

    private enum Heading { case card, page }

    private let backdrop = UIImageView()
    private let effect = UIVisualEffectView(effect: nil)
    let scroll = UIScrollView()
    /// Holds the cards, so they can fade, grow and sharpen in as one.
    let grid = UIView()
    private(set) var cells: [TabCell] = []
    private(set) var current = 0
    /// The page on its way into, or out of, its card, and which way it's going; nil while a finger
    /// holds it.
    private(set) var moving: TabCard?
    private var heading: Heading?
    /// Counts the page's moves, so one that's been turned around doesn't finish.
    private var move = 0
    /// Blurs the page in and out, and back partway; it pauses at either end rather than finishing.
    private var blurAnimator: UIViewPropertyAnimator?
    /// How far a swipe up has shrunk the page, from 0 to 1.
    private(set) var swipeProgress: CGFloat = 0
    /// A page the swipe caught as it moved: how far it had shrunk, and where it was, which it leaves
    /// for under the finger as the finger moves.
    private var caught: (progress: CGFloat, frame: CGRect, crop: CGFloat, radius: CGFloat)?
    var pageSize = CGSize(width: 1, height: 1)
    var stripHeight: CGFloat = 0
    /// Clear of the status bar, and of the bottom bar.
    var topInset: CGFloat = 0 { didSet { setNeedsLayout() } }
    var bottomInset: CGFloat = 0 { didSet { setNeedsLayout() } }
    var onSelect: (Int) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        addSubview(backdrop)
        addSubview(effect)
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
        scroll.addSubview(grid)
    }

    required init?(coder: NSCoder) { fatalError() }

    var cardSize: CGSize {
        let width = max(1, ((bounds.width-2*Self.inset-Self.spacing)/2).rounded(.down))
        return CGSize(width: width, height: (width*Self.cardAspect).rounded())
    }

    private var gridHeight: CGFloat {
        let rows = CGFloat((cells.count+1)/2), cell = cardSize.height+Self.titleHeight
        return max(0, rows*cell+(rows-1)*Self.rowSpacing)
    }

    /// A cell's frame in the grid.
    func cellFrame(_ index: Int) -> CGRect {
        let card = cardSize, row = CGFloat(index/2), column = CGFloat(index%2)
        return CGRect(x: Self.inset+column*(card.width+Self.spacing), y: row*(card.height+Self.titleHeight+Self.rowSpacing),
                      width: card.width, height: card.height+Self.titleHeight)
    }

    /// Where a tab's card sits on screen once settled, in this view.
    private func cardFrame(_ index: Int) -> CGRect {
        let cell = cellFrame(index)
        return CGRect(x: cell.minX, y: cell.minY-scroll.contentOffset.y, width: cell.width, height: cardSize.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        effect.frame = bounds
        scroll.frame = bounds
        scroll.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        scroll.verticalScrollIndicatorInsets = scroll.contentInset
        let height = gridHeight
        scroll.contentSize = CGSize(width: bounds.width, height: height)
        // By bounds and center, as the grid grows in, around its anchor.
        grid.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        grid.center = CGPoint(x: bounds.midX, y: grid.layer.anchorPoint.y*height)
        for (index, cell) in cells.enumerated() {
            cell.frame = cellFrame(index)
            cell.closeButton.isHidden = cells.count < 2
        }
    }

    /// The page landing in its card takes taps where it shows, rather than where it's headed.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let card = moving, heading == .card, let shown = card.layer.presentation()?.frame, shown.contains(point) {
            return card
        }
        return super.hitTest(point, with: event)
    }

    /// Lays out a card for each tab.
    func load(_ tabs: [BrowserTab], current: Int) {
        cells.forEach { $0.removeFromSuperview() }
        cells = tabs.map { tab in
            let cell = TabCell()
            cell.card.image.image = tab.snapshot
            cell.card.pageSize = pageSize
            cell.card.stripHeight = stripHeight
            cell.title.text = tab.title
            cell.favicon.image = tab.favicon
            tab.onFaviconChange = { [weak tab, weak cell] in cell?.favicon.image = tab?.favicon }
            cell.onSelect = { [weak self, weak cell] in
                guard let self, let cell, let index = cells.firstIndex(of: cell) else { return }
                onSelect(index)
            }
            cell.onClose = { [weak self, weak cell] in
                guard let self, let cell, let index = cells.firstIndex(of: cell) else { return }
                onClose(index)
            }
            grid.addSubview(cell)
            return cell
        }
        self.current = current
        setNeedsLayout()
        layoutIfNeeded()
    }

    /// Shows the page whole over a sharp copy of itself, ready to shrink into its card.
    func prepare(backdrop image: UIImage?) {
        stop()
        isHidden = false
        backdrop.image = image
        effect.effect = nil
        scrollToCurrent()
        anchorGridOnScreen()
        grid.alpha = 0
        grid.transform = .identity
        for cell in cells {
            cell.caption.alpha = 0
            cell.caption.transform = CGAffineTransform(translationX: 0, y: 6)
        }
        cells[current].card.alpha = 0
        cells[current].closeButton.alpha = 0
        let card = makeMovingCard(image: image)
        card.crop = 0
        card.frame = bounds
        card.layer.cornerRadius = 0
        card.layoutIfNeeded()
        let blur = UIViewPropertyAnimator(duration: 0.3, curve: .easeOut) { [effect] in effect.effect = Self.blur }
        blur.pausesOnCompletion = true
        blur.pauseAnimation()
        blurAnimator = blur
        caught = nil
        swipeProgress = 0
    }

    /// Shrinks the page into its card, after `prepare`, or turns it back into its card from
    /// wherever it has grown to.
    func present() {
        setBlur(on: true)
        BlurCrossfade.swap(from: nil, to: grid)
        settle()
    }

    /// Catches the page as it grows back out of its card, for a swipe to shrink it again from there.
    func catchPage() {
        guard let card = moving else { return }
        move += 1
        heading = nil
        freeze(card)
        BlurCrossfade.stop(in: scroll)
        blurAnimator?.pauseAnimation()
        let progress = min(1, max(0, (1-card.frame.width/max(1, bounds.width))/0.5))
        caught = (progress, card.frame, card.crop, card.layer.cornerRadius)
        swipeProgress = progress
    }

    /// Shrinks the page with a swipe up, its bottom edge following the finger. A caught page starts
    /// where it was and comes under the finger as it moves.
    func update(swipe translation: CGPoint) {
        guard let card = moving else { return }
        let travel = bounds.height*Self.swipeTravel
        let rise = (caught?.progress ?? 0)*travel-translation.y
        let progress = min(1, max(0, rise/travel))
        swipeProgress = progress
        let scale = 1-0.5*progress
        let size = CGSize(width: bounds.width*scale, height: bounds.height*scale)
        let bottom = bounds.maxY-max(0, rise)
        var frame = CGRect(x: bounds.midX+translation.x*0.4-size.width/2, y: bottom-size.height, width: size.width, height: size.height)
        var crop: CGFloat = 0, radius = min(1, progress*4)*Self.cornerRadius*1.6
        if let caught {
            let held = max(0, 1-hypot(translation.x, translation.y)/Self.catchTravel)
            let from = caught.frame.offsetBy(dx: translation.x, dy: translation.y)
            frame = CGRect(x: frame.minX+(from.minX-frame.minX)*held, y: frame.minY+(from.minY-frame.minY)*held,
                           width: frame.width+(from.width-frame.width)*held, height: frame.height+(from.height-frame.height)*held)
            crop = caught.crop*held
            radius += (caught.radius-radius)*held
        }
        card.frame = frame
        card.crop = crop
        card.layer.cornerRadius = radius
        card.layoutIfNeeded()
        if let blur = blurAnimator {
            blur.pauseAnimation()
            blur.isReversed = false
            blur.fractionComplete = progress
        }
        grid.alpha = progress
        let grow = 0.96+0.04*progress
        grid.transform = CGAffineTransform(scaleX: grow, y: grow)
    }

    /// Drops the page into its card, or springs it back to the window.
    func finishSwipe(commit: Bool, completion: @escaping () -> Void = {}) {
        guard let card = moving else { return }
        caught = nil
        if commit {
            setBlur(on: true)
            UIView.animate(springDuration: Self.spring.duration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.grid.alpha = 1
                self.grid.transform = .identity
            }
            settle()
            completion()
            return
        }
        setBlur(on: false)
        UIView.animate(springDuration: Self.returnSpring.duration, bounce: Self.returnSpring.bounce, initialSpringVelocity: 0,
                       delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.grid.alpha = 0
            self.grid.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        }
        grow(card, completion: completion)
    }

    /// Grows a tab's card back into the page, as the rest blur and fade away; a page still landing
    /// turns around from where it is.
    func dismiss(to index: Int, completion: @escaping () -> Void) {
        guard cells.indices.contains(index) else { hide(); completion(); return }
        caught = nil
        // Another card was chosen while the page was landing: it lands at once.
        if moving != nil, index != current { land() }
        current = index
        let cell = cells[index]
        let card: TabCard
        if let moving {
            card = moving
        } else {
            card = makeMovingCard(image: cell.card.image.image)
            card.frame = cardFrame(index)
            card.layer.cornerRadius = Self.cornerRadius
            card.layoutIfNeeded()
        }
        cell.card.alpha = 0
        cell.closeButton.alpha = 0
        anchorGridOnScreen()
        BlurCrossfade.swap(from: grid, to: nil)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cells.forEach { $0.caption.alpha = 0 }
        }
        setBlur(on: false)
        grow(card, completion: completion)
    }

    /// Closes a tab's card, the others moving up to fill its place.
    func remove(at index: Int, current: Int) {
        guard cells.indices.contains(index) else { return }
        let cell = cells.remove(at: index)
        self.current = current
        setNeedsLayout()
        UIView.animate(springDuration: Self.spring.duration, bounce: 0.1, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            cell.alpha = 0
            cell.transform = CGAffineTransform(scaleX: 0.8, y: 0.8)
            self.layoutIfNeeded()
        } completion: { _ in cell.removeFromSuperview() }
    }

    /// Hides the switcher at once.
    func hide() {
        stop()
        isHidden = true
        effect.effect = nil
        grid.alpha = 0
        grid.transform = .identity
        for cell in cells {
            cell.card.alpha = 1
            cell.closeButton.alpha = 1
        }
    }

    private func makeMovingCard(image: UIImage?) -> TabCard {
        moving?.removeFromSuperview()
        let card = TabCard()
        card.image.image = image
        card.pageSize = pageSize
        card.stripHeight = stripHeight
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(movingTapped)))
        addSubview(card)
        moving = card
        return card
    }

    /// A tap on the page as it lands grows it back.
    @objc private func movingTapped() {
        if heading == .card { onSelect(current) }
    }

    /// Moves the page into its card, with the titles coming in after it.
    private func settle() {
        guard let card = moving, cells.indices.contains(current) else { return }
        move += 1
        let move = move, target = cardFrame(current)
        heading = .card
        UIView.animate(springDuration: Self.spring.duration, bounce: Self.spring.bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState]) {
            card.frame = target
            card.crop = 1
            card.layer.cornerRadius = Self.cornerRadius
            card.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.move == move else { return }
            land()
        }
        UIView.animate(withDuration: 0.25, delay: 0.1, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]) {
            for cell in self.cells {
                cell.caption.alpha = 1
                cell.caption.transform = .identity
            }
        }
    }

    /// Grows the page to fill the window, then hides the switcher.
    private func grow(_ card: TabCard, completion: @escaping () -> Void) {
        move += 1
        let move = move
        heading = .page
        UIView.animate(springDuration: Self.returnSpring.duration, bounce: Self.returnSpring.bounce, initialSpringVelocity: 0,
                       delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            card.frame = self.bounds
            card.crop = 0
            card.layer.cornerRadius = 0
            card.layoutIfNeeded()
        } completion: { [weak self] _ in
            guard let self, self.move == move else { return }
            hide()
            completion()
        }
    }

    /// Puts the moving page in its card at once.
    private func land() {
        guard let card = moving else { return }
        let cell = cells.indices.contains(current) ? cells[current] : nil
        cell?.card.alpha = 1
        card.removeFromSuperview()
        moving = nil
        heading = nil
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction]) { cell?.closeButton.alpha = 1 }
    }

    /// Leaves the page where it shows, its animations dropped.
    private func freeze(_ card: TabCard) {
        guard let shown = card.layer.presentation() else { return }
        let frame = shown.frame, radius = shown.cornerRadius
        let imageTop = card.image.layer.presentation()?.frame.minY ?? card.image.frame.minY
        card.layer.removeAllAnimations()
        card.image.layer.removeAllAnimations()
        card.frame = frame
        card.layer.cornerRadius = radius
        let strip = stripHeight*frame.width/max(1, pageSize.width)
        card.crop = strip > 0 ? min(1, max(0, -imageTop/strip)) : 0
        card.layoutIfNeeded()
    }

    /// Blurs the page in, or out, from however blurred it is.
    private func setBlur(on: Bool) {
        guard let blur = blurAnimator else { return }
        blur.pauseAnimation()
        blur.isReversed = !on
        blur.startAnimation()
    }

    /// Ends whatever was moving, so a new move starts clean.
    private func stop() {
        move += 1
        moving?.removeFromSuperview()
        moving = nil
        heading = nil
        caught = nil
        if let blur = blurAnimator, blur.state == .active { blur.stopAnimation(true) }
        blurAnimator = nil
    }

    /// Brings the current tab's card into the middle of what shows, as far as the grid allows.
    private func scrollToCurrent() {
        layoutIfNeeded()
        guard cells.indices.contains(current) else { return }
        let visible = bounds.height-topInset-bottomInset
        let lowest = max(-topInset, scroll.contentSize.height+bottomInset-bounds.height)
        let offset = cellFrame(current).midY-topInset-visible/2
        scroll.contentOffset = CGPoint(x: 0, y: min(lowest, max(-topInset, offset)))
    }

    /// The grid grows in around the middle of what shows, rather than of all of it.
    private func anchorGridOnScreen() {
        let height = max(1, grid.bounds.height)
        let middle = scroll.contentOffset.y+topInset+(bounds.height-topInset-bottomInset)/2
        grid.layer.anchorPoint = CGPoint(x: 0.5, y: min(1, max(0, middle/height)))
        grid.center = CGPoint(x: bounds.midX, y: grid.layer.anchorPoint.y*height)
    }
}
