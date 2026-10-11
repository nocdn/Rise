import UIKit
import WebKit

/// The iOS shell: one page at a time under a status bar strip and above a bottom bar.
/// Pages that a Peek replaced are held for Back.
final class BrowserViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate {
    static let homeURL = URL(string: "https://news.ycombinator.com/")!
    private(set) var webView: WKWebView
    /// Pages an expanded Peek replaced, most recent last, held for Back as on the Mac.
    private(set) var previousPages: [WKWebView] = []
    private lazy var backSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipeBack))
    private let startURL: URL?
    private let allowsPeek: Bool
    /// Fills the area behind the status bar with the colour along the page's top edge, as Arc
    /// does, so the page seems to reach the top of the screen. Peek pages have their own strip.
    let topStrip = UIView()
    /// Holds the strip and the pages, so they recede together behind the bar's panel.
    let content = UIView()
    /// Darkens the receded page; tapping it closes the panel.
    private let dimming = UIView()
    private lazy var tint = PageEdgeTint { [weak self] color in self?.setTopColor(color, animated: true) }
    private(set) lazy var pullToReload = PullToReload { [weak self] in self?.webView.reload() }
    /// Only the main page has one; Peek pages are closed and opened by their handle.
    let bottomBar = BottomBar()
    private var scrollObservation: NSKeyValueObservation?
    /// Keeps More's address and its Back and Forward up to date with the page.
    private var addressObservations: [NSKeyValueObservation] = []
    /// How far the page has scrolled in its current direction, to collapse or open the bar.
    private var scrollTravel: CGFloat = 0, lastScrollOffset: CGFloat = 0
    /// The panel New Page grows the bar into, as a share of the window's height.
    static let panelHeightFraction: CGFloat = 0.7
    private(set) var isPanelOpen = false
    /// Growing from the panel to fill the window with a page chosen in it: quicker than a Peek
    /// expanding, and likewise without overshoot, which would fall outside the screen.
    static let panelFillSpring = (duration: 0.16, bounce: 0.0)
    /// How far the bar has grown into its panel: 0 is the bar and 1 the open panel.
    private(set) var panelExpansion: CGFloat = 0
    private lazy var panelPan = UIPanGestureRecognizer(target: self, action: #selector(dragPanel))

    init(startURL: URL? = BrowserViewController.homeURL, allowsPeek: Bool = true) {
        self.startURL = startURL
        self.allowsPeek = allowsPeek
        webView = Self.makeWebView()
        super.init(nibName: nil, bundle: nil)
        adoptDelegates(of: webView)
    }

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Honor the focus-zoom cap in our viewport script while still allowing manual pinch zoom.
        configuration.ignoresViewportScaleLimits = true
        configuration.userContentController.addUserScript(InputZoomPolicy.userScript)
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func adoptDelegates(of webView: WKWebView) {
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        #if DEBUG
        webView.isInspectable = true
        #endif
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping @MainActor @Sendable (UIContextMenuConfiguration?) -> Void) {
        guard allowsPeek, let url = elementInfo.linkURL, Self.canPeek(url) else {
            // Keep WebKit's suggested actions for images, external schemes, and links inside Peek.
            completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { actions in
                UIMenu(children: actions)
            })
            return
        }
        // nil can fall back to WebKit's Data Detectors link preview. An explicit empty
        // configuration suppresses that preview without replacing WebKit's link hit testing.
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in nil })
        // Let WebKit finish resolving its menu before presenting our interactive sheet.
        DispatchQueue.main.async { [weak self] in self?.showPeek(url) }
    }

    static func canPeek(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    func showPeek(_ url: URL) {
        guard allowsPeek, Self.canPeek(url), viewIfLoaded?.window != nil,
              presentedViewController == nil, !isPanelOpen else { return }
        let peek = PeekViewController(url: url) { [weak self] page, color in self?.adopt(page, topColor: color) }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        present(peek, animated: true)
    }

    required init?(coder: NSCoder) { fatalError("Use init(startURL:)") }

    override func loadView() {
        view = UIView()
        // Only shows around the page as it recedes behind the panel.
        view.backgroundColor = .black
        content.backgroundColor = .systemBackground
        content.clipsToBounds = true
        view.addSubview(content)
        topStrip.backgroundColor = .systemBackground
        content.addSubview(pullToReload.overlay)
        install(webView)
        content.addSubview(topStrip)
        if allowsPeek { setUpBottomBar() }
        backSwipe.edges = .left
        backSwipe.delegate = self
        view.addGestureRecognizer(backSwipe)
    }

    /// Moves a page straight from wherever it is: removing it first would take it out of the
    /// window for a moment, and WebKit would drop its painted content and flash.
    private func install(_ page: WKWebView) {
        content.insertSubview(page, belowSubview: pullToReload.overlay)
        page.frame = pageFrame
    }

    /// The strip covers what the status bar does; Peek pages, inside their card, have none.
    private var stripHeight: CGFloat { allowsPeek ? view.safeAreaInsets.top : 0 }
    /// Pages sit below the strip rather than scrolling under it, so nothing runs beneath the clock.
    private var pageFrame: CGRect {
        CGRect(x: 0, y: stripHeight, width: view.bounds.width, height: view.bounds.height-stripHeight)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Frames ignore transforms, so lay out the content, which recedes, by bounds and center.
        content.bounds = view.bounds
        content.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        dimming.frame = view.bounds
        topStrip.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: stripHeight)
        for page in [webView]+previousPages where page.superview === content {
            // Frames ignore transforms, so lay out a page sliding during Back by bounds and center.
            page.bounds.size = pageFrame.size
            page.center = CGPoint(x: pageFrame.midX, y: pageFrame.midY)
        }
        pullToReload.layoutGap()
        layoutBottomBar()
    }

    private(set) var topColor: UIColor?

    private func setTopColor(_ color: UIColor, animated: Bool) {
        topColor = color
        let apply = {
            self.topStrip.backgroundColor = color
            self.pullToReload.spinner.onDarkBackground = PageEdgeColor.isDark(color)
            self.setNeedsStatusBarAppearanceUpdate()
        }
        if animated {
            UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction],
                           animations: apply)
        } else {
            // Settles any fade under way too, which would otherwise carry on to its own colour.
            topStrip.layer.removeAnimation(forKey: "backgroundColor")
            apply()
        }
    }

    /// Light text and icons over a dark strip, dark ones over a light strip.
    override var preferredStatusBarStyle: UIStatusBarStyle {
        // Over the dark backdrop around the receded page. Behind More's panel, the page recedes
        // too little to clear the clock.
        if isPanelOpen, bottomBar.panel == .search, !UIAccessibility.isReduceMotionEnabled { return .lightContent }
        guard let topColor else { return .default }
        return PageEdgeColor.isDark(topColor) ? .lightContent : .darkContent
    }

    /// Makes an expanded Peek's live page this page, without loading it again. `topColor`, the
    /// Peek strip's colour, carries over so the strip doesn't change as the page moves in, and
    /// `bottomColor` likewise for the bar.
    func adopt(_ page: WKWebView, topColor: UIColor? = nil) {
        guard page !== webView else { return }
        page.transform = .identity
        install(page)
        webView.removeFromSuperview()
        previousPages.append(webView)
        adoptDelegates(of: page)
        webView = page
        if let topColor { setTopColor(topColor, animated: false) }
        pageChanged(from: topColor)
    }

    /// The tracking that follows whichever page is current: the strip's and the bar's colours,
    /// the pull to reload, and the bar collapsing as the page scrolls.
    private func pageChanged(from topColor: UIColor? = nil) {
        guard allowsPeek else { return }
        tint.track(webView, from: topColor)
        pullToReload.attach(to: webView)
        lastScrollOffset = webView.scrollView.contentOffset.y
        scrollTravel = 0
        scrollObservation = webView.scrollView.observe(\.contentOffset) { [weak self] scrollView, _ in
            MainActor.assumeIsolated { self?.pageScrolled(scrollView) }
        }
        setBottomBarCollapsed(false, animated: false)
        updateTabsPreview()
        addressObservations = [
            webView.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateAddress() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateAddress() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.updateAddress() } },
        ]
        updateAddress()
    }

    /// Back in More's panel also returns past the start of the page's history to the page it replaced.
    private func updateAddress() {
        let url = shareableURL
        bottomBar.menu.address.show(url, canGoBack: webView.canGoBack || !previousPages.isEmpty,
                               canGoForward: webView.canGoForward)
        for tile in [bottomBar.menu.shareTile, bottomBar.menu.copyTile] { tile.isEnabled = url != nil }
    }

    /// Back past the start of an adopted page's history returns to the page it replaced.
    func returnToPreviousPage() {
        guard let previous = previousPages.popLast() else { return }
        previous.transform = .identity
        install(previous)
        webView.removeFromSuperview()
        webView = previous
        pageChanged()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // WebKit's own swipe handles Back within the page's history.
        if gestureRecognizer === panelPan { return isPanelOpen }
        return gestureRecognizer !== backSwipe || (!previousPages.isEmpty && !webView.canGoBack && !isPanelOpen)
    }

    /// Slides the page off to the right over the previous one, as WebKit's Back swipe does.
    @objc private func swipeBack(_ swipe: UIScreenEdgePanGestureRecognizer) {
        guard let previous = previousPages.last else { return }
        let width = max(1, view.bounds.width)
        let distance = max(0, swipe.translation(in: view).x)
        let place = { [weak self] (progress: CGFloat) in
            self?.webView.transform = CGAffineTransform(translationX: progress*width, y: 0)
            previous.transform = CGAffineTransform(translationX: -(1-progress)*width/3, y: 0)
        }
        switch swipe.state {
        case .began:
            previous.frame = pageFrame
            content.insertSubview(previous, belowSubview: webView)
            place(distance/width)
        case .changed:
            place(distance/width)
        case .ended, .cancelled, .failed:
            let velocity = swipe.velocity(in: view).x
            let back = swipe.state == .ended && (velocity > 500 || distance > width/3 && velocity > -200)
            let remaining = back ? width-distance : distance
            UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: abs(velocity)/max(1, remaining),
                           delay: 0, options: [.beginFromCurrentState]) {
                place(back ? 1 : 0)
            } completion: { [weak self] _ in
                guard let self else { return }
                if back { returnToPreviousPage() } else { previous.removeFromSuperview(); previous.transform = .identity }
            }
        default: break
        }
    }

    private func setUpBottomBar() {
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dimming.alpha = 0
        dimming.isUserInteractionEnabled = false
        dimming.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closePanelOnTap)))
        view.addSubview(dimming)
        view.addSubview(bottomBar)
        bottomBar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openCollapsedBar)))
        panelPan.delegate = self
        bottomBar.addGestureRecognizer(panelPan)
        bottomBar.newPageButton.addAction(UIAction { [weak self] _ in self?.openPanel() }, for: .primaryActionTriggered)
        bottomBar.search.onOpen = { [weak self] url in self?.openFromPanel(url) }
        bottomBar.moreButton.addAction(UIAction { [weak self] _ in self?.openPanel(.menu) }, for: .primaryActionTriggered)
        // Back and Forward leave More's panel open, to go on through the history; the rest close it.
        let address = bottomBar.menu.address, menu = bottomBar.menu
        let actions: [(UIControl, @MainActor (BrowserViewController) -> Void)] = [
            (address.backButton, { $0.goBack() }),
            (address.forwardButton, { $0.webView.goForward() }),
            (address.reloadButton, { $0.closePanel(); $0.webView.reload() }),
            (menu.shareTile, { $0.closePanel(); $0.share() }),
            // Nothing to pin to yet.
            (menu.pinTile, { _ in }),
            (menu.findTile, { $0.closePanel(); $0.findOnPage() }),
            (menu.copyTile, { $0.closePanel(); $0.copyLink() }),
        ]
        for (control, action) in actions {
            control.addAction(UIAction { [weak self] _ in if let self { action(self) } }, for: .primaryActionTriggered)
        }
    }

    private func layoutBottomBar() {
        guard bottomBar.superview === view else { return }
        let bounds = view.bounds, safeBottom = view.window?.safeAreaInsets.bottom ?? 0
        var height = BottomBar.height(collapsed: bottomBar.isCollapsed, safeBottom: safeBottom)
        if panelExpansion != 0 { height += panelTravel*panelExpansion }
        bottomBar.frame = CGRect(x: 0, y: bounds.maxY-height, width: bounds.width, height: height)
        // Pages scroll clear of the open bar. Its collapsed strip leaves the inset alone, so the
        // page never resizes as the bar collapses; it just shows more of itself.
        let needed = BottomBar.height(collapsed: false, safeBottom: safeBottom)-safeBottom
        if additionalSafeAreaInsets.bottom != needed { additionalSafeAreaInsets.bottom = needed }
    }

    /// The bar collapses after the page scrolls down a little, and opens after it scrolls back up
    /// a little, or reaches either end. Only scrolls the person makes count.
    private func pageScrolled(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y
        let delta = offset-lastScrollOffset
        lastScrollOffset = offset
        guard scrollView.isTracking || scrollView.isDecelerating, !pullToReload.isReloading else { return }
        let top = -scrollView.adjustedContentInset.top
        let bottom = scrollView.contentSize.height+scrollView.adjustedContentInset.bottom-scrollView.bounds.height
        if offset <= top+1 || (bottom > top && offset >= bottom-1) { scrollTravel = 0; setBottomBarCollapsed(false); return }
        scrollTravel = (delta > 0) == (scrollTravel > 0) ? scrollTravel+delta : delta
        if scrollTravel > 24 { setBottomBarCollapsed(true) } else if scrollTravel < -24 { setBottomBarCollapsed(false) }
    }

    @objc private func openCollapsedBar() { setBottomBarCollapsed(false) }

    func setBottomBarCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard collapsed != bottomBar.isCollapsed, !isPanelOpen else { return }
        let change = {
            self.bottomBar.isCollapsed = collapsed
            self.layoutBottomBar()
            self.bottomBar.layoutIfNeeded()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { change(); return }
        UIView.animate(springDuration: BottomBar.springDuration, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: change) { _ in
            if !collapsed { self.updateTabsPreview() }
        }
    }

    /// How much taller the open panel is than the bar.
    private var panelTravel: CGFloat { travel(of: bottomBar.panel) }

    private func travel(of panel: BottomBar.Panel) -> CGFloat {
        let safeBottom = view.window?.safeAreaInsets.bottom ?? 0
        let open = BottomBar.height(collapsed: false, safeBottom: safeBottom)
        let height = switch panel {
        case .search: (view.bounds.height*Self.panelHeightFraction).rounded()
        case .menu: BottomBar.menuHeight(width: view.bounds.width, safeBottom: safeBottom)
        }
        return max(1, height-open)
    }

    /// How far the page recedes behind the open panel: fully behind New Page's, and behind smaller
    /// panels as far as the same rate of growth takes it.
    private var panelRecede: CGFloat { panelTravel/travel(of: .search) }

    /// Grows the bar and rounds its top corners as its buttons fade, setting the page back behind it.
    private func setPanel(_ expansion: CGFloat, recedingPage: Bool = true) {
        panelExpansion = expansion
        bottomBar.panelExpansion = expansion
        dimming.alpha = min(1, max(0, expansion))
        layoutBottomBar()
        bottomBar.layoutIfNeeded()
        if recedingPage { PageRecede.apply(expansion*panelRecede, to: content) }
    }

    /// New Page grows the bar into a panel, as quickly and springily as a Peek opens, with an empty
    /// search field focused so the keyboard comes up alongside it. More grows it a little, into the
    /// page's address and a few actions. The bar's buttons swap for the panel's contents as it grows.
    func openPanel(_ panel: BottomBar.Panel = .search) {
        guard allowsPeek, !isPanelOpen, presentedViewController == nil else { return }
        isPanelOpen = true
        bottomBar.panel = panel
        if panel == .search { bottomBar.search.begin() } else { updateAddress() }
        dimming.isUserInteractionEnabled = true
        bottomBar.accessibilityViewIsModal = true
        bottomBar.showContents(of: panel)
        settlePanelOpen()
    }

    private func settlePanelOpen(velocity: CGFloat = 0) {
        let spring = PeekPresentationController.openSpring
        let animate = { self.setPanel(1); self.setNeedsStatusBarAppearanceUpdate() }
        guard !UIAccessibility.isReduceMotionEnabled else { animate(); return }
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: velocity, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: animate)
    }

    /// Shrinks the panel back into the bar, carrying on at `velocity`, in points per second downwards.
    func closePanel(velocity: CGFloat = 0) {
        guard isPanelOpen else { return }
        isPanelOpen = false
        bottomBar.search.end()
        dimming.isUserInteractionEnabled = false
        bottomBar.accessibilityViewIsModal = false
        guard !UIAccessibility.isReduceMotionEnabled else {
            setPanel(0); bottomBar.showContents(of: nil, animated: false); setNeedsStatusBarAppearanceUpdate(); return
        }
        // As with Peek, the bar returns without overshoot while the page's bounce shows its return.
        let close = PeekPresentationController.closeSpring
        let remaining = max(1, panelTravel*panelExpansion)
        UIView.animate(springDuration: close.duration, bounce: close.bounce,
                       initialSpringVelocity: max(0, velocity)/remaining, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.setPanel(0, recedingPage: false)
            self.setNeedsStatusBarAppearanceUpdate()
        }
        let back = PeekPresentationController.pageReturnSpring
        UIView.animate(springDuration: back.duration, bounce: back.bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            PageRecede.apply(0, to: self.content)
        }
        bottomBar.showContents(of: nil)
    }

    @objc private func closePanelOnTap() { closePanel() }

    /// Opens a page chosen in the panel. The panel grows up to fill the window as its search fades
    /// out and the new page appears inside it; the page then stays, the previous one held for Back.
    func openFromPanel(_ url: URL) {
        guard isPanelOpen else { return }
        isPanelOpen = false
        bottomBar.search.end()
        dimming.isUserInteractionEnabled = false
        bottomBar.accessibilityViewIsModal = false
        view.isUserInteractionEnabled = false

        let page = Self.makeWebView()
        adoptDelegates(of: page)
        page.load(URLRequest(url: url))
        // Until the page paints, the strip above it and the bar take its background's colour.
        let color = page.underPageBackgroundColor.resolvedColor(with: traitCollection)
        // Holds the page, at the size it will have, inside the growing panel, which clips it.
        let arrival = UIView()
        arrival.backgroundColor = color
        arrival.alpha = 0
        arrival.frame = bottomBar.bounds
        page.frame = CGRect(origin: .zero, size: pageFrame.size)
        arrival.addSubview(page)
        bottomBar.addSubview(arrival)

        let safeBottom = view.window?.safeAreaInsets.bottom ?? 0
        let fills = (view.bounds.height-BottomBar.height(collapsed: false, safeBottom: safeBottom))/panelTravel
        let grow = {
            self.panelExpansion = fills
            self.layoutBottomBar()
            // Square corners at the end, as the page has.
            self.bottomBar.layer.cornerRadius = 0
            arrival.frame = self.bottomBar.bounds
            page.frame = self.pageFrame
            // The page behind carries on receding at the rate it did as the panel opened.
            PageRecede.apply(fills, to: self.content)
        }
        // The panel now looks just as the page will, so swapping them is invisible.
        let land = { [weak self] in
            guard let self else { return }
            PageRecede.apply(0, to: content)
            setPanel(0, recedingPage: false)
            adopt(page, topColor: color)
            arrival.removeFromSuperview()
            view.isUserInteractionEnabled = true
            bottomBar.showContents(of: nil)
        }
        guard !UIAccessibility.isReduceMotionEnabled else { grow(); land(); return }
        bottomBar.hideContents()
        UIView.animate(withDuration: 0.1, delay: 0.03, options: []) { arrival.alpha = 1 }
        let spring = Self.panelFillSpring
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState], animations: grow) { _ in land() }
    }

    /// Dragging the panel down shrinks it with the finger; up stretches it a little, with resistance.
    @objc private func dragPanel(_ pan: UIPanGestureRecognizer) {
        guard isPanelOpen else { return }
        let travel = panelTravel, distance = pan.translation(in: view).y
        switch pan.state {
        case .began, .changed:
            let stretch = 40*(1-1/(1+max(0, -distance)/160))
            setPanel(distance >= 0 ? max(0, 1-distance/travel) : 1+stretch/travel)
        case .ended, .cancelled, .failed:
            let velocity = pan.state == .ended ? pan.velocity(in: view).y : 0
            if velocity > 600 || (distance > travel*0.3 && velocity > -200) {
                closePanel(velocity: velocity)
            } else {
                settlePanelOpen(velocity: distance > 0 ? -velocity/distance : 0)
            }
        default: break
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isPanelOpen else { return super.accessibilityPerformEscape() }
        closePanel()
        return true
    }

    /// The current page, small, as the top card of the Tabs button.
    private func updateTabsPreview() {
        guard allowsPeek, webView.window != nil, webView.bounds.width > 0 else { return }
        // The top of the page, in the card's proportions.
        let card = TabsPreviewButton.cardSize, width = webView.bounds.width
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: width, height: min(webView.bounds.height, width*card.height/card.width))
        configuration.snapshotWidth = NSNumber(value: Double(card.width*3))
        // Waits for WebKit's next paint, so a page that has just loaded isn't caught blank.
        configuration.afterScreenUpdates = true
        let page = webView
        page.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, page === webView else { return }
            bottomBar.tabsButton.preview = image
        }
    }

    private var shareableURL: URL? { webView.url.flatMap { Self.canPeek($0) ? $0 : nil } }

    private func goBack() {
        if webView.canGoBack { webView.goBack() } else { returnToPreviousPage() }
    }

    private func copyLink() {
        guard let url = shareableURL else { return }
        UIPasteboard.general.url = url
    }

    private func share() {
        guard let url = shareableURL else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = bottomBar.moreButton
        present(share, animated: true)
    }

    private func findOnPage() {
        webView.isFindInteractionEnabled = true
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if allowsPeek {
            tint.fillsOverscroll = true
            pullToReload.onGapHeld = { [weak self] held in self?.tint.gapHeld = held }
            pageChanged()
        }
        if let startURL { webView.load(URLRequest(url: startURL)) }
    }

    // With no tab UI yet, links requesting a new window navigate this page instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        updateTabsPreview()
        // Images and late layout land after the load finishes.
        DispatchQueue.main.asyncAfter(deadline: .now()+1) { [weak self] in
            if self?.webView === webView { self?.updateTabsPreview() }
        }
        #if DEBUG
        if webView.url == Self.homeURL { print("Rise iOS: Hacker News loaded") }
        #endif
    }
}
