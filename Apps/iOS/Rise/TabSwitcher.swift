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
    /// A replica of the page, as `snapshotView` makes, quick to take, shown in place of `image` at
    /// the window's size, scaled down.
    var replica: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let replica { addSubview(replica) }
            setNeedsLayout()
        }
    }

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
        let page = Self.pageLayout(width: bounds.width, crop: crop, pageSize: pageSize, stripHeight: stripHeight)
        image.frame = page.frame
        if let replica {
            replica.bounds = CGRect(origin: .zero, size: pageSize)
            replica.transform = CGAffineTransform(scaleX: page.scale, y: page.scale)
            replica.center = CGPoint(x: page.frame.midX, y: page.frame.midY)
        }
    }

    /// Where the page shows in a card this wide: from the top, its strip cropped off as far as `crop`.
    static func pageLayout(width: CGFloat, crop: CGFloat, pageSize: CGSize, stripHeight: CGFloat) -> (frame: CGRect, scale: CGFloat) {
        let scale = width/max(1, pageSize.width)
        return (CGRect(x: 0, y: -stripHeight*scale*crop, width: width, height: pageSize.height*scale), scale)
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

/// The tabs as cards in two columns over a solid grey, as in Safari. The current page shrinks
/// into its card as the other cards fade, grow and sharpen in around it, their
/// titles last; choosing a card grows it back into the page. A swipe up the bottom bar shrinks the
/// page with the finger, the spot under it staying under it, and when let go it flies on at the
/// speed it was going and curves round into its card, on Summarise's springs. Every move can be
/// turned around partway, carrying on from its speed: Tabs again, a tap on the landing page, or a
/// swipe up as it grows back.
final class TabSwitcherView: UIView {
    static let inset: CGFloat = 16
    static let spacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    /// The cards' height for their width.
    static let cardAspect: CGFloat = 1.42
    static let titleHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 18
    static let closeSize: CGFloat = 24
    /// The grid's own fade and growth.
    static let spring = (duration: 0.3, bounce: 0.14)
    static let returnSpring = (duration: 0.28, bounce: 0.0)
    /// The page's corners as it starts to shrink, which ease down to the card's, if the screen's
    /// can't be read.
    static let swipeRadius = 28.8
    /// How far into its shrinking, as a share of the way to its card, the titles start to come in.
    static let captionFrom = 0.35
    /// Behind the cards: a solid, faintly warm grey, the same from the start, rather than a blur
    /// of the page that would be slow to come in.
    static let background = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 26/255, green: 25/255, blue: 24/255, alpha: 1)
        : UIColor(red: 243/255, green: 241/255, blue: 240/255, alpha: 1) }
    /// How far up the swipe goes, as a share of the height, for the page to shrink all it will.
    static let swipeTravel: CGFloat = 0.45
    /// How far the finger moves for a page caught partway to come under it.
    static let catchTravel: CGFloat = 120

    private enum Heading { case card, page }

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
    /// How far a swipe up has shrunk the page, from 0 to 1.
    private(set) var swipeProgress: CGFloat = 0
    /// A page the swipe caught as it moved: how far it had shrunk, and how it was, which it leaves
    /// for under the finger as the finger moves.
    private var caught: (progress: CGFloat, shape: Shape)?

    /// The moving page: its middle, its width as a share of the window's, how much of the page
    /// shows below its top, in the page's own points, how much of the strip is cropped, and its corners.
    struct Shape {
        var x, y, scale, height, crop, radius: Double
        static func lerp(_ a: Shape, _ b: Shape, _ k: Double) -> Shape {
            func mix(_ a: Double, _ b: Double) -> Double { a+(b-a)*k }
            return Shape(x: mix(a.x, b.x), y: mix(a.y, b.y), scale: mix(a.scale, b.scale), height: mix(a.height, b.height),
                         crop: mix(a.crop, b.crop), radius: mix(a.radius, b.radius))
        }

        static func velocity(from a: Shape, to b: Shape, over dt: Double) -> Shape {
            Shape(x: (b.x-a.x)/dt, y: (b.y-a.y)/dt, scale: (b.scale-a.scale)/dt,
                  height: (b.height-a.height)/dt, crop: (b.crop-a.crop)/dt, radius: (b.radius-a.radius)/dt)
        }
    }
    /// A move of the page on Summarise's springs. Let go, its size and place carry on at the speed
    /// they were going (`release`), so it doesn't follow a set path; its crop and corners carry
    /// their speed onto `shape` too, keeping both edges moving through release. Otherwise every
    /// part runs on one spring's progress.
    struct Flight {
        var from: Shape, to: Shape, t0: Double
        var velocity: Shape?
        var scale: SummariseSpring, place: SummariseSpring, shape: SummariseSpring

        func at(_ t: Double) -> Shape {
            func released(_ key: KeyPath<Shape, Double>, _ spring: SummariseSpring, _ speed: Double?) -> Double {
                guard let speed else { return from[keyPath: key]+(to[keyPath: key]-from[keyPath: key])*spring(t) }
                return spring.value(from: from[keyPath: key], to: to[keyPath: key], velocity: speed, at: t)
            }
            return Shape(x: released(\.x, place, velocity?.x), y: released(\.y, place, velocity?.y),
                         scale: released(\.scale, scale, velocity?.scale),
                         height: released(\.height, shape, velocity?.height),
                         crop: released(\.crop, shape, velocity?.crop),
                         radius: released(\.radius, shape, velocity?.radius))
        }
    }
    private var flight: Flight?
    /// Counts flights, so one that's been interrupted doesn't finish.
    private var flights = 0
    /// Holds the screen at 120 Hz from the first drag through landing, including a caught flight:
    /// touch-driven changes otherwise run at 60, as does the slow end of a Core Animation flight.
    private var rateHold: CADisplayLink?
    /// Called as each flight starts, on Core Animation, when the main thread can be busy for a
    /// moment without it showing.
    var onFlight: () -> Void = {}
    /// Where the page has been under the finger, for the speed it was going when let go.
    private var history: [(t: Double, shape: Shape)] = []
    /// Where the finger started, across: the spot on the page there stays under it.
    private var anchorX: Double = 0
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
        backgroundColor = Self.background
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

    /// Shows the page whole over the switcher's grey, ready to shrink into its card: a replica of
    /// it, quick to take, as the picture for its card is drawn once it's on its way.
    func prepare(page replica: UIView?) {
        stop()
        holdRate(true)
        isHidden = false
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
        let card = makeMovingCard(image: nil)
        card.replica = replica
        card.crop = 0
        card.frame = bounds
        card.layer.cornerRadius = pageRadius
        card.layoutIfNeeded()
        caught = nil
        swipeProgress = 0
        history = []
    }

    /// The picture for a tab's card, drawn once the page is on its way.
    func setPicture(_ image: UIImage, at index: Int) {
        guard cells.indices.contains(index) else { return }
        cells[index].card.image.image = image
    }

    /// Shrinks the page into its card, after `prepare`, or turns it back into its card from
    /// wherever it has grown to.
    func present() {
        BlurCrossfade.swap(from: nil, to: grid)
        settle()
    }

    /// Catches the page as it grows back out of its card, for a swipe to shrink it again from there.
    func catchPage() {
        guard let card = moving else { return }
        move += 1
        heading = nil
        freeze(card)
        holdRate(true)
        BlurCrossfade.stop(in: scroll)
        let shape = shape(of: card)
        let progress = min(1, max(0, (1-shape.scale)/0.5))
        caught = (progress, shape)
        swipeProgress = progress
        history = []
    }

    /// Shrinks the page with a swipe up, its bottom edge following the finger and the spot across
    /// from where the finger started staying under it, the corners rounding and the page cropping
    /// towards its card as it goes. A caught page starts where it was and comes under the finger as
    /// it moves.
    func update(swipe translation: CGPoint, from start: CGPoint? = nil) {
        guard let card = moving else { return }
        if history.isEmpty { anchorX = Double(start?.x ?? bounds.midX) }
        let travel = bounds.height*Self.swipeTravel
        let rise = (caught?.progress ?? 0)*travel-translation.y
        let progress = max(0, rise/travel)
        swipeProgress = min(1, progress)
        // Half the size at the end of the travel, and a little past it, giving.
        let s = progress <= 1 ? 1-0.5*progress : 0.5*exp(-(progress-1))
        let target = cardShape(current), width = Double(bounds.width), height = Double(bounds.height)
        let k = pow(min(1, max(0, (1-s)/(1-target.scale))), SummariseMotion.pinchEasing)
        var shape = Shape(x: anchorX+Double(translation.x)-(anchorX-width/2)*s, y: 0, scale: s,
                          height: height+(target.height-height)*k, crop: k,
                          radius: pageRadius+(Double(Self.cornerRadius)-pageRadius)*k)
        shape.y = height-max(0, Double(rise))-shape.height*s/2
        if let caught {
            let held = max(0, 1-hypot(translation.x, translation.y)/Self.catchTravel)
            var from = caught.shape
            from.x += Double(translation.x); from.y += Double(translation.y)
            shape = Shape.lerp(shape, from, Double(held))
        }
        apply(shape, to: card)
        let now = CACurrentMediaTime()
        history.append((now, shape))
        history.removeAll { now-$0.t > SummariseMotion.velocityWindow }
        grid.alpha = progress
        let grow = 0.96+0.04*progress
        grid.transform = CGAffineTransform(scaleX: grow, y: grow)
    }

    /// Drops the page into its card, or springs it back to the window.
    func finishSwipe(commit: Bool, completion: @escaping () -> Void = {}) {
        guard let card = moving else { return }
        caught = nil
        let velocity = swipeVelocity()
        history = []
        if commit {
            UIView.animate(springDuration: Self.spring.duration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.grid.alpha = 1
                self.grid.transform = .identity
            }
            settle(velocity: velocity)
            completion()
            return
        }
        UIView.animate(springDuration: Self.returnSpring.duration, bounce: Self.returnSpring.bounce, initialSpringVelocity: 0,
                       delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.grid.alpha = 0
            self.grid.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        }
        // Short, it springs back to the page from wherever it was going, as a short pinch does.
        fadeCaptions()
        grow(card, velocity: velocity, completion: completion)
    }

    /// Going back to the page, the titles go quickly.
    private func fadeCaptions() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.cells.forEach { $0.caption.alpha = 0 }
        }
    }

    /// How fast the page was going under the finger as it was let go.
    private func swipeVelocity() -> Shape {
        guard let first = history.first, let last = history.last, last.t-first.t > 0.008 else {
            return Shape(x: 0, y: 0, scale: 0, height: 0, crop: 0, radius: 0)
        }
        let dt = last.t-first.t, move = SummariseMotion.maxMoveSpeed, scale = SummariseMotion.maxScaleSpeed
        var velocity = Shape.velocity(from: first.shape, to: last.shape, over: dt)
        velocity.x = min(move, max(-move, velocity.x))
        velocity.y = min(move, max(-move, velocity.y))
        velocity.scale = min(scale, max(-scale, velocity.scale))
        return velocity
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
            apply(cardShape(index), to: card)
        }
        cell.card.alpha = 0
        cell.closeButton.alpha = 0
        anchorGridOnScreen()
        BlurCrossfade.swap(from: grid, to: nil)
        fadeCaptions()
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

    /// Moves the page into its card, with the titles coming in after it: let go, at the speed it
    /// was going, and otherwise turning round from however it was already moving.
    private func settle(velocity: Shape? = nil) {
        guard let card = moving, cells.indices.contains(current) else { return }
        move += 1
        let move = move
        heading = .card
        let M = SummariseMotion.self
        fly(card, to: cardShape(current), velocity: velocity ?? flightVelocity(),
            scale: M.releaseScale, place: M.releaseMove, shape: M.placeCrop) { [weak self] in
            guard let self, self.move == move else { return }
            land()
        }
    }

    /// Grows the page to fill the window, then hides the switcher: as Summarise's card grows back,
    /// or, let go short, springing back from the speed it was going.
    private func grow(_ card: TabCard, velocity: Shape? = nil, completion: @escaping () -> Void) {
        move += 1
        let move = move
        heading = .page
        let M = SummariseMotion.self
        let done = { [weak self] in
            guard let self, self.move == move else { return }
            hide()
            completion()
        }
        // Already moving, it turns round from that speed.
        if let speed = velocity ?? (flight != nil ? flightVelocity() : nil) {
            fly(card, to: pageShape, velocity: speed, scale: M.cancel, place: M.cancel, shape: M.cancel, done: done)
        } else {
            fly(card, to: pageShape, velocity: nil, scale: M.close, place: M.close, shape: M.close, done: done)
        }
    }

    // MARK: The page's flight

    private var pageShape: Shape {
        Shape(x: Double(bounds.midX), y: Double(bounds.midY), scale: 1, height: Double(bounds.height), crop: 0, radius: pageRadius)
    }

    /// The page's corners at full size: the screen's, so they're round from the moment it starts
    /// to shrink, rather than square at first, and ease from there to the card's.
    private var pageRadius: Double {
        let screen = Double(PageRecede.screenCornerRadius(of: self))
        return screen > 0 ? screen : Self.swipeRadius
    }

    /// A tab's card, settled.
    private func cardShape(_ index: Int) -> Shape {
        let frame = cardFrame(index), scale = Double(frame.width/max(1, bounds.width))
        return Shape(x: Double(frame.midX), y: Double(frame.midY), scale: scale, height: Double(frame.height)/scale,
                     crop: 1, radius: Double(Self.cornerRadius))
    }

    private func shape(of card: TabCard, asShown: Bool = false) -> Shape {
        let shown = asShown ? card.layer.presentation() : nil
        let frame = shown?.frame ?? card.frame, scale = max(0.01, Double(frame.width/max(1, bounds.width)))
        // The last touch can update the model without that pose reaching the screen before
        // release. Start from what was actually shown, including the strip's visible crop.
        var crop = Double(card.crop)
        if shown != nil, stripHeight > 0, let page = card.image.layer.presentation() {
            crop = min(1, max(0, -Double(page.frame.minY)/(Double(stripHeight)*scale)))
        }
        return Shape(x: Double(frame.midX), y: Double(frame.midY), scale: scale, height: Double(frame.height)/scale,
                     crop: crop, radius: Double(shown?.cornerRadius ?? card.layer.cornerRadius))
    }

    private func apply(_ shape: Shape, to card: TabCard) {
        card.bounds = CGRect(x: 0, y: 0, width: bounds.width*shape.scale, height: max(0, shape.height*shape.scale))
        card.center = CGPoint(x: shape.x, y: shape.y)
        card.crop = min(1, max(0, shape.crop))
        card.layer.cornerRadius = max(0, shape.radius)
        card.layoutIfNeeded()
        if card === moving, heading != .page { placeCaptions(for: shape) }
    }

    /// The titles come in as the page shrinks into its card: its own rides under it, and they all
    /// fade in over the last part of the way, rising a little into place.
    private func placeCaptions(for shape: Shape) {
        guard let captions = captions(for: shape) else { return }
        for (index, cell) in cells.enumerated() {
            cell.caption.alpha = captions.alpha
            cell.caption.transform = index == current ? captions.current : captions.others
        }
    }

    private func captions(for shape: Shape) -> (alpha: Double, current: CGAffineTransform, others: CGAffineTransform)? {
        guard cells.indices.contains(current) else { return nil }
        let target = cardShape(current)
        let k = min(1, max(0, ((1-shape.scale)/max(0.01, 1-target.scale)-Self.captionFrom)/(1-Self.captionFrom)))
        let shown = k*k*(3-2*k)
        // Its own under the page, wherever it is, rather than under its card.
        let height = shape.height*shape.scale
        return (shown, CGAffineTransform(translationX: shape.x-target.x, y: (shape.y+height/2)-(target.y+target.height*target.scale/2)+6*(1-shown)),
                CGAffineTransform(translationX: 0, y: 6*(1-shown)))
    }

    /// Flies the page along its springs on Core Animation: the whole path is worked out at once,
    /// as nothing but a new touch changes it, and played as keyframes 120 times a second, so it
    /// carries on smoothly while the main thread is busy, as it is for the keyboard coming up.
    private func fly(_ card: TabCard, to target: Shape, velocity: Shape?,
                     scale: SummariseSpring, place: SummariseSpring, shape: SummariseSpring, done: @escaping () -> Void) {
        let now = CACurrentMediaTime(), from = flight.map { $0.at(now-$0.t0) } ?? self.shape(of: card, asShown: true)
        stopFlight()
        flights += 1
        let id = flights
        let flight = Flight(from: from, to: target, t0: now, velocity: velocity, scale: scale, place: place, shape: shape)
        self.flight = flight
        // Until it rests within half a point of its place, barely moving.
        let step = 1.0/120, width = Double(bounds.width)
        func near(_ a: Shape, _ b: Shape, _ points: Double) -> Bool {
            abs(a.x-b.x) < points && abs(a.y-b.y) < points && abs(a.scale-b.scale)*width < points
                && abs(a.height*a.scale-b.height*b.scale) < points && abs(a.crop-b.crop) < 0.01 && abs(a.radius-b.radius) < points
        }
        var path = [from]
        while path.count < 360 {
            let next = flight.at(Double(path.count)*step)
            let resting = near(next, target, 0.5) && near(next, path[path.count-1], 0.1)
            path.append(resting ? target : next)
            if resting { break }
        }
        if path.last.map({ !near($0, target, 0.01) }) ?? true { path.append(target) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, flights == id, self.flight != nil else { return }
            self.flight = nil
            holdRate(false)
            done()
        }
        apply(target, to: card)
        self.flight?.t0 = animate(card, along: path, duration: Double(path.count-1)*step)
        CATransaction.commit()
        holdRate(true)
        onFlight()
    }

    private func animate(_ card: TabCard, along path: [Shape], duration: Double) -> CFTimeInterval {
        var animations: [(layer: CALayer, key: String, animation: CAKeyframeAnimation)] = []
        func keyframes(_ layer: CALayer, _ keyPath: String, _ values: [Any]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.duration = duration
            animation.calculationMode = .linear
            animation.fillMode = .backwards
            // Left to choose, iOS plays explicit animations at 60 Hz.
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            animations.append((layer, Self.flightKey+keyPath, animation))
        }
        let width = bounds.width
        let frames = path.map { shape in
            CGRect(x: shape.x-width*shape.scale/2, y: shape.y-max(0, shape.height*shape.scale)/2,
                   width: width*shape.scale, height: max(0, shape.height*shape.scale))
        }
        keyframes(card.layer, "bounds", frames.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.size)) })
        keyframes(card.layer, "position", frames.map { NSValue(cgPoint: CGPoint(x: $0.midX, y: $0.midY)) })
        keyframes(card.layer, "cornerRadius", path.map { max(0, $0.radius) })
        let pages = zip(path, frames).map { shape, frame in
            TabCard.pageLayout(width: frame.width, crop: min(1, max(0, shape.crop)), pageSize: card.pageSize, stripHeight: card.stripHeight)
        }
        keyframes(card.image.layer, "bounds", pages.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.frame.size)) })
        keyframes(card.image.layer, "position", pages.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        if let replica = card.replica {
            keyframes(replica.layer, "transform", pages.map { NSValue(caTransform3D: CATransform3DMakeScale($0.scale, $0.scale, 1)) })
            keyframes(replica.layer, "position", pages.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        }
        // The titles ride along on the way in.
        if heading != .page {
            let titles = path.compactMap { captions(for: $0) }
            if titles.count == path.count {
                for (index, cell) in cells.enumerated() {
                    keyframes(cell.caption.layer, "opacity", titles.map { Float($0.alpha) })
                    keyframes(cell.caption.layer, "transform",
                              titles.map { NSValue(caTransform3D: CATransform3DMakeAffineTransform(index == current ? $0.current : $0.others)) })
                }
            }
        }
        // Start the clock after preparing the keyframes. On a strong flick, even a few ms spent
        // building them used to skip a noticeable part of the path before its first frame.
        let start = CACurrentMediaTime()
        for (layer, key, animation) in animations {
            animation.beginTime = layer.convertTime(start, from: nil)
            layer.add(animation, forKey: key)
        }
        return start
    }

    private static let flightKey = "flight."

    /// How fast the page is going in its flight now, for a new one to carry on from.
    private func flightVelocity() -> Shape? {
        guard let flight else { return nil }
        let t = CACurrentMediaTime()-flight.t0, dt = 1.0/240
        let a = flight.at(t-dt), b = flight.at(t)
        return Shape.velocity(from: a, to: b, over: dt)
    }

    /// Asks for the high refresh rate throughout a drag and its flight, until it lands or hides.
    private func holdRate(_ holding: Bool) {
        guard holding != (rateHold != nil) else { return }
        rateHold?.invalidate()
        rateHold = nil
        guard holding else { return }
        let link = CADisplayLink(target: FrameTicker {}, selector: #selector(FrameTicker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        rateHold = link
    }

    private func stopFlight() {
        guard let flight else { return }
        let shown = flight.at(CACurrentMediaTime()-flight.t0)
        self.flight = nil
        guard let card = moving else { return }
        var layers = [card.layer, card.image.layer]+cells.map(\.caption.layer)
        if let replica = card.replica { layers.append(replica.layer) }
        for layer in layers {
            for key in layer.animationKeys() ?? [] where key.hasPrefix(Self.flightKey) { layer.removeAnimation(forKey: key) }
        }
        apply(shown, to: card)
    }

    /// Puts the moving page in its card at once.
    private func land() {
        guard let card = moving else { return }
        stopFlight()
        holdRate(false)
        let cell = cells.indices.contains(current) ? cells[current] : nil
        if heading != .page {
            for cell in cells {
                cell.caption.alpha = 1
                cell.caption.transform = .identity
            }
        }
        cell?.card.alpha = 1
        card.removeFromSuperview()
        moving = nil
        heading = nil
        UIView.animate(withDuration: 0.15, delay: 0, options: [.allowUserInteraction]) { cell?.closeButton.alpha = 1 }
    }

    /// Leaves the page where it shows, its flight dropped.
    private func freeze(_ card: TabCard) {
        stopFlight()
    }

    /// Ends whatever was moving, so a new move starts clean.
    private func stop() {
        move += 1
        stopFlight()
        holdRate(false)
        history = []
        moving?.removeFromSuperview()
        moving = nil
        heading = nil
        caught = nil
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
