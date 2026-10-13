import UIKit
import WebKit

/// The iOS shell: a tab's page under a status bar strip and above a bottom bar, with the other
/// tabs in a switcher. Pages that a Peek replaced in a tab are held for Back.
final class BrowserViewController: UIViewController, WKUIDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate {
    static let homeURL = URL(string: "https://news.ycombinator.com/")!
    /// The open tabs, in the switcher's order.
    private(set) var tabs: [BrowserTab]
    private(set) var tabIndex = 0
    private var currentTab: BrowserTab { tabs[tabIndex] }
    /// The current tab's page.
    private(set) var webView: WKWebView {
        get { currentTab.webView }
        set { currentTab.webView = newValue }
    }
    /// Pages an expanded Peek replaced in this tab, most recent last, held for Back as on the Mac.
    private(set) var previousPages: [WKWebView] {
        get { currentTab.previousPages }
        set { currentTab.previousPages = newValue }
    }
    /// The tabs as cards, over the page and under the bottom bar, which stays.
    let tabSwitcher = TabSwitcherView()
    private(set) var isTabSwitcherOpen = false
    /// A swipe up anywhere on the bottom bar shrinks the page into the tab switcher.
    private lazy var tabSwipe = UIPanGestureRecognizer(target: self, action: #selector(swipeToTabs))
    /// Holding New Page listens for a search; letting go opens New Page with it transcribed.
    private lazy var newPageHold = UILongPressGestureRecognizer(target: self, action: #selector(holdNewPage))
    let voice = VoiceInput()
    private var isSwipingToTabs = false
    private lazy var backSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipeBack))
    private let startURL: URL?
    private let allowsPeek: Bool
    private var opensSearchOnFirstAppearance: Bool
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
    /// How much of the window the keyboard covers, which Find's panel sits above.
    private var keyboardHeight: CGFloat = 0
    private lazy var panelPan = UIPanGestureRecognizer(target: self, action: #selector(dragPanel(_:)))
    /// Pinching in on the page, from its smallest zoom, folds it up and summarises it.
    private lazy var summarisePinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchToSummarise(_:)))
    private var pinchFromSmallest = false
    /// Where the pinch's fingers started, and where they were last together.
    private var pinchStart = CGPoint.zero, pinchCentroid = CGPoint.zero
    /// The fingers' scale when Summarise caught the card, which they go on from.
    private var pinchGrabScale: CGFloat = 1
    /// The page folded into a card over its summary, between the page and the bottom bar.
    private(set) var summarise: SummariseView?
    private lazy var collapsedBarTap = UITapGestureRecognizer(target: self, action: #selector(openCollapsedBar))

    init(startURL: URL? = BrowserViewController.homeURL, allowsPeek: Bool = true,
         opensSearchOnFirstAppearance: Bool = false) {
        self.startURL = startURL
        self.allowsPeek = allowsPeek
        self.opensSearchOnFirstAppearance = opensSearchOnFirstAppearance
        tabs = [BrowserTab(webView: Self.makeWebView())]
        super.init(nibName: nil, bundle: nil)
        adoptDelegates(of: webView)
    }

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Honor the focus-zoom cap in our viewport script while still allowing manual pinch zoom.
        configuration.ignoresViewportScaleLimits = true
        configuration.userContentController.addUserScript(InputZoomPolicy.userScript)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // In dark mode, see-through until it paints, rather than flashing WebKit's white.
        PagePaintWatcher.shared.install(on: webView)
        return webView
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
              presentedViewController == nil, !isPanelOpen, !isTabSwitcherOpen else { return }
        let peek = PeekViewController(url: url) { [weak self] page, color in self?.adopt(page, topColor: color) }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        present(peek, animated: true)
    }

    required init?(coder: NSCoder) { fatalError("Use init(startURL:)") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Only a freshly created scene opts in. Consume it once, so returning to the app or
        // dismissing a presented controller preserves whatever the person was doing.
        guard opensSearchOnFirstAppearance else { return }
        opensSearchOnFirstAppearance = false
        openPanel()
    }

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
        if allowsPeek {
            // In the content, so it recedes with the page behind the bar's panels.
            content.addSubview(tabSwitcher)
            setUpBottomBar()
            summarisePinch.delegate = self
            summarisePinch.cancelsTouchesInView = false
            content.addGestureRecognizer(summarisePinch)
        }
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
        bottomBar.find.maximumAnswerHeight = max(80, min(300, view.bounds.height-keyboardHeight-160))
        layoutBottomBar()
        // Summarise is laid out for the window it started in.
        if let summarise, summarise.bounds.size != view.bounds.size { summarise.finish() }
        if tabSwitcher.superview === content {
            tabSwitcher.frame = content.bounds
            tabSwitcher.pageSize = content.bounds.size
            tabSwitcher.stripHeight = stripHeight
            tabSwitcher.topInset = view.safeAreaInsets.top+8
            let safeBottom = view.window?.safeAreaInsets.bottom ?? 0
            tabSwitcher.bottomInset = BottomBar.height(collapsed: false, safeBottom: safeBottom)+12
        }
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
        // Over Summarise's light backdrop.
        if let summarise, !summarise.isOverPage { return .darkContent }
        // Over the dark backdrop around the receded page. Behind More's panel, the page recedes
        // too little to clear the clock.
        if isPanelOpen, bottomBar.panel == .search, !UIAccessibility.isReduceMotionEnabled { return .lightContent }
        // Over the switcher's blur, which follows the appearance.
        if isTabSwitcherOpen { return .default }
        guard let topColor else { return .default }
        return PageEdgeColor.isDark(topColor) ? .lightContent : .darkContent
    }

    /// Makes an expanded Peek's live page this page, without loading it again. `topColor`, the
    /// Peek strip's colour, carries over so the strip doesn't change as the page moves in.
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
        currentTab.loadFavicon()
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
        for tile in [bottomBar.menu.shareTile, bottomBar.menu.summariseTile, bottomBar.menu.copyTile] { tile.isEnabled = url != nil }
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
        if gestureRecognizer === tabSwipe {
            // Only upwards, more up than sideways.
            let velocity = tabSwipe.velocity(in: view)
            return canShowTabSwitcher && !voice.isRecording && velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
        }
        if gestureRecognizer === summarisePinch { return (canSummarise || summarise?.canGrab == true) && !isPanelOpen }
        if gestureRecognizer === newPageHold {
            return VoiceInput.isSupported && !isPanelOpen && presentedViewController == nil && !isSwipingToTabs
        }
        return gestureRecognizer !== backSwipe
            || (!previousPages.isEmpty && !webView.canGoBack && !isPanelOpen && !isTabSwitcherOpen && summarise == nil)
    }

    /// Summarise's pinch watches alongside WebKit's zoom, taking over only when pinching in from its smallest.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === summarisePinch
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // The strip's tap must not compete with controls in the expanded toolbar or its panels.
        if gestureRecognizer === collapsedBarTap { return bottomBar.isCollapsed && !isPanelOpen }
        // Editing and selection belong to the field; answer scrolling belongs to TextKit.
        if gestureRecognizer === panelPan, let touched = touch.view {
            if bottomBar.panel == .find, touched.isDescendant(of: bottomBar.find.field)
                || touched.isDescendant(of: bottomBar.find.answerView) { return false }
            if bottomBar.panel == .search, touched.isDescendant(of: bottomBar.search.field) { return false }
        }
        return true
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
        bottomBar.find.attachHosts(to: self)
        collapsedBarTap.delegate = self
        collapsedBarTap.cancelsTouchesInView = false
        bottomBar.addGestureRecognizer(collapsedBarTap)
        panelPan.delegate = self
        bottomBar.addGestureRecognizer(panelPan)
        tabSwipe.delegate = self
        bottomBar.addGestureRecognizer(tabSwipe)
        bottomBar.tabsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if isTabSwitcherOpen { selectTab(tabIndex) } else { showTabSwitcher() }
        }, for: .primaryActionTriggered)
        bottomBar.tabsButton.count = tabs.count
        tabSwitcher.onSelect = { [weak self] index in self?.selectTab(index) }
        tabSwitcher.onClose = { [weak self] index in self?.closeTab(index) }
        bottomBar.newPageButton.addAction(UIAction { [weak self] _ in self?.openPanel() }, for: .primaryActionTriggered)
        newPageHold.minimumPressDuration = 0.3
        newPageHold.delegate = self
        bottomBar.newPageButton.addGestureRecognizer(newPageHold)
        bottomBar.search.onOpen = { [weak self] url in self?.openFromPanel(url) }
        bottomBar.search.onClose = { [weak self] in self?.closePanel() }
        bottomBar.moreButton.addAction(UIAction { [weak self] _ in self?.openPanel(.menu) }, for: .primaryActionTriggered)
        bottomBar.find.find = { [weak self] query, direction in
            await self?.find(query, direction: direction) ?? PageFind.Matches(count: 0, index: -1)
        }
        bottomBar.find.clear = { [weak self] in
            guard let page = self?.webView else { return }
            Task { await PageFind.clear(page, selectingCurrent: false) }
        }
        bottomBar.find.answer = { [weak self] question, history in
            let page = self?.webView
            let url = page?.url
            return PageAssistant.answer(question, history: history, page: {
                guard let page else { throw PageAssistant.Failure.service("There’s no page to ask about.") }
                await PageFind.clear(page, selectingCurrent: false)
                await PageFind.clearPassage(page)
                try Task.checkCancellation()
                return try await PageAssistant.snapshot(of: page)
            }, highlight: { [weak self] quote in
                guard !Task.isCancelled, let self, let page, page === self.webView, page.url == url,
                      self.isPanelOpen, self.bottomBar.find.mode == .ask else { return false }
                let found = await PageFind.highlightPassage(quote, in: page)
                guard !Task.isCancelled, page === self.webView, page.url == url,
                      self.isPanelOpen, self.bottomBar.find.mode == .ask else {
                    await PageFind.clearPassage(page)
                    return false
                }
                if found { await self.revealPassage(in: page) }
                return found
            })
        }
        bottomBar.find.clearPassage = { [weak self] in
            guard let page = self?.webView else { return }
            Task { await PageFind.clearPassage(page) }
        }
        bottomBar.find.onHeightChanged = { [weak self] in
            guard let self, isPanelOpen, bottomBar.panel == .find else { return }
            bottomBar.find.maximumAnswerHeight = max(80, min(300, view.bounds.height-keyboardHeight-160))
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.layoutBottomBar(); self.bottomBar.layoutIfNeeded()
            }
            if bottomBar.find.mode == .ask {
                Task { [weak self] in
                    guard let self else { return }
                    await revealPassage(in: webView)
                }
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Back and Forward leave More's panel open, to go on through the history; the rest close it.
        let address = bottomBar.menu.address, menu = bottomBar.menu
        address.addAction(UIAction { [weak self] _ in self?.editAddress() }, for: [.touchUpInside, .primaryActionTriggered])
        let actions: [(UIControl, @MainActor (BrowserViewController) -> Void)] = [
            (address.backButton, { $0.goBack() }),
            (address.forwardButton, { $0.webView.goForward() }),
            // While editing the address, X clears it, or closes the dialog once it's empty.
            (address.reloadButton, {
                if !$0.bottomBar.menu.address.isEditingURL { $0.closePanel(); $0.webView.reload() }
                else if ($0.bottomBar.search.field.text ?? "").isEmpty { $0.closePanel() }
                else { $0.bottomBar.search.clearAddress() }
            }),
            (menu.shareTile, { $0.closePanel(); $0.share() }),
            (menu.summariseTile, { $0.summariseFromMenu() }),
            (menu.findTile, { $0.openFind() }),
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
        // Summarise slides the bar off by its transform, which frames don't account for.
        let offset = bottomBar.transform
        bottomBar.transform = .identity
        bottomBar.frame = CGRect(x: 0, y: bounds.maxY-height, width: bounds.width, height: height)
        bottomBar.transform = offset
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
        case .find: BottomBar.findHeight(keyboard: keyboardHeight, safeBottom: safeBottom, answer: bottomBar.find.answerHeight)
        }
        return max(1, height-open)
    }

    /// How far the page recedes behind the open panel: fully behind New Page's, and behind smaller
    /// panels as far as the same rate of growth takes it. Find leaves the page where it is, to show
    /// its matches.
    private var panelRecede: CGFloat { bottomBar.panel == .find ? 0 : panelTravel/travel(of: .search) }

    /// Grows the bar and rounds its top corners as its buttons fade, setting the page back behind it.
    private func setPanel(_ expansion: CGFloat, recedingPage: Bool = true) {
        panelExpansion = expansion
        bottomBar.panelExpansion = expansion
        dimming.alpha = min(1, max(0, expansion))
        // Find's page stays clear, though a tap on it still closes the panel.
        dimming.backgroundColor = UIColor.black.withAlphaComponent(bottomBar.panel == .find ? 0 : 0.2)
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
        bottomBar.restoreAddress()
        bottomBar.panel = panel
        if panel == .search { bottomBar.search.begin() } else { updateAddress() }
        dimming.isUserInteractionEnabled = true
        bottomBar.accessibilityViewIsModal = true
        bottomBar.showContents(of: panel)
        settlePanelOpen()
    }

    private func settlePanelOpen(velocity: CGFloat = 0, alongside: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        let spring = PeekPresentationController.openSpring
        let animate = { alongside?(); self.setPanel(1); self.setNeedsStatusBarAppearanceUpdate() }
        guard !UIAccessibility.isReduceMotionEnabled else { animate(); completion?(); return }
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: velocity, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: animate) { finished in
            if finished { completion?() }
        }
    }

    /// Expand More into the New Page-sized editor, carrying its address on the same spring.
    func editAddress() {
        guard isPanelOpen, bottomBar.panel == .menu else { return }
        bottomBar.expandAddress(webView.url)
        settlePanelOpen(alongside: { self.bottomBar.menu.address.alignEditingContents() }) { [weak self] in
            guard let self, isPanelOpen, bottomBar.panel == .search else { return }
            bottomBar.search.finishAddressTransition()
        }
        bottomBar.search.focusAddress()
    }

    /// Shrinks the panel back into the bar, carrying on at `velocity`, in points per second downwards.
    func closePanel(velocity: CGFloat = 0) {
        guard isPanelOpen else { return }
        isPanelOpen = false
        bottomBar.search.end()
        bottomBar.find.end()
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

    /// More's Find turns its panel into a find field, the panel moving to just above the keyboard
    /// as its contents swap, and the page coming forward to show its matches.
    func openFind() {
        guard isPanelOpen, bottomBar.panel == .menu else { return }
        bottomBar.panel = .find
        bottomBar.showContents(of: .find)
        bottomBar.find.begin()
        settlePanelOpen()
        let back = PeekPresentationController.pageReturnSpring
        UIView.animate(springDuration: back.duration, bounce: back.bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            PageRecede.apply(0, to: self.content)
        }
    }

    /// Find's panel follows the keyboard up and down.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let screen = view.window?.screen else { return }
        let frame = view.convert(end, from: screen.coordinateSpace)
        keyboardHeight = frame.minY < view.bounds.maxY ? view.bounds.maxY-frame.minY : 0
        guard isPanelOpen, bottomBar.panel == .find else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16),
                                                                  .beginFromCurrentState, .allowUserInteraction]) {
            self.bottomBar.find.maximumAnswerHeight = max(80, min(300, self.view.bounds.height-self.keyboardHeight-160))
            self.layoutBottomBar()
            self.bottomBar.layoutIfNeeded()
        }
    }

    /// Finds in the page, then brings the current match out from under Find's panel and the
    /// keyboard, into the middle of what shows of the page.
    private func find(_ query: String, direction: PageFind.Direction) async -> PageFind.Matches {
        let page = webView
        let matches = await PageFind.find(query, direction: direction, in: page)
        guard matches.index >= 0, direction != .refresh, page === webView else { return matches }
        let script = """
        const current = CSS.highlights.get('rise-find-current');
        for (const range of current || []) { const rect = range.getBoundingClientRect(); return [rect.top, rect.bottom] }
        return null
        """
        guard let rect = try? await page.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: PageFind.world) as? [Double],
              rect.count == 2, page === webView, isPanelOpen, bottomBar.panel == .find else { return matches }
        let scroll = page.scrollView, zoom = scroll.zoomScale, margin: CGFloat = 24
        let panelTop = bottomBar.frame.minY
        let shownTop = margin, shownBottom = view.convert(CGPoint(x: 0, y: panelTop), to: page).y-margin
        let top = CGFloat(rect[0])*zoom, bottom = CGFloat(rect[1])*zoom
        guard shownBottom > shownTop, top < shownTop || bottom > shownBottom else { return matches }
        let lowest = -scroll.adjustedContentInset.top
        let highest = max(lowest, scroll.contentSize.height+scroll.adjustedContentInset.bottom-scroll.bounds.height)
        let y = scroll.contentOffset.y+(top+bottom)/2-(shownTop+shownBottom)/2
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(highest, max(lowest, y))), animated: true)
        return matches
    }

    /// A supporting passage is kept above the answer sheet, as find matches are.
    private func revealPassage(in page: WKWebView) async {
        let script = """
        for (const range of CSS.highlights.get('rise-passage') || []) {
            const r = range.getBoundingClientRect(); return [r.top, r.bottom];
        }
        return null;
        """
        guard let rect = try? await page.callAsyncJavaScript(script, arguments: [:], in: nil,
                contentWorld: PageFind.world) as? [Double], rect.count == 2, page === webView,
              isPanelOpen, bottomBar.find.mode == .ask else { return }
        let scroll = page.scrollView, zoom = scroll.zoomScale
        let visibleBottom = view.convert(CGPoint(x: 0, y: bottomBar.frame.minY), to: page).y-24
        let top = CGFloat(rect[0])*zoom, bottom = CGFloat(rect[1])*zoom
        guard top < 24 || bottom > visibleBottom else { return }
        let low = -scroll.adjustedContentInset.top
        let high = max(low, scroll.contentSize.height+scroll.adjustedContentInset.bottom-scroll.bounds.height)
        let target = scroll.contentOffset.y+(top+bottom)/2-(24+visibleBottom)/2
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(high, max(low, target))), animated: true)
    }

    /// Opens a page chosen in the panel. The panel grows up to fill the window as its search fades
    /// out and the new page appears inside it; the page then stays, the previous one held for Back.
    func openFromPanel(_ url: URL) {
        guard isPanelOpen else { return }
        if bottomBar.search.editingAddress != nil {
            closePanel()
            webView.load(URLRequest(url: url))
            return
        }
        isPanelOpen = false
        bottomBar.search.end()
        dimming.isUserInteractionEnabled = false
        bottomBar.accessibilityViewIsModal = false
        view.isUserInteractionEnabled = false

        let page = Self.makeWebView()
        adoptDelegates(of: page)
        page.load(URLRequest(url: url))
        // Until the page paints, the strip above it and the bar take its background's colour, or
        // in dark mode the dark surface it shows through to.
        let color = (PagePaintWatcher.shared.isTransparent(page) ? .systemBackground : page.underPageBackgroundColor)
            .resolvedColor(with: traitCollection)
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
            openInNewTab(page, topColor: color)
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
        let distance = pan.translation(in: view).y
        switch pan.state {
        case .began, .changed:
            dragPanel(to: distance)
        case .ended, .cancelled, .failed:
            let velocity = pan.state == .ended ? pan.velocity(in: view).y : 0
            finishPanelDrag(at: distance, velocity: velocity)
        default: break
        }
    }

    func dragPanel(to distance: CGFloat) {
        guard isPanelOpen else { return }
        let travel = panelTravel
        let stretch = 40*(1-1/(1+max(0, -distance)/160))
        setPanel(distance >= 0 ? max(0, 1-distance/travel) : 1+stretch/travel)
    }

    func finishPanelDrag(at distance: CGFloat, velocity: CGFloat = 0) {
        guard isPanelOpen else { return }
        let travel = panelTravel
        if velocity > 600 || (distance > travel*0.3 && velocity > -200) {
            closePanel(velocity: velocity)
        } else {
            settlePanelOpen(velocity: distance > 0 ? -velocity/distance : 0)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        if !isPanelOpen, isTabSwitcherOpen { selectTab(tabIndex); return true }
        guard isPanelOpen else { return super.accessibilityPerformEscape() }
        closePanel()
        return true
    }

    // MARK: Summarise

    private var canSummarise: Bool {
        allowsPeek && summarise == nil && !isTabSwitcherOpen && !isSwipingToTabs && presentedViewController == nil
            && view.window != nil && shareableURL != nil
    }

    /// The page shrinks into Summarise's card with the fingers as they pinch in from its smallest
    /// zoom, which WebKit would otherwise follow with a bounce, and carries on into it when let go.
    @objc private func pinchToSummarise(_ pinch: UIPinchGestureRecognizer) {
        let scroll = webView.scrollView
        switch pinch.state {
        case .began, .changed:
            if pinch.state == .began {
                pinchFromSmallest = scroll.zoomScale <= scroll.minimumZoomScale+0.001
                if pinchFromSmallest { scroll.bouncesZoom = false }
                pinchStart = pinch.location(in: view)
            }
            // Between the fingers, until one lifts.
            if pinch.numberOfTouches >= 2 { pinchCentroid = pinch.location(in: view) }
            if let summarise {
                // Caught as soon as the fingers move, on its way back to the page.
                if pinch.state == .began, summarise.canGrab {
                    scroll.bouncesZoom = false
                    pinchGrabScale = pinch.scale
                    summarise.grab(at: pinchCentroid)
                    stopFollowing(scroll)
                }
                summarise.updatePinch(scale: pinch.scale/pinchGrabScale, centroid: pinchCentroid)
            } else if pinchFromSmallest, pinch.scale < 0.99, scroll.zoomScale <= scroll.minimumZoomScale+0.001,
                      canSummarise, !isPanelOpen {
                pinchGrabScale = 1
                startSummarise(.pinch, at: pinchStart)
                summarise?.updatePinch(scale: pinch.scale, centroid: pinchCentroid)
                stopFollowing(scroll)
            }
        case .ended, .cancelled, .failed:
            scroll.bouncesZoom = true
            pinchFromSmallest = false
            summarise?.endPinch(cancelled: pinch.state != .ended)
        default: break
        }
    }

    /// Summarise has the pinch now: WebKit's own zoom and scrolling, following the same fingers,
    /// would only move the page underneath and cost it frames. Turning them off and on again ends
    /// them, leaving them ready for the next touch.
    private func stopFollowing(_ scroll: UIScrollView) {
        for gesture in [scroll.pinchGestureRecognizer, scroll.panGestureRecognizer] {
            guard let gesture, gesture.isEnabled else { continue }
            gesture.isEnabled = false
            gesture.isEnabled = true
        }
    }

    /// Summarise in More: the panel goes at once and the whole page shrinks into the card.
    func summariseFromMenu() {
        guard isPanelOpen, bottomBar.panel == .menu, canSummarise else { return }
        isPanelOpen = false
        bottomBar.search.end()
        bottomBar.find.end()
        dimming.isUserInteractionEnabled = false
        bottomBar.accessibilityViewIsModal = false
        setPanel(0)
        bottomBar.showContents(of: nil, animated: false)
        startSummarise(.menu)
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Lays Summarise over the page, under the bar, from a picture of the page as it is.
    func startSummarise(_ path: SummariseView.Path, at point: CGPoint = .zero) {
        guard canSummarise else { return }
        let page = webView
        let title = [page.title, page.url?.host()].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let size = view.bounds.size
        let summarise = SummariseView(page: { [content] in
            content.snapshotView(afterScreenUpdates: false) ?? UIView(frame: CGRect(origin: .zero, size: size))
        }, title: title, size: size)
        summarise.makeSummary = { try await PageSummary.make(of: PageAssistant.snapshot(of: page)) }
        let log = SummariseLog(path: path == .pinch ? "pinch" : "menu", page: page.url?.host() ?? "no page")
        summarise.log = log
        let describePage = { [weak page] in
            guard let page else { return "page gone" }
            return String(format: "page %@, zoom %.2f, scrolled %.0f of %.0f pt", page.isLoading ? "loading" : "loaded",
                          page.scrollView.zoomScale, page.scrollView.contentOffset.y, page.scrollView.contentSize.height)
        }
        summarise.describePage = describePage
        log.event("page", describePage())
        // The page is where the card shows it, though fingers may move it underneath: two of them
        // pan it as they pinch, and the page takes touches as the card grows back.
        let scroll = page.scrollView, zoom = scroll.zoomScale, offset = scroll.contentOffset
        summarise.onBar = { [weak self] offset in
            guard let self else { return }
            bottomBar.transform = offset == 0 ? .identity : CGAffineTransform(translationX: 0, y: offset*(bottomBar.bounds.height+4))
        }
        summarise.onStatusBar = { [weak self] in self?.setNeedsStatusBarAppearanceUpdate() }
        summarise.onFinish = { [weak self, weak summarise, weak scroll] in
            guard let self, let summarise, self.summarise === summarise else { return }
            if let scroll, scroll.zoomScale != zoom || scroll.contentOffset != offset {
                log.event("page moved", String(format: "to %.0f, %.0f at zoom %.2f, back to %.0f, %.0f at zoom %.2f",
                                               scroll.contentOffset.x, scroll.contentOffset.y, scroll.zoomScale, offset.x, offset.y, zoom))
                scroll.setZoomScale(zoom, animated: false)
                scroll.setContentOffset(offset, animated: false)
            }
            summarise.removeFromSuperview()
            self.summarise = nil
            bottomBar.transform = .identity
            bottomBar.isUserInteractionEnabled = true
            setNeedsStatusBarAppearanceUpdate()
        }
        view.insertSubview(summarise, belowSubview: bottomBar)
        bottomBar.isUserInteractionEnabled = false
        self.summarise = summarise
        if path == .pinch { summarise.beginPinch(at: point) } else { summarise.startFromMenu() }
    }

    // MARK: Tabs

    /// Opens a page chosen in New Page's panel in a new tab after this one.
    private func openInNewTab(_ page: WKWebView, topColor: UIColor?) {
        if !tabSwitcher.isHidden { closeTabSwitcherAtOnce() } else { currentTab.snapshot = snapshotPage() }
        let previous = webView
        tabs.insert(BrowserTab(webView: page), at: tabIndex+1)
        tabIndex += 1
        bottomBar.tabsButton.count = tabs.count
        page.transform = .identity
        install(page)
        previous.removeFromSuperview()
        adoptDelegates(of: page)
        if let topColor { setTopColor(topColor, animated: false) }
        pageChanged(from: topColor)
    }

    /// How the page looks now, strip included, for its tab's card.
    private func snapshotPage() -> UIImage {
        let bounds = content.bounds
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in content.drawHierarchy(in: bounds, afterScreenUpdates: false) }
    }

    /// Also while a card is still growing back into its page, which turns it around.
    private var canShowTabSwitcher: Bool {
        allowsPeek && !isTabSwitcherOpen && !isPanelOpen && presentedViewController == nil && view.window != nil
    }

    /// Shrinks the page into its card among the other tabs', over a blur of it, or back into it as
    /// it grows out.
    func showTabSwitcher() {
        guard canShowTabSwitcher else { return }
        prepareTabSwitcher()
        tabSwitcher.present()
    }

    private func prepareTabSwitcher() {
        if tabSwitcher.isHidden {
            setBottomBarCollapsed(false)
            let snapshot = snapshotPage()
            currentTab.snapshot = snapshot
            tabSwitcher.load(tabs, current: tabIndex)
            tabSwitcher.prepare(backdrop: snapshot)
        }
        isTabSwitcherOpen = true
        bottomBar.tabsButton.setShowsSwitcher(true, animated: true)
        UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
    }

    /// Grows a tab's card back into the page, making it the current tab.
    func selectTab(_ index: Int) {
        guard isTabSwitcherOpen, !isSwipingToTabs, tabs.indices.contains(index) else { return }
        if index != tabIndex { switchTab(to: index) }
        isTabSwitcherOpen = false
        bottomBar.tabsButton.setShowsSwitcher(false, animated: true)
        tabSwitcher.dismiss(to: index) { [weak self] in self?.updateTabsPreview() }
        UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
    }

    private func closeTabSwitcherAtOnce() {
        tabSwitcher.hide()
        isTabSwitcherOpen = false
        bottomBar.tabsButton.setShowsSwitcher(false, animated: true)
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Puts a tab's page in place, under the switcher.
    private func switchTab(to index: Int) {
        let previous = webView
        tabIndex = index
        webView.transform = .identity
        install(webView)
        if previous !== webView { previous.removeFromSuperview() }
        pageChanged()
    }

    /// Closes a tab from its card; the last one stays.
    private func closeTab(_ index: Int) {
        guard isTabSwitcherOpen, tabs.count > 1, tabs.indices.contains(index) else { return }
        let closing = tabs.remove(at: index)
        if index < tabIndex {
            tabIndex -= 1
        } else if index == tabIndex {
            tabIndex = min(index, tabs.count-1)
            install(webView)
            closing.webView.removeFromSuperview()
            pageChanged()
        }
        tabSwitcher.remove(at: index, current: tabIndex)
        bottomBar.tabsButton.count = tabs.count
    }

    @objc private func swipeToTabs(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        switch pan.state {
        case .began:
            beginTabSwipe()
            updateTabSwipe(translation)
        case .changed:
            updateTabSwipe(translation)
        case .ended, .cancelled, .failed:
            endTabSwipe(velocity: pan.state == .ended ? pan.velocity(in: view) : .zero, cancelled: pan.state != .ended)
        default: break
        }
    }

    /// The swipe up the bottom bar, in steps: the page follows the finger, shrinking, and when let
    /// go past a quarter of the way, or flicked up, drops into its card.
    /// A swipe as a card grows back into its page catches it there.
    func beginTabSwipe() {
        guard canShowTabSwitcher else { return }
        isSwipingToTabs = true
        let growing = !tabSwitcher.isHidden
        prepareTabSwitcher()
        if growing { tabSwitcher.catchPage() }
    }

    func updateTabSwipe(_ translation: CGPoint) {
        guard isSwipingToTabs else { return }
        tabSwitcher.update(swipe: translation)
    }

    func endTabSwipe(velocity: CGPoint, cancelled: Bool = false) {
        guard isSwipingToTabs else { return }
        isSwipingToTabs = false
        let progress = tabSwitcher.swipeProgress
        let commit = !cancelled && (velocity.y < -400 || (progress > 0.25 && velocity.y < 400))
        if commit {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
        } else {
            isTabSwitcherOpen = false
            bottomBar.tabsButton.setShowsSwitcher(false, animated: true)
            UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
        }
        tabSwitcher.finishSwipe(commit: commit)
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


    override func viewDidLoad() {
        super.viewDidLoad()
        if allowsPeek {
            tint.fillsOverscroll = true
            pullToReload.onGapHeld = { [weak self] held in self?.tint.gapHeld = held }
            pageChanged()
            VoiceInput.prepare()
            DispatchQueue.main.async { SummariseView.prepareGlows() }
        }
        if let startURL { webView.load(URLRequest(url: startURL)) }
    }

    @objc private func holdNewPage(_ hold: UILongPressGestureRecognizer) {
        switch hold.state {
        case .began: startListening()
        case .ended: finishListening()
        case .cancelled, .failed: cancelListening()
        default: break
        }
    }

    /// Swaps New Page's plus for a waveform of the voice, humming softly while it listens.
    func startListening() {
        guard voice.begin() else { return }
        bottomBar.setListening(true) { [weak voice] in voice?.level ?? 0 }
    }

    /// Opens New Page as a tap would, its field filled with what was said once it's transcribed,
    /// a spinner standing in for the clear button meanwhile. Without permission yet, it just opens.
    func finishListening() {
        guard voice.isRecording else { openPanel(); return }
        let transcription = voice.finish()
        bottomBar.setListening(false)
        openPanel()
        guard isPanelOpen, bottomBar.panel == .search else { transcription.cancel(); return }
        let opening = bottomBar.search.beginTranscribing()
        Task { [weak self] in
            let text = await transcription.value
            self?.bottomBar.search.finishTranscribing(text, for: opening)
        }
    }

    private func cancelListening() {
        guard voice.isRecording else { return }
        voice.cancel()
        bottomBar.setListening(false)
    }

    // With no tab UI yet, links requesting a new window navigate this page instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        PagePaintWatcher.shared.didFinish(webView)
        tabs.first { $0.webView === webView }?.loadFavicon()
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
