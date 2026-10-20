import UIKit
import WebKit
import SwiftUI

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
    /// A swipe down the open bar collapses it, as scrolling down the page does.
    private lazy var barCollapseSwipe = UIPanGestureRecognizer(target: self, action: #selector(swipeBarDown))
    /// Holding New Page listens for a search; letting go opens New Page with it transcribed.
    private lazy var newPageHold = UILongPressGestureRecognizer(target: self, action: #selector(holdNewPage))
    let voice = VoiceInput()
    private var isSwipingToTabs = false
    private lazy var backSwipe = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(swipeBack))
    private lazy var panelBackSwipe = UIPanGestureRecognizer(target: self, action: #selector(swipePanelBack))
    let isPrivateBrowsing: Bool
    let websiteDataStore: WKWebsiteDataStore
    lazy var quickActions = BrowserQuickActions(browser: self)
    private let sessionStore: MobileBrowserSessionStore?
    private var lastSavedSession: MobileBrowserSession?
    let addressSuggestions: MobileAddressSuggestions
    let tabSync: SharedTabsSync?
    let tabPreviews: BackgroundTabPreviews?
    private var isApplyingSharedTabs = false
    private var hasPendingSharedTabs = false
    /// Links from other apps, waiting for the browser to be free to open them.
    private var pendingLinks: [URL] = []
    private let allowsPeek: Bool
    private var opensSearchOnFirstAppearance: Bool
    /// Fills the area behind the status bar with the colour along the page's top edge, as Arc
    /// does, so the page seems to reach the top of the screen. Peek pages have their own strip.
    let topStrip = UIView()
    /// Holds the strip and the pages, so they recede together behind the bar's panel.
    let content = UIView()
    /// Preview WebKit pages remain in the window to paint, behind an opaque black cover.
    private let previewBackdrop = UIView()
    let navigationStatus = BrowserNavigationStatus()
    /// Darkens the receded page; tapping it closes the panel.
    private let dimming = UIView()
    private lazy var tint = PageEdgeTint { [weak self] color in self?.setTopColor(color, animated: true) }
    private(set) lazy var pullToReload = PullToReload { [weak self] in self?.reloadPage() }
    /// Only the main page has one; Peek pages are closed and opened by their handle.
    let bottomBar = BottomBar()
    /// Continues the bar's opaque background to the screen edge during its upward rebound.
    private let bottomBarUnderfill = UIView()
    let downloadOrigins = DownloadOriginTracker()
    private var scrollObservation: NSKeyValueObservation?
    /// Keeps More's address and its Back and Forward up to date with the page.
    private var addressObservations: [NSKeyValueObservation] = []
    let adBlocker: MobileAdBlocker
    let videoPlayback: VideoPlaybackPolicy
    var isVideoContextMenuOpen = false
    weak var adBlockingPage: WKWebView?
    var adBlockingNavigation: WKNavigation?
    var adBlockingTask: Task<Void, Never>?
    var adBlockingID: UUID?
    var reloadingCookieBanners = false
    /// How far the page has scrolled in its current direction, to collapse or open the bar.
    private var scrollTravel: CGFloat = 0, lastScrollOffset: CGFloat = 0
    /// The panel New Page grows the bar into, as a share of the window's height.
    static let panelHeightFraction: CGFloat = 0.71
    private(set) var isPanelOpen = false
    /// Growing from the panel to fill the window with a page chosen in it: quicker than a Peek
    /// expanding, and likewise without overshoot, which would fall outside the screen.
    static let panelFillSpring = (duration: 0.16, bounce: 0.0)
    /// How far the bar has grown into its panel: 0 is the bar and 1 the open panel.
    private(set) var panelExpansion: CGFloat = 0
    /// How much of the window the keyboard covers, which Find's panel sits above.
    private var keyboardHeight: CGFloat = 0
    private lazy var panelPan = UIPanGestureRecognizer(target: self, action: #selector(dragPanel(_:)))
    let panelMotion = PanelMotion()
    #if DEBUG
    var onPanelCloseCommit: (() -> Void)?
    /// How far below the bar's drawn bottom edge the underfill reaches, as drawn.
    var bottomBarUnderfillCoverage: Double {
        let bar = bottomBar.layer.presentation()?.frame ?? bottomBar.frame
        let fill = bottomBarUnderfill.layer.presentation()?.frame ?? bottomBarUnderfill.frame
        guard fill.minY <= bar.maxY+0.5 else { return 0 }
        return Double(max(0, fill.maxY-bar.maxY))
    }
    #endif
    private(set) var downloadsSheet = DownloadsSheetState()
    private var historyReturnPanel: BottomBar.Panel?
    /// Pinching in on the page, from its smallest zoom, folds it up and summarises it.
    private lazy var summarisePinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchToSummarise(_:)))
    private var pinchFromSmallest = false
    /// Where the pinch's fingers started, and where they were last together.
    private var pinchStart = CGPoint.zero, pinchCentroid = CGPoint.zero
    /// The fingers' scale when Summarise caught the card, which they go on from.
    private var pinchGrabScale: CGFloat = 1
    /// The page folded into a card over its summary, between the page and the bottom bar.
    private(set) var summarise: SummariseView?
    /// Keep one text view graph for this browser: destroying it at the page handoff costs frames.
    /// Each scene has a fresh reveal model, installed in the host when its own summary arrives.
    private lazy var summaryHost: UIHostingController<SummaryBlocks> = {
        let host = UIHostingController(rootView: SummaryBlocks(reveal: SummaryReveal()))
        host.overrideUserInterfaceStyle = .light
        return host
    }()
    private lazy var collapsedBarTap = UITapGestureRecognizer(target: self, action: #selector(openCollapsedBar))

    init(startURL: URL? = BrowserViewController.homeURL, allowsPeek: Bool = true,
         opensSearchOnFirstAppearance: Bool = false, adBlocker: MobileAdBlocker? = nil,
         sessionStore: MobileBrowserSessionStore? = nil, tabSync: SharedTabsSync? = nil,
         previewCacheURL: URL? = nil, suggestionsDirectory: URL? = nil,
         isPrivateBrowsing: Bool = false, websiteDataStore: WKWebsiteDataStore? = nil,
         videoPlayback: VideoPlaybackPolicy = .shared) {
        self.isPrivateBrowsing = isPrivateBrowsing
        self.videoPlayback = videoPlayback
        let dataStore: WKWebsiteDataStore
        if isPrivateBrowsing { dataStore = websiteDataStore.flatMap { $0.isPersistent ? nil : $0 } ?? .nonPersistent() }
        else { dataStore = websiteDataStore ?? .default() }
        self.websiteDataStore = dataStore
        addressSuggestions = MobileAddressSuggestions(directory: suggestionsDirectory ??
            sessionStore?.fileURL.deletingLastPathComponent() ?? URL.temporaryDirectory.appendingPathComponent("RiseAddresses-\(UUID())"),
            recordsBrowsing: !isPrivateBrowsing)
        let blocker = adBlocker ?? (isPrivateBrowsing ? MobileAdBlocker(preferences: nil) : .shared)
        self.adBlocker = blocker
        self.sessionStore = allowsPeek && !isPrivateBrowsing ? sessionStore : nil
        self.tabSync = allowsPeek && !isPrivateBrowsing ? tabSync : nil
        tabPreviews = allowsPeek && !isPrivateBrowsing ? previewCacheURL.map { BackgroundTabPreviews(cacheURL: $0, adBlocker: blocker) } : nil
        self.allowsPeek = allowsPeek
        let restored = self.sessionStore?.load()
        self.opensSearchOnFirstAppearance = opensSearchOnFirstAppearance
        if let restored {
            tabs = restored.tabs.map { BrowserTab(webView: Self.makeWebView(dataStore: dataStore, videoPlayback: videoPlayback), restoring: $0) }
            tabIndex = restored.tabs.firstIndex { $0.id == restored.selectedTabID } ?? 0
        } else {
            tabs = [BrowserTab(webView: Self.makeWebView(dataStore: dataStore, videoPlayback: videoPlayback), restoring: .init(url: startURL))]
        }
        super.init(nibName: nil, bundle: nil)
        for tab in tabs { track(tab) }
        addressSuggestions.onChange = { [weak self] in
            self?.tabSync?.captureSearches()
            self?.bottomBar.search.refresh()
        }
        self.tabSync?.onSearchesChange = { [weak self] in self?.bottomBar.search.refresh() }
        self.tabSync?.onHistoryChange = { [weak self] in self?.bottomBar.search.refresh() }
        self.tabSync?.onTabsChange = { [weak self] in self?.applySharedTabs($0) }
        self.tabSync?.onStatusChange = { [weak self] _ in self?.updateAppSettings() }
    }

    private func track(_ tab: BrowserTab) {
        adoptDelegates(of: tab.webView)
        tab.onPageChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.addressSuggestions.changed(tab.webView)
            if tab.webView === self.webView, self.isViewLoaded {
                self.updateAddress()
                self.updateNavigationStatus()
            }
            self.saveSession()
        }
    }

    /// Save on tab/navigation changes as well as lifecycle events: an update can terminate the
    /// process without another background callback. Test and Peek browsers have no session store.
    func saveSession(flush: Bool = false) {
        if flush { addressSuggestions.save() }
        guard let sessionStore else { return }
        let session = MobileBrowserSession(tabs: tabs.map(\.sessionTab), selectedTabID: currentTab.id)
        if flush || session != lastSavedSession {
            sessionStore.save(session)
            lastSavedSession = session
        }
        if flush { sessionStore.flush() }
        if !isApplyingSharedTabs { tabSync?.capture(sharedTabsSnapshot) }
        if flush { tabSync?.flush() }
        refreshTabPreviews()
    }

    private var sharedTabsSnapshot: [SharedBrowserTab] {
        tabs.filter { !$0.isSyncPlaceholder }.map {
            let saved = $0.sessionTab
            return SharedBrowserTab(id: saved.id, url: saved.url?.absoluteString, title: saved.title, navigationHistory: saved.navigationHistory)
        }
    }

    @objc private func aiSettingsChanged() { updateAIAvailability() }

    private func updateAIAvailability() {
        let enabled = MobileAISettings.shared.enabled
        bottomBar.menu.summariseTile.isEnabled = enabled
        bottomBar.menu.summariseTile.alpha = enabled ? 1 : 0.35
        bottomBar.find.setAIEnabled(enabled)
        if !enabled { summarise?.finish() }
    }

    private func updateAppSettings() {
        bottomBar.appSettings.ai.refresh()
        updateAIAvailability()
        bottomBar.appSettings.showAutoplay(enabled: videoPlayback.allowsAutoplay)
        if isPrivateBrowsing {
            bottomBar.appSettings.showSync(enabled: false, message: "Private tabs are never saved or synced with iCloud.")
            bottomBar.appSettings.syncRow.isEnabled = false
            bottomBar.appSettings.syncRow.toggle.isEnabled = false
            return
        }
        bottomBar.appSettings.showSync(enabled: tabSync?.isEnabled ?? true,
                                      message: tabSync?.status.message ?? SharedTabsSync.Status.ready.message)
    }

    private func applySharedTabs(_ incoming: [SharedBrowserTab]) {
        guard isViewLoaded, !isSwipingToTabs, !isTabSwitcherOpen, tabSwitcher.isHidden,
              summarise == nil, !isPanelOpen, !isVideoContextMenuOpen, presentedViewController == nil else {
            hasPendingSharedTabs = true; return
        }
        isApplyingSharedTabs = true
        hasPendingSharedTabs = false
        let previous = webView, selected = currentTab.id, previousIndex = tabIndex
        let existing = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let incoming = SharedTabsReconciliation.preservingActiveTab(in: incoming, displayed: sharedTabsSnapshot, activeID: selected)
        var next = incoming.map { saved -> BrowserTab in
            if let tab = existing[saved.id], tab.sessionTab.url?.absoluteString == saved.url,
               saved.navigationHistory.map({ tab.navigationHistory?.hasSameRoute(as: $0) == true }) ?? true {
                tab.rememberSharedTitle(saved.title)
                return tab
            }
            let tab = BrowserTab(webView: Self.makeWebView(dataStore: websiteDataStore, videoPlayback: videoPlayback), restoring: .init(
                id: saved.id, url: saved.url.flatMap(URL.init(string:)), title: saved.title, navigationHistory: saved.navigationHistory))
            track(tab)
            return tab
        }
        if next.isEmpty {
            let blank = BrowserTab(webView: Self.makeWebView(dataStore: websiteDataStore, videoPlayback: videoPlayback))
            blank.isSyncPlaceholder = true
            track(blank); next = [blank]
        }
        for old in tabs where !next.contains(where: { $0 === old }) {
            old.onPageChange = nil
            for page in [old.webView] + old.previousPages + old.forwardPages {
                page.stopLoading(); page.navigationDelegate = nil; page.uiDelegate = nil
            }
        }
        tabs = next
        tabIndex = tabs.firstIndex { $0.id == selected } ?? min(previousIndex, tabs.count-1)
        if previous !== webView { install(webView); previous.removeFromSuperview() }
        bottomBar.tabsButton.count = tabs.count
        tabSync?.acknowledge(sharedTabsSnapshot)
        pageChanged()
        isApplyingSharedTabs = false
        saveSession()
    }

    private func applyPendingSharedTabs() {
        guard hasPendingSharedTabs, let tabSync, tabSync.isEnabled else { return }
        applySharedTabs(tabSync.tabs)
    }

    /// Applies what arrived while the browser was busy, once it has settled.
    func applyPendingChanges() {
        guard !quickActions.applyPending() else { return }
        openPendingLinks()
        applyPendingSharedTabs()
    }

    /// Opens links from other apps, each in a new tab after the current one, as Safari does.
    func openLinks(_ urls: [URL]) {
        let links = urls.filter { ["http", "https"].contains($0.scheme?.lowercased()) }
        guard !links.isEmpty else { return }
        // The link is what the person came for, rather than the search a fresh launch opens with.
        opensSearchOnFirstAppearance = false
        pendingLinks += links
        applyPendingChanges()
    }

    private func openPendingLinks() {
        guard !pendingLinks.isEmpty, allowsPeek, isViewLoaded, view.window != nil, !isSwipingToTabs,
              isTabSwitcherOpen || tabSwitcher.isHidden else { return }
        // Clears whatever is over the page first; each calls back here once it has gone.
        if presentedViewController != nil { dismiss(animated: true) { [weak self] in self?.applyPendingChanges() }; return }
        if let summarise { summarise.finish(); return }
        if isPanelOpen { closePanel(); return }
        let links = pendingLinks
        pendingLinks = []
        for url in links {
            let page = Self.makeWebView(dataStore: websiteDataStore, videoPlayback: videoPlayback)
            adoptDelegates(of: page)
            page.load(URLRequest(url: url))
            openInNewTab(page, topColor: nil, initialURL: url)
        }
    }

    func refreshTabPreviews() {
        guard isViewLoaded, view.window != nil else { return }
        tabPreviews?.update(tabs: tabs, selected: currentTab, viewport: view.bounds.size, stripHeight: stripHeight)
    }

    func setTabPreviewsActive(_ active: Bool) {
        tabPreviews?.setActive(active)
        if active {
            currentTab.retryUncommittedPage()
            updateNavigationStatus()
            refreshTabPreviews()
        }
    }

    static func makeWebView(dataStore: WKWebsiteDataStore = .default(),
                            videoPlayback: VideoPlaybackPolicy = .shared) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        MobileTabHistory.configure(configuration)
        videoPlayback.configure(configuration)
        configuration.userContentController.addUserScript(VideoContextMenuScript.userScript)
        // Honor the focus-zoom cap in our viewport script while still allowing manual pinch zoom.
        configuration.ignoresViewportScaleLimits = true
        configuration.userContentController.addUserScript(InputZoomPolicy.userScript)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        videoPlayback.track(webView)
        // In dark mode, see-through until it paints, rather than flashing WebKit's white.
        PagePaintWatcher.shared.install(on: webView)
        return webView
    }

    private func adoptDelegates(of webView: WKWebView) {
        VideoContextMenus.install(on: webView, browser: self)
        downloadOrigins.install(on: webView)
        if !isPrivateBrowsing { addressSuggestions.learner.install(on: webView) }
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
        let peek = PeekViewController(url: url, isPrivateBrowsing: isPrivateBrowsing, websiteDataStore: websiteDataStore, adBlocker: adBlocker, videoPlayback: videoPlayback) { [weak self] page, color in self?.adopt(page, topColor: color) }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        present(peek, animated: true)
    }

    required init?(coder: NSCoder) { fatalError("Use init(startURL:)") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateAIAvailability()
        if allowsPeek { setUpDownloads() }
        applyPendingChanges()
        tabPreviews?.setActive(true)
        refreshTabPreviews()
        // Only a freshly created scene opts in. Consume it once, so returning to the app or
        // dismissing a presented controller preserves whatever the person was doing.
        guard opensSearchOnFirstAppearance else { return }
        opensSearchOnFirstAppearance = false
        openPanel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tabPreviews?.setActive(false)
    }

    override func loadView() {
        view = UIView()
        // Only shows around the page as it recedes behind the panel.
        view.backgroundColor = .black
        if let tabPreviews {
            view.addSubview(tabPreviews.host)
            previewBackdrop.backgroundColor = .black
            previewBackdrop.isUserInteractionEnabled = false
            view.addSubview(previewBackdrop)
            tabPreviews.canRender = { [weak self] in
                guard let self else { return false }
                return view.window?.windowScene?.activationState == .foregroundActive
                    && !isSwipingToTabs && !tabSwitcher.isAnimatingOrTracking && summarise == nil
                    && !isPanelOpen && presentedViewController == nil
            }
        }
        content.backgroundColor = .systemBackground
        content.clipsToBounds = true
        view.addSubview(content)
        topStrip.backgroundColor = .systemBackground
        content.addSubview(pullToReload.overlay)
        install(webView)
        content.addSubview(navigationStatus)
        navigationStatus.retry = { [weak self] in self?.reloadPage() }
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
        panelBackSwipe.maximumNumberOfTouches = 1
        panelBackSwipe.delegate = self
        view.addGestureRecognizer(panelBackSwipe)
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
        tabPreviews?.host.frame = view.bounds
        previewBackdrop.frame = view.bounds
        dimming.frame = view.bounds
        navigationStatus.frame = pageFrame
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
        currentTab.discardForwardPages()
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
        saveSession()
        currentTab.loadIfNeeded()
        updateNavigationStatus()
    }

    /// Back in More's panel also returns past the start of the page's history to the page it replaced.
    func updateAddress() {
        updateAdBlockingSettings()
        let url = shareableURL
        bottomBar.menu.address.show(url, canGoBack: webView.canGoBack || !previousPages.isEmpty,
                               canGoForward: webView.canGoForward || !currentTab.forwardPages.isEmpty)
        for tile in [bottomBar.menu.shareTile, bottomBar.menu.copyTile] { tile.isEnabled = url != nil }
        bottomBar.menu.summariseTile.isEnabled = currentTab.hasCommittedDocument && webView.url.map(Self.canPeek) == true
        bottomBar.menu.findTile.isEnabled = currentTab.hasCommittedDocument
    }

    /// Back past the start of an adopted page's history returns to the page it replaced.
    func returnToPreviousPage() {
        guard let previous = previousPages.popLast() else { return }
        previous.transform = .identity
        install(previous)
        currentTab.forwardPages.append(webView)
        webView.removeFromSuperview()
        webView = previous
        pageChanged()
    }

    func returnToNextPage() {
        guard let next = currentTab.forwardPages.popLast() else { return }
        next.transform = .identity
        install(next)
        previousPages.append(webView)
        webView.removeFromSuperview()
        webView = next
        pageChanged()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // WebKit's own swipe handles Back within the page's history.
        if gestureRecognizer === panelPan {
            guard isPanelOpen else { return false }
            if bottomBar.panel == .search {
                let list = bottomBar.search.list
                if list.bounds.contains(panelPan.location(in: list)) {
                    return list.canPullToClose(velocity: panelPan.velocity(in: view))
                }
            }
            if bottomBar.panel == .history {
                let list = bottomBar.history.list
                if list.bounds.contains(panelPan.location(in: list)) {
                    return list.canRubberBandPanel(velocity: panelPan.velocity(in: view))
                }
            }
            if bottomBar.panel == .downloads {
                let velocity = panelPan.velocity(in: view)
                guard abs(velocity.y) > abs(velocity.x) else { return false }
                let list = bottomBar.downloads.list
                if list.bounds.contains(panelPan.location(in: list)), bottomBar.downloads.isScrollable {
                    if list.contentOffset.y > -list.adjustedContentInset.top+1, velocity.y > 0 { return false }
                    if downloadsSheet.detent == .expanded, velocity.y < 0 { return false }
                }
            }
            if bottomBar.panel == .appSettings {
                return bottomBar.appSettings.canPullToClose(at: panelPan.location(in: bottomBar.appSettings),
                                                          velocity: panelPan.velocity(in: view))
            }
            return true
        }
        if gestureRecognizer === tabSwipe {
            // Only upwards, more up than sideways.
            let velocity = tabSwipe.velocity(in: view)
            return canShowTabSwitcher && !voice.isRecording && velocity.y < 0 && abs(velocity.y) > abs(velocity.x)
        }
        if gestureRecognizer === barCollapseSwipe {
            // Only downwards, more down than sideways, on the bar at rest.
            let velocity = barCollapseSwipe.velocity(in: view)
            return !bottomBar.isCollapsed && !isPanelOpen && !isTabSwitcherOpen && !isSwipingToTabs && summarise == nil
                && velocity.y > 0 && velocity.y > abs(velocity.x)
        }
        if gestureRecognizer === summarisePinch { return (canSummarise || summarise?.canGrab == true) && !isPanelOpen }
        if gestureRecognizer === newPageHold {
            return VoiceInput.isSupported && !isPanelOpen && presentedViewController == nil && !isSwipingToTabs
        }
        if gestureRecognizer === panelBackSwipe {
            let delta = panelBackSwipe.translation(in: view), velocity = panelBackSwipe.velocity(in: view)
            let direction = abs(delta.x)+abs(delta.y) > 1 ? delta : velocity
            return canReturnFromPanel && direction.x > abs(direction.y)
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
        if gestureRecognizer === panelBackSwipe {
            return canReturnFromPanel && touch.location(in: view).x <= 16
        }
        // The strip's tap must not compete with controls in the expanded toolbar or its panels.
        if gestureRecognizer === collapsedBarTap { return bottomBar.isCollapsed && !isPanelOpen }
        // Editing and selection belong to the field; answer scrolling belongs to TextKit.
        if gestureRecognizer === panelPan, let touched = touch.view {
            if bottomBar.panel == .find, touched.isDescendant(of: bottomBar.find.field)
                || touched.isDescendant(of: bottomBar.find.answerView) { return false }
            if bottomBar.panel == .search, touched.isDescendant(of: bottomBar.search.field) { return false }
            if bottomBar.panel == .siteSettings,
               bottomBar.siteSettings.switches.contains(where: { touched.isDescendant(of: $0) }) { return false }
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

    @objc private func swipePanelBack(_ swipe: UIPanGestureRecognizer) {
        handlePanelEdgeSwipe(swipe.state)
    }

    func handlePanelEdgeSwipe(_ state: UIGestureRecognizer.State) {
        guard state == .began, canReturnFromPanel else { return }
        returnFromPanel()
    }

    var canReturnFromPanel: Bool {
        guard isPanelOpen else { return false }
        switch bottomBar.panel {
        case .history, .downloads, .siteSettings, .appSettings: return true
        default: return false
        }
    }

    /// X, the left-edge gesture and accessibility escape take the same route back.
    func returnFromPanel() {
        guard isPanelOpen else { return }
        switch bottomBar.panel {
        case .history: closeHistory()
        case .downloads: closeDownloads()
        case .siteSettings: closeSiteSettings()
        case .appSettings: closeAppSettings()
        default: closePanel()
        }
    }

    private func setUpBottomBar() {
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dimming.alpha = 0
        dimming.isUserInteractionEnabled = false
        dimming.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closePanelOnTap)))
        view.addSubview(dimming)
        bottomBarUnderfill.backgroundColor = bottomBar.backgroundColor
        bottomBarUnderfill.isUserInteractionEnabled = false
        view.addSubview(bottomBarUnderfill)
        view.addSubview(bottomBar)
        bottomBar.find.attachHosts(to: self)
        collapsedBarTap.delegate = self
        collapsedBarTap.cancelsTouchesInView = false
        bottomBar.addGestureRecognizer(collapsedBarTap)
        panelPan.delegate = self
        panelPan.maximumNumberOfTouches = 1
        bottomBar.addGestureRecognizer(panelPan)
        panelPan.require(toFail: panelBackSwipe)
        bottomBar.search.list.panGestureRecognizer.require(toFail: panelPan)
        bottomBar.history.list.panGestureRecognizer.require(toFail: panelPan)
        // The panel pan can reject horizontal movement before the edge pan begins;
        // the list must still wait for the edge gesture itself in that case.
        bottomBar.history.list.panGestureRecognizer.require(toFail: panelBackSwipe)
        bottomBar.history.swipe.pan.require(toFail: panelBackSwipe)
        panelPan.require(toFail: bottomBar.history.swipe.pan)
        bottomBar.downloads.list.panGestureRecognizer.require(toFail: panelPan)
        bottomBar.downloads.list.panGestureRecognizer.require(toFail: panelBackSwipe)
        bottomBar.downloads.onRowsChange = { [weak self] in self?.resizeDownloadsPanel() }
        tabSwipe.delegate = self
        bottomBar.addGestureRecognizer(tabSwipe)
        barCollapseSwipe.delegate = self
        barCollapseSwipe.maximumNumberOfTouches = 1
        bottomBar.addGestureRecognizer(barCollapseSwipe)
        bottomBar.tabsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if isTabSwitcherOpen { selectTab(tabIndex) } else { showTabSwitcher() }
        }, for: .primaryActionTriggered)
        bottomBar.tabsButton.count = tabs.count
        tabSwitcher.onSelect = { [weak self] index in self?.selectTab(index) }
        tabSwitcher.onClose = { [weak self] index in self?.closeTab(index) }
        tabSwitcher.onFocusChange = { [weak self] index in
            guard let self, let previews = tabPreviews, let slot = tabSwitcher.displayOrder.firstIndex(of: index) else { return }
            let order = tabSwitcher.displayOrder
            let nearby = (max(0, slot-3)...min(order.count-1, slot+2)).sorted { abs($0-slot) < abs($1-slot) }
            previews.prioritize(nearby.compactMap { tabs.indices.contains(order[$0]) ? tabs[order[$0]].id : nil })
        }
        tabSwitcher.onFlight = { [weak self] in
            guard self?.pendingCard != nil else { return }
            // Once the flight is with the render server.
            CATransaction.flush()
            self?.drawPendingCard()
        }
        bottomBar.newPageButton.addAction(UIAction { [weak self] _ in self?.openPanel() }, for: .primaryActionTriggered)
        newPageHold.minimumPressDuration = 0.3
        newPageHold.delegate = self
        bottomBar.newPageButton.addGestureRecognizer(newPageHold)
        bottomBar.search.allowsRemoteSuggestions = !isPrivateBrowsing
        bottomBar.search.source = addressSuggestions
        bottomBar.history.source = addressSuggestions
        addressSuggestions.icons.onLoad = { [weak self] in
            self?.bottomBar.search.refresh()
            self?.bottomBar.history.refreshIcons()
        }
        bottomBar.history.open = { [weak self] url in
            guard let self, isPanelOpen, bottomBar.panel == .history else { return }
            historyReturnPanel = nil
            openFromPanel(url)
        }
        bottomBar.search.tabIcon = { [weak self] url in
            self?.tabs.first { MobileSuggestionFavicons.origin($0.sessionTab.url) == MobileSuggestionFavicons.origin(url) && $0.favicon != nil }?.favicon
        }
        bottomBar.search.openTabs = { [weak self] in
            self?.tabs.map { AddressSuggestionTab(id: $0.id, title: $0.title, url: $0.sessionTab.url) } ?? []
        }
        bottomBar.search.onSwitchToTab = { [weak self] id in
            guard let self, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
            closePanel(); switchTab(to: index)
        }
        bottomBar.search.onOpen = { [weak self] url in self?.openFromPanel(url) }
        bottomBar.search.onClose = { [weak self] in self?.closePanel() }
        bottomBar.search.onSiteSearchChanged = { [weak self] in
            guard let self, isPanelOpen, bottomBar.panel == .search else { return }
            settlePanelOpen()
        }
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
            }, provider: MobileAISettings.shared.modelChoice)
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
        NotificationCenter.default.addObserver(self, selector: #selector(aiSettingsChanged),
                                               name: MobileAISettings.changed, object: nil)
        updateAIAvailability()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // Back and Forward leave More's panel open, to go on through the history; the rest close it.
        let address = bottomBar.menu.address, menu = bottomBar.menu
        address.addAction(UIAction { [weak self] _ in self?.editAddress() }, for: [.touchUpInside, .primaryActionTriggered])
        let actions: [(UIControl, @MainActor (BrowserViewController) -> Void)] = [
            (address.backButton, { $0.goBack() }),
            (address.forwardButton, { $0.goForward() }),
            // While editing the address, X clears it, or closes the dialog once it's empty.
            (address.reloadButton, {
                if !$0.bottomBar.menu.address.isEditingURL { $0.closePanel(); $0.reloadPage() }
                else if $0.bottomBar.search.siteSearch == nil && ($0.bottomBar.search.field.text ?? "").isEmpty { $0.closePanel() }
                else { $0.bottomBar.search.clearAddress() }
            }),
            (menu.shareTile, { $0.closePanel(); $0.share() }),
            (menu.summariseTile, { $0.summariseFromMenu() }),
            (menu.findTile, { $0.openFind() }),
            (menu.copyTile, { $0.copyLink() }),
            (menu.siteSettingsButton, { $0.openSiteSettings() }),
            (bottomBar.siteSettings.appSettingsRow, { $0.openAppSettings() }),
            (menu.downloadsButton, { $0.openDownloads() }),
            (bottomBar.tabMenu.historyButton, { $0.openHistory() }),
        ]
        for (control, action) in actions {
            control.addAction(UIAction { [weak self] _ in if let self { action(self) } }, for: .primaryActionTriggered)
        }
        for button in [bottomBar.history.closeButton, bottomBar.downloads.closeButton,
                       bottomBar.siteSettings.closeButton, bottomBar.appSettings.closeButton] {
            button.addAction(UIAction { [weak self] _ in self?.returnFromPanel() }, for: .primaryActionTriggered)
        }
        bottomBar.siteSettings.onAdBlockingChanged = { [weak self] enabled in self?.changeAdBlocking(enabled) }
        bottomBar.siteSettings.onCookieBannersChanged = { [weak self] enabled in self?.changeCookieBanners(enabled) }
        bottomBar.appSettings.onSyncChanged = { [weak self] enabled in
            self?.tabSync?.setEnabled(enabled)
            self?.updateAppSettings()
        }
        bottomBar.appSettings.onAutoplayChanged = { [weak self] enabled in
            self?.videoPlayback.setAllowsAutoplay(enabled)
        }
        if allowsPeek { setUpDownloads() }
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
        layoutBottomBarUnderfill()
        bottomBar.search.visibleHeight = min(SearchPanel.height, max(SearchPanel.fieldHeight,
            fullSearchHeight-keyboardHeight-BottomBar.searchTop))
        // Pages scroll clear of the open bar. Its collapsed strip leaves the inset alone, so the
        // page never resizes as the bar collapses; it just shows more of itself.
        let needed = BottomBar.height(collapsed: false, safeBottom: safeBottom)-safeBottom
        if additionalSafeAreaInsets.bottom != needed { additionalSafeAreaInsets.bottom = needed }
    }

    private func layoutBottomBarUnderfill() {
        // A one-point overlap avoids a raster seam; the existing bar and spring stay untouched.
        let frame = bottomBar.frame, top = frame.maxY-1
        bottomBarUnderfill.frame = CGRect(x: frame.minX, y: top, width: frame.width,
                                         height: max(0, view.bounds.maxY-top))
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

    /// Collapses the bar as soon as the swipe down is recognised, on the same spring as a scroll.
    @objc private func swipeBarDown(_ pan: UIPanGestureRecognizer) {
        guard pan.state == .began else { return }
        scrollTravel = 0
        setBottomBarCollapsed(true)
    }

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

    /// The fifth row starts at the keyboard edge. Short screens expose fewer rows,
    /// while the scroll view still lets every result move fully above the keyboard.
    private var fullSearchHeight: CGFloat {
        let desired = keyboardHeight > 0 ? keyboardHeight+BottomBar.searchTop+SearchPanel.height
            : (view.bounds.height*Self.panelHeightFraction).rounded()
        return min(view.bounds.height-view.safeAreaInsets.top-12, desired)
    }

    private func travel(of panel: BottomBar.Panel) -> CGFloat {
        let safeBottom = view.window?.safeAreaInsets.bottom ?? 0
        let open = BottomBar.height(collapsed: false, safeBottom: safeBottom)
        let height = switch panel {
        case .search: bottomBar.search.siteSearch == nil
            ? fullSearchHeight
            : BottomBar.findHeight(keyboard: keyboardHeight, safeBottom: safeBottom)
        case .menu: BottomBar.menuHeight(width: view.bounds.width, safeBottom: safeBottom)
        case .tabMenu: BottomBar.tabMenuHeight(safeBottom: safeBottom)
        case .find: BottomBar.findHeight(keyboard: keyboardHeight, safeBottom: safeBottom, answer: bottomBar.find.answerHeight)
        case .siteSettings: BottomBar.siteSettingsHeight(width: view.bounds.width, safeBottom: safeBottom)
        case .appSettings: min(view.bounds.height-view.safeAreaInsets.top-12, BottomBar.appSettingsHeight(width: view.bounds.width, safeBottom: safeBottom))
        case .downloads: downloadsSheet.height(in: downloadsHeights)
        case .history: BottomBar.historyHeight(screenHeight: view.bounds.height, safeTop: view.safeAreaInsets.top)
        }
        return max(1, height-open)
    }

    /// How far the page recedes behind the open panel: fully behind New Page's, and behind smaller
    /// panels as far as the same rate of growth takes it. Find leaves the page where it is, to show
    /// its matches.
    private var panelRecede: CGFloat {
        let safeBottom = view.window?.safeAreaInsets.bottom ?? 0
        let fullSearchTravel = fullSearchHeight
            - BottomBar.height(collapsed: false, safeBottom: safeBottom)
        return bottomBar.panel == .find ? 0 : panelTravel/max(1, fullSearchTravel)
    }

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
    func openPanel(_ requested: BottomBar.Panel = .search) {
        guard allowsPeek, !isPanelOpen, presentedViewController == nil else { return }
        let panel: BottomBar.Panel = requested == .menu && isTabSwitcherOpen ? .tabMenu : requested
        isPanelOpen = true
        bottomBar.restoreAddress()
        bottomBar.panel = panel
        if panel == .search { bottomBar.search.begin() }
        else if panel != .tabMenu { updateAddress() }
        dimming.isUserInteractionEnabled = true
        bottomBar.accessibilityViewIsModal = true
        bottomBar.showContents(of: panel)
        settlePanelOpen()
        if panel == .search {
            // The keyboard holds up the main thread for a while: the panel's spring goes to the
            // render server first, so it opens smoothly through that, and anything else in flight
            // on Core Animation, such as the tab switcher's page, carries on too.
            CATransaction.flush()
            bottomBar.search.focus()
        }
    }

    private func settlePanelOpen(velocity: CGFloat = 0, alongside: (() -> Void)? = nil, completion: (() -> Void)? = nil) {
        let spring = PeekPresentationController.openSpring
        panelMotion.settle(for: spring.duration)
        let animate = { alongside?(); self.setPanel(1); self.setNeedsStatusBarAppearanceUpdate() }
        guard !UIAccessibility.isReduceMotionEnabled else { animate(); panelMotion.stop(); completion?(); return }
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: velocity, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: animate) { finished in
            if finished { completion?() }
        }
    }

    /// Expand More into the New Page-sized editor, carrying its address on the same spring.
    func editAddress() {
        guard isPanelOpen, bottomBar.panel == .menu else { return }
        bottomBar.expandAddress(currentTab.addressURL)
        settlePanelOpen(alongside: { self.bottomBar.menu.address.alignEditingContents() }) { [weak self] in
            guard let self, isPanelOpen, bottomBar.panel == .search else { return }
            bottomBar.search.finishAddressTransition()
        }
        bottomBar.search.focusAddress()
    }

    /// Shrinks the panel back into the bar, carrying on at `velocity`, in points per second downwards.
    func closePanel(velocity: CGFloat = 0) {
        guard isPanelOpen else { return }
        bottomBar.appSettings.endEditing(true)
        historyReturnPanel = nil
        isPanelOpen = false
        dimming.isUserInteractionEnabled = false
        bottomBar.accessibilityViewIsModal = false
        guard !UIAccessibility.isReduceMotionEnabled else {
            setPanel(0); bottomBar.showContents(of: nil, animated: false); setNeedsStatusBarAppearanceUpdate()
            bottomBar.search.end(); bottomBar.find.end(); panelMotion.stop()
            applyPendingChanges(); return
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
        panelMotion.settle(for: max(close.duration, back.duration))
        UIView.animate(springDuration: back.duration, bounce: back.bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            PageRecede.apply(0, to: self.content)
        } completion: { _ in PageRecede.settle(self.content); self.applyPendingChanges() }
        // Keyboard resignation and blurred copies can block the main thread. Hand the
        // closing motion to the render server before either starts, as when opening.
        CATransaction.flush()
        panelMotion.event("close-committed")
        #if DEBUG
        onPanelCloseCommit?()
        #endif
        bottomBar.search.end()
        bottomBar.find.end()
        bottomBar.showContents(of: nil)
    }

    @objc private func closePanelOnTap() {
        if bottomBar.panel == .history { closeHistory() }
        else { closePanel() }
    }

    /// Grow directly from the current surface; no toolbar dismissal or modal presentation first.
    func openHistory() {
        guard allowsPeek, presentedViewController == nil, !isPanelOpen || bottomBar.panel != .history else { return }
        historyReturnPanel = isPanelOpen ? bottomBar.panel : nil
        bottomBar.history.setSelecting(false, animated: false)
        bottomBar.history.reload()
        if isPanelOpen { swapMenuPanel(to: .history) }
        else { openPanel(.history) }
    }

    func closeHistory() {
        guard isPanelOpen, bottomBar.panel == .history else { return }
        if let previous = historyReturnPanel {
            historyReturnPanel = nil
            swapMenuPanel(to: previous)
        } else { closePanel() }
    }

    /// More fades away with its usual blurred swap as the settings surface grows a little.
    func openSiteSettings() {
        guard isPanelOpen, bottomBar.panel == .menu else { return }
        updateAdBlockingSettings()
        swapMenuPanel(to: .siteSettings)
    }

    /// Settings' X returns to More, keeping the panel open and carrying its current animation on.
    func closeSiteSettings() {
        guard isPanelOpen, bottomBar.panel == .siteSettings else { return }
        swapMenuPanel(to: .menu)
    }

    func openAppSettings() {
        guard isPanelOpen, bottomBar.panel == .siteSettings else { return }
        updateAppSettings()
        swapMenuPanel(to: .appSettings)
    }

    func closeAppSettings() {
        guard isPanelOpen, bottomBar.panel == .appSettings else { return }
        swapMenuPanel(to: .siteSettings)
    }

    /// Downloads opens as Site settings does, showing what's under way and what's done.
    func openDownloads() {
        guard isPanelOpen, bottomBar.panel == .menu else { return }
        bottomBar.downloads.reload(MobileDownloads.shared.items)
        bottomBar.downloads.setSelecting(false, animated: false)
        downloadsSheet.reset()
        swapMenuPanel(to: .downloads)
    }

    func closeDownloads() {
        guard isPanelOpen, bottomBar.panel == .downloads else { return }
        swapMenuPanel(to: .menu)
    }

    /// Downloads came or went: the list follows, and the open panel grows or shrinks to fit it.
    func downloadsChanged() {
        bottomBar.downloads.reload(MobileDownloads.shared.items)
        bottomBar.menu.updateDownloadProgress(MobileDownloads.shared.items)
    }

    private func resizeDownloadsPanel() {
        guard isPanelOpen, bottomBar.panel == .downloads else { return }
        swapMenuPanel(to: .downloads)
    }

    var downloadsHeights: DownloadsSheetState.Heights {
        let safe = view.window?.safeAreaInsets.bottom ?? 0
        let maximum = max(1,view.bounds.height-view.safeAreaInsets.top-12)
        let compact = min(maximum,BottomBar.downloadsHeight(width: view.bounds.width,safeBottom: safe,
                                                          rows: bottomBar.downloads.rowCount))
        let expanded = min(maximum,max(compact+96,fullSearchHeight+48,view.bounds.height*0.8))
        return .init(compact: compact, expanded: expanded)
    }

    private func beginDownloadsDrag() {
        guard !downloadsSheet.isDragging else { return }
        let height = bottomBar.layer.presentation()?.bounds.height ?? bottomBar.bounds.height
        downloadsSheet.begin(at: height, in: downloadsHeights)
        // Catch the displayed sheet without interrupting its child symbol transitions.
        for layer in [bottomBar.layer,content.layer,dimming.layer] { layer.removeAllAnimations() }
    }

    private func finishDownloadsDrag(velocity: CGFloat, cancelled: Bool) {
        let current = downloadsSheet.height(in: downloadsHeights)
        downloadsSheet.finish(velocity: velocity,cancelled: cancelled,in: downloadsHeights)
        let distance = downloadsSheet.height(in: downloadsHeights)-current
        let speed = abs(distance) > 1 ? min(4,max(0,-velocity/distance)) : 0
        let change = { self.setPanel(1) }
        guard !UIAccessibility.isReduceMotionEnabled else { change(); panelMotion.stop(); return }
        panelMotion.settle(for: 0.3)
        UIView.animate(springDuration: 0.3,bounce: 0,initialSpringVelocity: speed,delay: 0,
                       options: [.beginFromCurrentState,.allowUserInteraction],animations: change)
    }

    private func swapMenuPanel(to panel: BottomBar.Panel) {
        if panel != .appSettings { bottomBar.appSettings.endEditing(true) }
        bottomBar.panel = panel
        bottomBar.showContents(of: panel)
        let change = { self.setPanel(1); self.setNeedsStatusBarAppearanceUpdate() }
        guard !UIAccessibility.isReduceMotionEnabled else { change(); panelMotion.stop(); return }
        let spring = PeekPresentationController.closeSpring
        panelMotion.settle(for: spring.duration)
        UIView.animate(springDuration: spring.duration, bounce: spring.bounce, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: change)
    }

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
        } completion: { _ in PageRecede.settle(self.content) }
    }

    /// Find and compact site search follow the keyboard up and down.
    @objc private func keyboardWillChange(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let screen = view.window?.screen else { return }
        let frame = view.convert(end, from: screen.coordinateSpace)
        keyboardHeight = frame.minY < view.bounds.maxY ? view.bounds.maxY-frame.minY : 0
        if isPanelOpen, bottomBar.panel == .appSettings {
            bottomBar.appSettings.keyboardInset = max(0, keyboardHeight-(view.window?.safeAreaInsets.bottom ?? 0))
            return
        }
        guard isPanelOpen, bottomBar.panel == .find || bottomBar.panel == .search else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16),
                                                                  .beginFromCurrentState, .allowUserInteraction]) {
            if self.bottomBar.panel == .find {
                self.bottomBar.find.maximumAnswerHeight = max(80, min(300, self.view.bounds.height-self.keyboardHeight-160))
                self.layoutBottomBar()
                self.bottomBar.layoutIfNeeded()
            } else {
                self.setPanel(self.panelExpansion)
            }
        }
    }

    /// Finds in the page, then brings the current match out from under Find's panel and the
    /// keyboard, into the middle of what shows of the page.
    private func find(_ query: String, direction: PageFind.Direction) async -> PageFind.Matches {
        let page = webView
        // What shows of the page above Find's panel, so matches under it don't count as seen.
        let scale: CGFloat = max(page.scrollView.zoomScale, 0.01)
        let uncoveredTop: CGFloat = max(0, view.convert(CGPoint(x: 0, y: view.safeAreaInsets.top), to: page).y)
        let uncoveredBottom: CGFloat = isPanelOpen ? view.convert(CGPoint(x: 0, y: bottomBar.frame.minY), to: page).y : page.bounds.height
        let shown: ClosedRange<Double>? = uncoveredBottom > uncoveredTop ? Double(uncoveredTop/scale)...Double(uncoveredBottom/scale) : nil
        let matches = await PageFind.find(query, direction: direction, shown: shown, in: page)
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

        let page = Self.makeWebView(dataStore: websiteDataStore, videoPlayback: videoPlayback)
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
            openInNewTab(page, topColor: color, initialURL: url)
            arrival.removeFromSuperview()
            view.isUserInteractionEnabled = true
            bottomBar.showContents(of: nil)
            applyPendingChanges()
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
            if bottomBar.panel == .downloads {
                finishDownloadsDrag(velocity: velocity,cancelled: pan.state != .ended)
            } else if pan.state == .ended { finishPanelDrag(at: distance, velocity: velocity) }
            else { settlePanelOpen() }
        default: break
        }
    }

    func dragPanel(to distance: CGFloat) {
        guard isPanelOpen else { return }
        let began = CACurrentMediaTime()
        panelMotion.begin(bottomBar.panel, screen: view.window?.windowScene?.screen)
        defer { panelMotion.tracked(since: began) }
        if bottomBar.panel == .downloads {
            beginDownloadsDrag()
            downloadsSheet.drag(by: distance,in: downloadsHeights)
            setPanel(1)
            return
        }
        let travel = panelTravel
        let stretch = 40*(1-1/(1+abs(distance)/160))
        if bottomBar.panel == .history {
            setPanel(1+(distance < 0 ? stretch : -stretch)/travel)
        } else {
            setPanel(distance >= 0 ? max(0, 1-distance/travel) : 1+stretch/travel)
        }
    }

    func finishPanelDrag(at distance: CGFloat, velocity: CGFloat = 0) {
        guard isPanelOpen else { return }
        if bottomBar.panel == .downloads {
            if !downloadsSheet.isDragging { dragPanel(to: distance) }
            finishDownloadsDrag(velocity: velocity,cancelled: false)
            return
        }
        if bottomBar.panel == .history { settlePanelOpen(); return }
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
        returnFromPanel()
        return true
    }

    // MARK: Summarise

    private var canSummarise: Bool {
        MobileAISettings.shared.enabled && allowsPeek && summarise == nil && !isTabSwitcherOpen && !isSwipingToTabs && presentedViewController == nil
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
        let attachingHost = summaryHost.parent == nil
        if attachingHost { addChild(summaryHost) }
        let summarise = SummariseView(page: { [content] in
            content.snapshotView(afterScreenUpdates: false) ?? UIView(frame: CGRect(origin: .zero, size: size))
        }, title: title, size: size, summaryHost: summaryHost)
        summarise.makeSummary = { try await PageSummary.make(of: PageAssistant.snapshot(of: page), provider: MobileAISettings.shared.modelChoice) }
        // Summarised before and unchanged since, the page flies straight to its summary.
        let tab = currentTab, url = page.url, item = page.backForwardList.currentItem
        summarise.memorised = tab.summary(of: page)
        summarise.onSummary = { [weak tab, weak page] summary in
            guard let page else { return }
            tab?.remember(summary, of: page, url: url, item: item)
        }
        summarise.answerFollowUp = { question, summary, history in
            try await PageSummary.answer(question, after: summary, history: history, of: PageAssistant.snapshot(of: page), provider: MobileAISettings.shared.modelChoice)
        }
        let log = SummariseLog(path: path == .pinch ? "pinch" : "menu", page: isPrivateBrowsing ? "Private" : page.url?.host() ?? "no page", enabled: !isPrivateBrowsing)
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
            layoutBottomBarUnderfill()
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
            // Reparent directly within the window before removing the scene. Even a retained
            // host does expensive SwiftUI environment/bridge updates if its window becomes nil.
            summaryHost.view.isHidden = true
            view.insertSubview(summaryHost.view, belowSubview: content)
            summarise.removeFromSuperview()
            self.summarise = nil
            bottomBar.transform = .identity
            layoutBottomBarUnderfill()
            bottomBar.isUserInteractionEnabled = true
            setNeedsStatusBarAppearanceUpdate()
            applyPendingChanges()
        }
        view.insertSubview(summarise, belowSubview: bottomBarUnderfill)
        if attachingHost { summaryHost.didMove(toParent: self) }
        bottomBar.isUserInteractionEnabled = false
        self.summarise = summarise
        if path == .pinch { summarise.beginPinch(at: point) } else { summarise.startFromMenu() }
    }

    /// A Home Screen action waits for the same completions as external links.
    func prepareForQuickAction(_ action: HomeScreenAction) -> Bool {
        guard allowsPeek, isViewLoaded, (view.window != nil || presentedViewController != nil), view.isUserInteractionEnabled, !isSwipingToTabs else { return false }
        opensSearchOnFirstAppearance = false
        if let presented = presentedViewController {
            guard !presented.isBeingPresented else { return false }
            if !presented.isBeingDismissed {
                dismiss(animated: true) { [weak self] in self?.applyPendingChanges() }
            }
            return false
        }
        if let summarise { summarise.finish(); return false }
        if isPanelOpen, action == .history, bottomBar.panel != .search, bottomBar.panel != .find { return true }
        if isPanelOpen { closePanel(); return false }
        if isTabSwitcherOpen, action != .history { selectTab(tabIndex); return false }
        return isTabSwitcherOpen || tabSwitcher.isHidden
    }

    func endPrivateSession() {
        guard isPrivateBrowsing else { return }
        summarise?.finish()
        panelMotion.stop()
        bottomBar.search.end()
        bottomBar.find.end()
        voice.cancel()
        adBlockingTask?.cancel()
        for tab in tabs {
            for page in [tab.webView] + tab.previousPages + tab.forwardPages { page.stopLoading() }
        }
    }

    func suppressLaunchSearch() { opensSearchOnFirstAppearance = false }

    func openNewBlankTab() {
        let page = Self.makeWebView(dataStore: websiteDataStore, videoPlayback: videoPlayback)
        openInNewTab(page, topColor: nil, initialURL: nil)
        openPanel()
    }

    // MARK: Tabs

    /// Opens a page chosen in New Page's panel in a new tab after this one.
    private func openInNewTab(_ page: WKWebView, topColor: UIColor?, initialURL: URL?) {
        if !tabSwitcher.isHidden { closeTabSwitcherAtOnce() } else { currentTab.snapshot = snapshotPage() }
        tabPreviews?.save(currentTab)
        let previous = webView
        let tab = BrowserTab(webView: page, initialURL: initialURL)
        track(tab)
        tabs.insert(tab, at: tabIndex+1)
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

    /// Moves the page into the Arc-style horizontal deck, or turns its growing card around.
    func showTabSwitcher() {
        guard canShowTabSwitcher else { return }
        prepareTabSwitcher()
        tabSwitcher.present()
    }

    private func prepareTabSwitcher() {
        if tabSwitcher.isHidden {
            setBottomBarCollapsed(false)
            // Drawing the page for its card holds up the main thread for a couple of frames: the
            // page shrinks as a replica, quick to take, and its card's picture is drawn once it's
            // on its way on Core Animation.
            let replica = content.snapshotView(afterScreenUpdates: false)
            pendingCard = currentTab
            tabSwitcher.load(tabs, current: tabIndex)
            tabSwitcher.prepare(page: replica)
        }
        isTabSwitcherOpen = true
        bottomBar.tabsButton.setShowsSwitcher(true, animated: true)
        UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
    }

    /// Grows a tab's card back into the page, making it the current tab.
    func selectTab(_ index: Int) {
        guard isTabSwitcherOpen, !isSwipingToTabs, tabs.indices.contains(index) else { return }
        isTabSwitcherOpen = false
        tabSwitcher.dismiss(to: index) { [weak self] in
            self?.updateTabsPreview(); self?.applyPendingChanges()
        }
        // The selected card is already flying on Core Animation before WebKit/tint tracking,
        // thumbnail requests and session/sync work for its live page start underneath it.
        if index != tabIndex { switchTab(to: index) }
        bottomBar.tabsButton.setShowsSwitcher(false, animated: true)
        UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
    }

    /// The tab whose card's picture is still to be drawn, as its page shrinks into it.
    private var pendingCard: BrowserTab?

    /// Draws the picture for the card of the page that just went into the switcher, as the page and
    /// its strip, without the switcher now over them.
    private func drawPendingCard() {
        guard let tab = pendingCard else { return }
        pendingCard = nil
        guard let index = tabs.firstIndex(where: { $0 === tab }), tab.webView.window != nil else { return }
        let bounds = content.bounds, strip = topStrip.backgroundColor ?? .systemBackground, frame = pageFrame
        let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
            strip.setFill()
            context.fill(CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight))
            tab.webView.drawHierarchy(in: frame, afterScreenUpdates: false)
        }
        tab.snapshot = image
        tabPreviews?.save(tab)
        tabSwitcher.setPicture(image, at: index)
    }

    private func closeTabSwitcherAtOnce() {
        drawPendingCard()
        tabSwitcher.hide()
        isTabSwitcherOpen = false
        bottomBar.tabsButton.setShowsSwitcher(false, animated: true)
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Puts a tab's page in place, under the switcher.
    private func switchTab(to index: Int) {
        drawPendingCard()
        let previous = webView
        tabIndex = index
        webView.transform = .identity
        install(webView)
        if previous !== webView { previous.removeFromSuperview() }
        pageChanged()
    }

    /// A closed tab, kept in memory only, so shaking can bring it back while the app runs.
    private struct ClosedTab {
        let saved: MobileBrowserSession.Tab
        let index: Int
        let snapshot: UIImage?
        let favicon: UIImage?
        /// The tab after it in the switcher's recent order, to go back in before.
        let before: UUID?
    }
    private var closedTabs: [ClosedTab] = []

    /// Closes a tab from its card; the last one stays.
    private func closeTab(_ index: Int) {
        guard isTabSwitcherOpen, tabs.count > 1, tabs.indices.contains(index) else { return }
        let closesSelected = index == tabIndex
        let order = tabSwitcher.displayOrder
        let after = order.firstIndex(of: index).flatMap { order.indices.contains($0+1) ? tabs[order[$0+1]].id : nil }
        let closing = tabs.remove(at: index)
        closedTabs.append(ClosedTab(saved: closing.sessionTab, index: index, snapshot: closing.snapshot,
                                    favicon: closing.favicon, before: after))
        if closedTabs.count > 50 { closedTabs.removeFirst() }
        if pendingCard === closing { pendingCard = nil }
        if index < tabIndex {
            tabIndex -= 1
        } else if closesSelected {
            tabIndex = min(index, tabs.count-1)
        }
        // Commit the deck's reflow before WebKit/session work can occupy the main thread.
        tabSwitcher.remove(at: index, current: tabIndex)
        drawPendingCard()
        if closesSelected {
            install(webView)
            closing.webView.removeFromSuperview()
            pageChanged()
        }
        bottomBar.tabsButton.count = tabs.count
        saveSession()
    }

    /// Shaking brings back the last tab closed, and shaking again the one before it. In the
    /// switcher its card drops back into the deck; on a page, it opens. False if there was none
    /// to bring back, or the browser was busy.
    @discardableResult func reopenClosedTab() -> Bool {
        guard allowsPeek, let closed = closedTabs.last, !isSwipingToTabs, summarise == nil, !isPanelOpen,
              presentedViewController == nil else { return false }
        let inSwitcher = !tabSwitcher.isHidden
        if inSwitcher && (!isTabSwitcherOpen || tabSwitcher.isAnimatingOrTracking) { return false }
        closedTabs.removeLast()
        let tab = BrowserTab(webView: Self.makeWebView(dataStore: websiteDataStore, videoPlayback: videoPlayback),
                             restoring: closed.saved)
        tab.snapshot = closed.snapshot
        tab.restoreFavicon(closed.favicon)
        track(tab)
        if !inSwitcher {
            currentTab.snapshot = snapshotPage()
            tabPreviews?.save(currentTab)
        }
        let index = min(closed.index, tabs.count)
        tabs.insert(tab, at: index)
        if index <= tabIndex { tabIndex += 1 }
        bottomBar.tabsButton.count = tabs.count
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if inSwitcher {
            tabSwitcher.restore(tabs, current: tabIndex, restored: index, before: closed.before)
            saveSession()
        } else {
            switchTab(to: index)
        }
        return true
    }

    @objc private func swipeToTabs(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view), location = pan.location(in: view)
        let start = CGPoint(x: location.x-translation.x, y: location.y-translation.y)
        switch pan.state {
        case .began:
            beginTabSwipe()
            updateTabSwipe(translation, from: start)
        case .changed:
            updateTabSwipe(translation, from: start)
        case .ended, .cancelled, .failed:
            updateTabSwipe(translation, from: start)
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

    func updateTabSwipe(_ translation: CGPoint, from start: CGPoint? = nil) {
        guard isSwipingToTabs else { return }
        tabSwitcher.update(swipe: translation, from: start.map { view.convert($0, to: tabSwitcher) })
    }

    func endTabSwipe(velocity: CGPoint, cancelled: Bool = false) {
        guard isSwipingToTabs else { return }
        isSwipingToTabs = false
        let progress = tabSwitcher.swipeProgress
        let commit = !cancelled && (velocity.y < -400 || (progress > 0.25 && velocity.y < 400))
        if !commit {
            isTabSwitcherOpen = false
            bottomBar.tabsButton.setShowsSwitcher(false, animated: true)
            UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
        }
        tabSwitcher.finishSwipe(commit: commit) { [weak self] in self?.applyPendingChanges() }
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

    private var shareableURL: URL? { currentTab.addressURL.flatMap { Self.canPeek($0) ? $0 : nil } }
    func updateNavigationStatus() {
        navigationStatus.show(address: currentTab.addressURL, committed: currentTab.hasCommittedDocument,
                              error: currentTab.navigationError)
    }
    func reloadPage() {
        currentTab.reload()
        updateNavigationStatus()
    }

    private func goBack() {
        if webView.canGoBack { webView.goBack() } else { returnToPreviousPage() }
    }
    private func goForward() {
        if webView.canGoForward { webView.goForward() } else { returnToNextPage() }
    }

    private func copyLink() {
        guard let url = shareableURL else { return }
        UIPasteboard.general.url = url
        bottomBar.showCopySuccess()
        closePanel()
    }

    private func share() {
        guard let url = shareableURL else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.completionWithItemsHandler = { [weak self] _, _, _, _ in
            DispatchQueue.main.async { self?.applyPendingChanges() }
        }
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
        currentTab.loadIfNeeded()
        updateAppSettings()
        tabSync?.start(tabs: sharedTabsSnapshot, learnedSearches: addressSuggestions.learner.searches, browsingHistory: addressSuggestions.history)
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
        bottomBar.setListening(false)
    }

    // With no tab UI yet, links requesting a new window navigate this page instead.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView.url?.scheme == MobileTabHistory.scheme { return }
        tabs.first { $0.webView === webView }?.didCommit(navigation)
        addressSuggestions.committed(webView)
        if webView === self.webView { updateNavigationStatus(); updateAddress() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.scheme == MobileTabHistory.scheme {
            MobileTabHistory.finishInternalDocument(in: webView)
            return
        }
        tabs.first { $0.webView === webView }?.didFinish()
        finishAdBlockingReload(on: webView, navigation: navigation)
        PagePaintWatcher.shared.didFinish(webView)
        addressSuggestions.changed(webView)
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
