import UIKit
import WebKit

/// A tab: its page, the pages a Peek replaced in it (held for Back), how it last looked, and its icon.
@MainActor final class BrowserTab {
    let id: UUID
    let isPrivateBrowsing: Bool
    var webView: WKWebView {
        didSet {
            pendingURL = nil; restoreNavigation = nil; activeNavigation = nil
            cancellationRetries = 0
            navigationError = nil; hasCommittedDocument = webView.url != nil
            rememberedURL = nil
            rememberedTitle = nil
            pendingHistory = nil; pendingInteractionState = nil; isRestoringHistory = false
            snapshot = nil
            favicon = nil
            summary = nil; fingerprint = nil
            observePage()
        }
    }
    /// The page's last summary, kept while it's still the same page: the same web view, address
    /// and history entry, with nothing committed since. Only in memory.
    private var summary: (url: URL?, item: WKBackForwardListItem?, summary: PageSummary)?
    func summary(of page: WKWebView) -> PageSummary? {
        guard page === webView, let summary, summary.url == page.url,
              summary.item === page.backForwardList.currentItem else { return nil }
        return summary.summary
    }
    /// Kept if the page is still the one summarised, from `url` and `item` as the request began.
    func remember(_ summary: PageSummary, of page: WKWebView, url: URL?, item: WKBackForwardListItem?) {
        guard page === webView, page.url == url, page.backForwardList.currentItem === item else { return }
        self.summary = (url, item, summary)
    }
    /// The page's text, fingerprinted as it was sent to the model or once it loaded
    /// (`SummaryCache.key`), for finding its summary on disk after a relaunch. Kept as long as the
    /// summary in memory is.
    private var fingerprint: (url: URL?, item: WKBackForwardListItem?, key: String)?
    func fingerprint(of page: WKWebView) -> String? {
        guard page === webView, let fingerprint, fingerprint.url == page.url,
              fingerprint.item === page.backForwardList.currentItem else { return nil }
        return fingerprint.key
    }
    func fingerprint(_ key: String, of page: WKWebView, url: URL?, item: WKBackForwardListItem?) {
        guard page === webView, page.url == url, page.backForwardList.currentItem === item else { return }
        fingerprint = (url, item, key)
    }
    /// Restored tabs keep their address/title while their page waits to be selected and loaded.
    private var rememberedURL: URL?
    private var rememberedTitle: String?
    private var pendingURL: URL?
    private var pendingHistory: TabNavigationHistory?
    private var pendingInteractionState: Data?
    private var isRestoringHistory = false
    private var restoreNavigation: WKNavigation?
    private var activeNavigation: WKNavigation?
    private var cancellationRetries = 0
    #if DEBUG
    var restorationHasStarted: Bool {
        restoreNavigation != nil && activeNavigation === restoreNavigation
    }
    #endif
    private(set) var hasCommittedDocument = false
    private(set) var navigationError: Error?
    var addressURL: URL? {
        if isRestoringHistory { return rememberedURL }
        if let url = webView.url, let entry = MobileTabHistory.entry(for: url) { return URL(string: entry.url) }
        if let url = webView.url, MobileBrowserSession.canRestore(url) { return url }
        return rememberedURL
    }
    private var pageObservations: [NSKeyValueObservation] = []
    private var knownHistoryItems: [WKBackForwardListItem] = []
    var onPageChange: (() -> Void)?
    var isSyncPlaceholder = false
    func rememberSharedTitle(_ title: String?) { rememberedTitle = title }
    var previousPages: [WKWebView] = []
    var forwardPages: [WKWebView] = []
    func discardForwardPages() {
        for page in forwardPages { page.stopLoading(); page.navigationDelegate = nil; page.uiDelegate = nil }
        forwardPages.removeAll()
    }
    /// The page, strip included, as it was when last left, for its card in the tab switcher.
    var snapshot: UIImage? { didSet { onSnapshotChange?() } }
    var onSnapshotChange: (() -> Void)?
    /// The page's icon, or nil for the blank square.
    private(set) var favicon: UIImage? { didSet { onFaviconChange?() } }
    var onFaviconChange: (() -> Void)?
    func restoreFavicon(_ image: UIImage?) { if favicon == nil { favicon = image } }
    /// The page the icon was looked up for, so it's looked up once a page.
    private var faviconPage: URL?
    private static var icons: [URL: UIImage] = [:]

    init(webView: WKWebView, restoring tab: MobileBrowserSession.Tab? = nil, initialURL: URL? = nil,
         isPrivateBrowsing: Bool = false) {
        precondition(!isPrivateBrowsing || !webView.configuration.websiteDataStore.isPersistent)
        self.isPrivateBrowsing = isPrivateBrowsing
        self.webView = webView
        hasCommittedDocument = webView.url != nil
        id = tab?.id ?? UUID()
        isSyncPlaceholder = tab?.isSyncPlaceholder == true
        rememberedURL = (tab?.url ?? initialURL).flatMap { MobileBrowserSession.canRestore($0) ? $0 : nil }
        rememberedTitle = tab?.title
        pendingURL = tab?.url
        pendingHistory = tab?.navigationHistory?.validated(for: tab?.url?.absoluteString)
        pendingInteractionState = tab?.interactionState
        observePage()
    }

    var sessionTab: MobileBrowserSession.Tab {
        let history = navigationHistory
        // URL notifications can precede a commit. Save the committed history and its cursor
        // together, rather than briefly replacing them with a provisional URL and no history.
        let url = history?.current.flatMap { URL(string: $0.url) } ?? rememberedURL
        return MobileBrowserSession.Tab(id: id, url: url, title: rememberedTitle, isSyncPlaceholder: isSyncPlaceholder ? true : nil,
                                        navigationHistory: history, interactionState: interactionState)
    }

    var navigationHistory: TabNavigationHistory? {
        if isRestoringHistory || pendingURL != nil && !hasCommittedDocument { return pendingHistory }
        guard let current = MobileTabHistory.snapshot(of: webView) else { return pendingHistory }
        return TabNavigationHistory.combining(back: previousPages.compactMap { MobileTabHistory.snapshot(of: $0) },
            current: current, forward: forwardPages.reversed().compactMap { MobileTabHistory.snapshot(of: $0) })
    }

    private var interactionState: Data? {
        if isRestoringHistory || pendingURL != nil && !hasCommittedDocument { return pendingInteractionState }
        let list = webView.backForwardList
        let items = list.backList + [list.currentItem].compactMap { $0 } + list.forwardList
        // A placeholder is tied to this web view's private origin. Recreate it from portable
        // history after relaunch rather than archiving that ephemeral capability.
        guard previousPages.isEmpty, forwardPages.isEmpty, !items.isEmpty,
              items.allSatisfy({ MobileBrowserSession.canRestore($0.url) }),
              let data = webView.interactionState as? Data, data.count <= MobileTabHistory.maximumStateBytes else { return nil }
        return data
    }

    func loadIfNeeded() {
        guard let url = pendingURL, !isRestoringHistory, restoreNavigation == nil, !webView.isLoading, navigationError == nil else { return }
        if let state = pendingInteractionState {
            isRestoringHistory = true
            webView.interactionState = state
            if webView.backForwardList.currentItem != nil { return }
            isRestoringHistory = false; pendingInteractionState = nil
        }
        if let history = pendingHistory, history.entries.count > 1 {
            isRestoringHistory = true
            restoreNavigation = MobileTabHistory.restore(history, in: webView)
        } else { restoreNavigation = webView.load(URLRequest(url: url)) }
    }
    func didStart(_ navigation: WKNavigation) {
        activeNavigation = navigation
        navigationError = nil
        if !isRestoringHistory, let restoring = restoreNavigation, restoring !== navigation {
            // A new user navigation supersedes the restored request, rather than reopening it later.
            restoreNavigation = nil; pendingURL = nil
        }
    }
    func didCommit(_ navigation: WKNavigation) {
        // A new document, or the same one reloaded, may say something else.
        summary = nil; fingerprint = nil
        if let active = activeNavigation, active !== navigation { return }
        if !isRestoringHistory, let restoring = restoreNavigation, restoring !== navigation { return }
        hasCommittedDocument = true
        cancellationRetries = 0
        navigationError = nil
        isRestoringHistory = false; pendingHistory = nil; pendingInteractionState = nil
        pendingURL = nil; restoreNavigation = nil
        rememberAddress()
    }
    func didFinish() { pageDidChange() }
    /// A cancelled startup request gets one retry; ordinary failures keep the destination for Retry.
    func didFail(_ navigation: WKNavigation?, error: Error) -> Bool {
        if !isRestoringHistory, let restoring = restoreNavigation, let navigation, restoring !== navigation { return false }
        if let active = activeNavigation, let navigation, active !== navigation { return false }
        let restoring = pendingURL != nil && !hasCommittedDocument
        isRestoringHistory = false
        restoreNavigation = nil; activeNavigation = nil
        let cancelled = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
        if cancelled, restoring, cancellationRetries < 1 {
            cancellationRetries += 1
            return true
        }
        if !cancelled || restoring { navigationError = error }
        return false
    }
    /// Ignoring the cache, as Safari's Reload Page From Origin does, revalidates the page and everything it loads.
    func reload(ignoringCache: Bool = false) {
        let failed = navigationError != nil
        navigationError = nil; cancellationRetries = 0
        if hasCommittedDocument && !failed, webView.url != nil {
            if ignoringCache { webView.reloadFromOrigin() } else { webView.reload() }
        } else if let url = addressURL {
            restoreNavigation = nil; activeNavigation = nil
            pendingURL = url
            webView.stopLoading()
            loadIfNeeded()
        }
    }
    func processTerminated() {
        pendingHistory = navigationHistory
        pendingInteractionState = interactionState
        pendingURL = addressURL
        restoreNavigation = nil; activeNavigation = nil
        hasCommittedDocument = false; navigationError = nil
        cancellationRetries = 0
    }
    func retryUncommittedPage() {
        guard !hasCommittedDocument, !webView.isLoading, restoreNavigation == nil,
              let url = pendingURL ?? addressURL else { return }
        pendingURL = url
        navigationError = nil
        cancellationRetries = 0
        loadIfNeeded()
    }

    private func observePage() {
        knownHistoryItems = historyItems
        MobileTabHistory.observe(webView) { [weak self] in self?.pageDidChange() }
        rememberAddress()
        if let title = webView.title, !title.isEmpty { rememberedTitle = title }
        pageObservations = [
            webView.observe(\.url) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            webView.observe(\.title) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            webView.observe(\.canGoBack) { [weak self] _, _ in MainActor.assumeIsolated { self?.onPageChange?() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in MainActor.assumeIsolated { self?.onPageChange?() } },
            webView.observe(\.isLoading, options: [.old, .new]) { [weak self] _, change in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if change.oldValue == true && change.newValue == false { self.loadingStopped() }
                    self.onPageChange?()
                }
            },
        ]
        onPageChange?()
    }

    /// An early stop can leave WebKit idle without a navigation failure callback. Let
    /// the usual commit/failure callbacks settle before recovering the same request.
    private func loadingStopped() {
        // The internal bootstrap intentionally stops before its replacement page
        // starts (which can wait for content rules). Re-seeding here duplicates it.
        guard !isRestoringHistory, let navigation = restoreNavigation, pendingURL != nil, !hasCommittedDocument else { return }
        let page = webView
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak page] in
            guard let self, let page, self.webView === page,
                  self.restoreNavigation === navigation, self.pendingURL != nil,
                  !self.isRestoringHistory, !self.hasCommittedDocument, !page.isLoading else { return }
            let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
            if self.didFail(navigation, error: cancelled) { self.loadIfNeeded() }
            self.onPageChange?()
        }
    }

    /// WebKit can deliver title and address notifications in either order. Read the pair
    /// together so a later address notification cannot clear the already updated title.
    private func pageDidChange() {
        if let current = webView.backForwardList.currentItem,
           !knownHistoryItems.contains(where: { $0 === current }) {
            // Reload and Back/Forward retain an existing item. A new document or
            // pushState creates an item and abandons any later adopted Peek pages.
            discardForwardPages()
        }
        knownHistoryItems = historyItems
        rememberAddress()
        if let title = webView.title, !title.isEmpty { rememberedTitle = title }
        onPageChange?()
    }

    private var historyItems: [WKBackForwardListItem] {
        let list = webView.backForwardList
        return list.backList + [list.currentItem].compactMap { $0 } + list.forwardList
    }

    private func rememberAddress() {
        guard !isRestoringHistory else { return }
        guard let url = webView.url else { return }
        if let entry = MobileTabHistory.entry(for: url) {
            rememberedURL = URL(string: entry.url); rememberedTitle = entry.title
            return
        }
        if url.absoluteString == "about:blank" {
            if pendingURL != nil && !hasCommittedDocument { return }
            rememberedURL = nil
            rememberedTitle = nil
            snapshot = nil
            favicon = nil
            return
        }
        guard MobileBrowserSession.canRestore(url) else { return }
        isSyncPlaceholder = false
        if rememberedURL != url {
            rememberedTitle = nil
            snapshot = nil
            favicon = nil
            faviconPage = nil
        }
        rememberedURL = url
    }

    var title: String {
        if let title = rememberedTitle, !title.isEmpty { return title }
        if let title = webView.title, !title.isEmpty { return title }
        return rememberedURL?.host() ?? "New Page"
    }

    /// The icons the page declares, as bitmaps can be drawn here, in the page's own order.
    private static let iconScript = """
    (() => {
      const links = Array.from(document.querySelectorAll('link[rel][href]'));
      const rels = link => link.rel.toLowerCase().split(/\\s+/);
      const scheme = link => link.media.match(/\\(\\s*prefers-color-scheme\\s*:\\s*(dark|light)\\s*\\)/i);
      const candidates = dark => {
        const usable = link => {
          if (/svg/i.test(link.type) || /\\.svg([?#]|$)/i.test(link.href)) return false;
          const appearance = scheme(link);
          return appearance ? (appearance[1].toLowerCase() === 'dark') === dark
            : (!link.media || matchMedia(link.media).matches);
        };
        const icons = links.filter(link => rels(link).includes('icon') && usable(link));
        const touch = links.filter(link => rels(link).some(rel => rel.startsWith('apple-touch-icon')) && usable(link));
        return icons.concat(touch).sort((a, b) => Number(!!scheme(b))-Number(!!scheme(a))).map(link => link.href);
      };
      return { light: candidates(false), dark: candidates(true) };
    })()
    """

    struct IconCandidates: Equatable {
        let light: [URL]
        let dark: [URL]
    }

    /// Looks up the page's icon: the first it declares that loads, else the site's favicon.ico.
    func loadFavicon() {
        let web = webView
        guard let page = web.url, page != faviconPage else { return }
        faviconPage = page
        guard ["http", "https"].contains(page.scheme?.lowercased() ?? "") else { favicon = nil; return }
        Task { [weak self] in
            let image = await Self.favicon(for: web)
            guard let self, webView === web, faviconPage == page else { return }
            favicon = image
        }
    }

    /// A quick first-party lookup, independent of the page's loading progress.
    static func favicon(for page: URL) async -> UIImage? {
        guard MobileBrowserSession.canRestore(page),
              let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL else { return nil }
        return await favicon(at: IconCandidates(
            light: [FaviconDiscovery.lightIcon(for: page), fallback].compactMap { $0 },
            dark: [FaviconDiscovery.darkIcon(for: page), fallback].compactMap { $0 }))
    }

    /// Used by the temporary preview page too, without changing a real tab's address/history.
    static func favicon(for web: WKWebView) async -> UIImage? {
        await favicon(at: faviconCandidates(for: web))
    }

    static func faviconCandidates(for web: WKWebView) async -> IconCandidates {
        guard web.configuration.websiteDataStore.isPersistent,
              let page = web.url, MobileBrowserSession.canRestore(page) else { return IconCandidates(light: [], dark: []) }
        let result = (try? await web.evaluateJavaScript(iconScript)) as? [String: [String]]
        func candidates(dark: Bool) -> [URL] {
            var urls = (result?[dark ? "dark" : "light"] ?? []).compactMap(URL.init(string:))
                .filter { ["http", "https", "data"].contains($0.scheme?.lowercased() ?? "") }
            urls = Array(urls.prefix(4))
            let known = dark ? FaviconDiscovery.darkIcon(for: page) : FaviconDiscovery.lightIcon(for: page)
            if let known { urls.insert(known, at: 0) }
            if let fallback = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL { urls.append(fallback) }
            return urls
        }
        return IconCandidates(light: candidates(dark: false), dark: candidates(dark: true))
    }

    static func favicon(at candidates: IconCandidates) async -> UIImage? {
        let light = await firstIcon(at: candidates.light)
        let dark = candidates.dark == candidates.light ? nil : await firstIcon(at: candidates.dark)
        guard let light = light ?? dark else { return nil }
        return MobileFavicon.adaptive(light: light, dark: dark)
    }

    private static func firstIcon(at candidates: [URL]) async -> UIImage? {
        for url in candidates {
            guard !Task.isCancelled else { return nil }
            if let image = await icon(at: url) { return image }
        }
        return nil
    }

    private static func icon(at url: URL) async -> UIImage? {
        if let icon = icons[url] { return icon }
        guard let loaded = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5)),
              (loaded.1 as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let icon = MobileFavicon.decode(loaded.0) else { return nil }
        icons[url] = icon
        return icon
    }

}

/// A page's icon, its corners clipped a little as the Mac app's are, so square icons round off and
/// transparent or round ones keep their shape; without one, the Mac app's blank square.
final class FaviconView: UIView {
    static let size: CGFloat = 16
    static let cornerRadiusFraction: CGFloat = 4.0/16.0
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
        layer.cornerRadius = min(bounds.width, bounds.height)*Self.cornerRadiusFraction
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
    var onActivate: (() -> Void)?
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

    override func accessibilityActivate() -> Bool {
        guard let onActivate else { return super.accessibilityActivate() }
        onActivate()
        return true
    }

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

/// A tab in the horizontal deck: its favicon/title above the page. It's closed by swiping it up,
/// or with VoiceOver's Close Tab action.
final class TabCell: UIControl {
    private var touchOrigin: CGPoint?
    private var closeBaseTransform = CGAffineTransform.identity
    /// The last tab can't be closed; it can still be pulled down against resistance.
    var canClose = true
    var isPrivateBrowsing = false
    /// How far the caption moves right of its usual place, to keep a favicon on screen.
    var captionNudge: CGFloat = 0 { didSet { if captionNudge != oldValue { setNeedsLayout() } } }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        touchOrigin = touch.location(in: window)
        setPressed(true)
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isTap(at: touch.location(in: window)) else {
            touchOrigin = nil
            setPressed(false)
            return false
        }
        return true
    }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        let activate = touch.map { isTap(at: $0.location(in: window)) } ?? false
        touchOrigin = nil
        setPressed(false)
        if activate { sendActions(for: .primaryActionTriggered) }
    }
    override func cancelTracking(with event: UIEvent?) {
        touchOrigin = nil
        setPressed(false)
        super.cancelTracking(with: event)
    }
    private func isTap(at point: CGPoint) -> Bool {
        guard let touchOrigin else { return false }
        return hypot(point.x-touchOrigin.x, point.y-touchOrigin.y) <= 8
    }
    private func setPressed(_ pressed: Bool) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        UIView.animate(springDuration: pressed ? 0.2 : 0.3, bounce: pressed ? 0 : 0.3, initialSpringVelocity: 0,
                       delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.transform = pressed ? CGAffineTransform(scaleX: Self.pressedScale, y: Self.pressedScale) : .identity
        }
    }
    let card = TabCard()
    let cardShadow = UIView()
    private let shade = UIView()
    var roundingLayers: [CALayer] { [card.layer, shade.layer] }
    var shadeAmount: CGFloat = 0 { didSet { shade.alpha = shadeAmount*card.alpha } }
    var shownShadeAmount: CGFloat { CGFloat(shade.layer.presentation()?.opacity ?? shade.layer.opacity) }
    /// The favicon remains visible in the stack; only the focused card shows title text.
    let caption = UIView()
    let favicon = FaviconView()
    let title = UILabel()
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}
    var onGestureActivity: (Bool) -> Void = { _ in }
    /// `changed` carries the card's shown offset: negative up, or a resisted pull down.
    enum CloseGesture { case began, changed(CGFloat), ended(committed: Bool, velocity: CGFloat) }
    var onCloseGesture: (CloseGesture) -> Void = { _ in }
    var canBeginClose: () -> Bool = { true }
    private lazy var closePan = UIPanGestureRecognizer(target: self, action: #selector(dragToClose))
    private let closePanDelegate = TabClosePanDelegate()
    private static let iconGap: CGFloat = 6
    static let captionOffset: CGFloat = 6
    static let pressedScale: CGFloat = 0.97
    /// How far a pull down can ever show the card moved, as UIScrollView's rubber band gives.
    static let pullLimit: CGFloat = 150

    /// A pull down follows the finger less and less, as a scroll view's edge does.
    static func resisted(_ pull: CGFloat) -> CGFloat {
        guard pull > 0 else { return pull }
        return pullLimit*(1-1/(pull*0.55/pullLimit+1))
    }

    static func styleShadow(_ view: UIView) {
        view.isUserInteractionEnabled = false
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.10
        view.layer.shadowRadius = 6
        view.layer.shadowOffset = CGSize(width: 0, height: 2)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        Self.styleShadow(cardShadow)
        addSubview(cardShadow)
        card.layer.cornerRadius = TabSwitcherView.cornerRadius
        card.isAccessibilityElement = true
        card.accessibilityTraits = .button
        // The cell tracks the press; VoiceOver reaches the card itself.
        card.isUserInteractionEnabled = false
        card.onActivate = { [weak self] in self?.onSelect() }
        addSubview(card)
        shade.backgroundColor = .black
        shade.isUserInteractionEnabled = false
        shade.layer.cornerCurve = .continuous
        shade.alpha = 0
        addSubview(shade)
        isAccessibilityElement = false
        accessibilityElements = [card]
        addAction(UIAction { [weak self] _ in self?.setPressed(true) }, for: [.touchDown, .touchDragEnter])
        addAction(UIAction { [weak self] _ in self?.setPressed(false) },
                  for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        addAction(UIAction { [weak self] _ in self?.onSelect() }, for: .primaryActionTriggered)
        title.font = SearchPanel.roundedFont(ofSize: 13, weight: .semibold, scaled: false)
        title.textColor = .label
        title.lineBreakMode = .byTruncatingTail
        title.isAccessibilityElement = false
        caption.isUserInteractionEnabled = false
        caption.addSubview(favicon)
        caption.addSubview(title)
        addSubview(caption)
        closePan.delegate = closePanDelegate
        addGestureRecognizer(closePan)
        card.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Close Tab", target: self,
                                                                     selector: #selector(closeFromAccessibility))]
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Carries the visible press scale into the opening flight, even during the release spring.
    func shownCardFrame(in view: UIView) -> CGRect {
        if let shown = card.layer.presentation(), let destination = view.layer.presentation() {
            return shown.convert(shown.bounds, to: destination)
        }
        return card.convert(card.bounds, to: view)
    }
    func setCardOpacity(_ opacity: CGFloat) {
        card.alpha = opacity
        cardShadow.alpha = opacity
        shade.alpha = shadeAmount*opacity
    }

    @objc private func closeFromAccessibility() -> Bool {
        guard canClose else { return false }
        onClose(); return true
    }
    @objc private func dragToClose(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: superview).y
        switch pan.state {
        case .began: beginCloseDrag(); updateCloseDrag(translation)
        case .changed: updateCloseDrag(translation)
        case .ended, .cancelled, .failed:
            endCloseDrag(translation, velocity: pan.velocity(in: self).y, cancelled: pan.state != .ended)
        default: break
        }
    }
    /// Up, the card follows the finger to be closed (the last one can't go up at all); down, it
    /// gives against resistance and springs back.
    private func shownOffset(_ translation: CGFloat) -> CGFloat {
        translation < 0 ? (canClose ? translation : 0) : Self.resisted(translation)
    }
    func beginCloseDrag() {
        closeBaseTransform = CATransform3DGetAffineTransform((layer.presentation() ?? layer).transform)
        onGestureActivity(true)
        onCloseGesture(.began)
    }
    func updateCloseDrag(_ translation: CGFloat) {
        let offset = shownOffset(translation)
        transform = closeBaseTransform.translatedBy(x: 0, y: offset)
        onCloseGesture(.changed(offset))
    }
    func endCloseDrag(_ translation: CGFloat, velocity: CGFloat, cancelled: Bool) {
        let offset = shownOffset(translation)
        let commit = !cancelled && canClose && (offset < -bounds.height*0.18 || (velocity < -650 && offset < 0))
        onCloseGesture(.ended(committed: commit, velocity: velocity))
        if commit {
            isUserInteractionEnabled = false
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseIn]) {
                self.transform = self.closeBaseTransform.translatedBy(x: 0, y: -self.bounds.height*1.8)
            } completion: { _ in self.onGestureActivity(false); self.onClose() }
        } else {
            UIView.animate(springDuration: 0.3, bounce: 0.12, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.transform = .identity
            } completion: { _ in self.onGestureActivity(false) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.frame = CGRect(x: 0, y: TabSwitcherView.titleHeight, width: bounds.width, height: bounds.height-TabSwitcherView.titleHeight)
        cardShadow.frame = card.frame
        cardShadow.layer.shadowPath = UIBezierPath(roundedRect: cardShadow.bounds,
            cornerRadius: card.layer.cornerRadius).cgPath
        shade.frame = card.frame
        shade.layer.cornerRadius = card.layer.cornerRadius
        card.accessibilityLabel = title.text
        caption.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: TabSwitcherView.titleHeight-10)
        caption.center = CGPoint(x: bounds.midX+Self.captionOffset+captionNudge, y: card.frame.minY-7-caption.bounds.height/2)
        let icon = FaviconView.size, lead = icon+Self.iconGap
        let text = min(ceil(title.sizeThatFits(caption.bounds.size).width), caption.bounds.width-lead)
        favicon.frame = CGRect(x: 0, y: ((caption.bounds.height-icon)/2).rounded(), width: icon, height: icon)
        title.frame = CGRect(x: lead, y: 0, width: text, height: caption.bounds.height)
    }
}

/// An overlapping horizontal deck. The current page moves right while recent tabs rise from
/// the toolbar stack; swiping brings each card forward. Choosing a card grows it
/// back into the page from its pressed size. A swipe up the bottom bar shrinks the
/// page with the finger, the spot under it staying under it, and when let go it flies on at the
/// speed it was going and curves round into its card, on Summarise's springs. Every move can be
/// turned around partway, carrying on from its speed: Tabs again, a tap on the landing page, or a
/// swipe up as it grows back.
final class TabSwitcherView: UIView, UIScrollViewDelegate {
    static let titleHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 26
    /// The grid's own fade and growth.
    static let spring = (duration: 0.3, bounce: 0.14)
    static let returnSpring = (duration: 0.28, bounce: 0.0)
    /// The page's corners as it starts to shrink, which ease down to the card's, if the screen's
    /// can't be read.
    static let swipeRadius = 28.8
    /// How far into shrinking the moving page's own title starts to come in.
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

    let scroll = TabGridScrollView()
    /// Holds the cards, so they can fade, grow and sharpen in as one.
    let grid = UIView()
    /// Keep a page in flight inside the scroll gesture's ancestry too. It can be
    /// caught horizontally before landing, without turning that drag into a tap.
    private let flightContainer = TabFlightContainer()
    private(set) var cells: [TabCell] = []
    private(set) var current = 0
    private var recentIDs: [UUID] = []
    private var tabIDs: [UUID] = []
    private var slots: [Int: Int] = [:]
    private(set) var displayOrder: [Int] = [] {
        didSet { slots = Dictionary(uniqueKeysWithValues: displayOrder.enumerated().map { ($0.element, $0.offset) }) }
    }
    private let entrance = TabDeckEntrance()
    private var closing: TabDeckDismissal?
    private var reflowing = false
    private var layingOutDeck = false
    private var scrollCatch: (shape: Shape, target: Shape)?
    private var caughtCells: [ObjectIdentifier: (offset: CGPoint, transform: CGAffineTransform, radius: CGFloat)] = [:]
    private var caughtOffset: CGFloat = 0
    private var focusMove = 0
    /// The page on its way into, or out of, its card, and which way it's going; nil while a finger
    /// holds it.
    private(set) var moving: TabCard?
    private(set) var movingShadow: UIView?
    var isAnimatingOrTracking: Bool {
        moving != nil || closing != nil || reflowing || scroll.isTracking || scroll.isDragging || scroll.isDecelerating
    }
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
    #if DEBUG
    /// Native audit's boundary, before any snapshot work that follows the first commit.
    var onFlightCommit: () -> Void = {}
    #endif
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
    /// "Incognito mode", just under the Dynamic Island, while the private tabs show.
    private let modeLabel = UILabel()
    private(set) var showsIncognitoLabel = false
    /// Said in the middle when there are no cards, such as when no private tabs are open.
    private let emptyLabel = UILabel()
    var emptyText: String? {
        didSet { emptyLabel.text = emptyText; updateEmptyLabel(animated: window != nil) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        backgroundColor = Self.background
        modeLabel.text = "Incognito mode"
        modeLabel.font = SearchPanel.roundedFont(ofSize: 15, weight: .semibold)
        modeLabel.adjustsFontForContentSizeCategory = true
        modeLabel.textColor = .secondaryLabel
        modeLabel.textAlignment = .center
        modeLabel.alpha = 0
        modeLabel.accessibilityTraits = .header
        emptyLabel.font = SearchPanel.roundedFont(ofSize: 17, weight: .semibold)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = .tertiaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.alpha = 0
        scroll.delegate = self
        scroll.alwaysBounceHorizontal = true
        scroll.alwaysBounceVertical = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.decelerationRate = .fast
        scroll.isDirectionalLockEnabled = true
        scroll.delaysContentTouches = false
        scroll.contentInsetAdjustmentBehavior = .never
        addSubview(scroll)
        scroll.addSubview(grid)
        scroll.addSubview(flightContainer)
        addSubview(emptyLabel)
        addSubview(modeLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Brings "Incognito mode" in, settling down into place, or sends it up and away, quickly.
    func setIncognitoLabel(_ shown: Bool, animated: Bool) {
        guard shown != showsIncognitoLabel else { return }
        showsIncognitoLabel = shown
        modeLabel.accessibilityElementsHidden = !shown
        let apply = {
            self.modeLabel.alpha = shown ? 1 : 0
            self.modeLabel.transform = shown ? .identity : CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 0.96, y: 0.96)
        }
        guard animated, !isHidden, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            modeLabel.layer.removeAllAnimations(); apply(); return
        }
        if shown, modeLabel.alpha == 0 {
            modeLabel.transform = CGAffineTransform(translationX: 0, y: -6).scaledBy(x: 0.96, y: 0.96)
        }
        UIView.animate(springDuration: shown ? 0.32 : 0.2, bounce: 0, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction], animations: apply)
    }

    private func updateEmptyLabel(animated: Bool) {
        let shown: CGFloat = cells.isEmpty && emptyText != nil ? 1 : 0
        guard emptyLabel.alpha != shown else { return }
        guard animated, !isHidden else { emptyLabel.layer.removeAllAnimations(); emptyLabel.alpha = shown; return }
        UIView.animate(withDuration: shown > 0 ? 0.22 : 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.emptyLabel.alpha = shown
        }
    }

    /// Swaps the cards for another set, such as the private tabs for the others, with the
    /// switcher open: the new cards come in as the old ones go, quickly, where they'd rest.
    func switchDeck(to tabs: [BrowserTab], current: Int?, animated: Bool = true) {
        let outgoing = !animated || isHidden || cells.isEmpty ? nil : grid.snapshotView(afterScreenUpdates: false)
        stop()
        load(tabs, current: current ?? 0)
        UIView.performWithoutAnimation {
            for cell in cells {
                cell.transform = .identity
                cell.setCardOpacity(1)
                cell.caption.layer.removeAllAnimations()
                cell.caption.alpha = 1
                cell.caption.transform = .identity
            }
            scrollToCurrent()
            anchorGridOnScreen()
            grid.transform = .identity
        }
        updateEmptyLabel(animated: animated)
        guard animated, window != nil, !isHidden, !UIAccessibility.isReduceMotionEnabled else { grid.alpha = 1; return }
        if let outgoing {
            outgoing.frame = convert(grid.frame, from: scroll)
            outgoing.isUserInteractionEnabled = false
            insertSubview(outgoing, aboveSubview: scroll)
            UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut]) {
                outgoing.alpha = 0
                outgoing.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
            } completion: { _ in outgoing.removeFromSuperview() }
        }
        grid.alpha = 0
        grid.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
        UIView.animate(springDuration: 0.3, bounce: 0, initialSpringVelocity: 0, delay: 0.04,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.grid.alpha = 1
            self.grid.transform = .identity
        }
    }

    private var deck: TabDeckLayout {
        TabDeckLayout(size: bounds.size, stripHeight: stripHeight, topInset: topInset,
                      bottomInset: bottomInset, count: cells.count, focus: focus)
    }
    var focus: CGFloat { scroll.contentOffset.x/max(1, bounds.width*0.57) }
    var cardSize: CGSize { deck.cardSize }
    var focusedIndex: Int? {
        guard !displayOrder.isEmpty else { return nil }
        return displayOrder[min(displayOrder.count-1, max(0, Int(focus.rounded())))]
    }
    var onFocusChange: ((Int) -> Void)?
    private var previewFocus: Int?
    /// A cell's frame in the viewport. The scroll view supplies native momentum; card
    /// positions compress on the left, rather than becoming a flat row of thumbnails.
    func cellFrame(_ index: Int) -> CGRect {
        deck.frame(at: slots[index] ?? 0)
    }

    /// Where a tab's card sits on screen once settled, in this view.
    private func cardFrame(_ index: Int) -> CGRect {
        let cell = cellFrame(index)
        return CGRect(x: cell.minX, y: cell.minY+Self.titleHeight, width: cell.width, height: cell.height-Self.titleHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !layingOutDeck else { return }
        layingOutDeck = true
        scroll.frame = bounds
        scroll.contentInset = .zero
        scroll.contentSize = CGSize(width: bounds.width+CGFloat(max(0, cells.count-1))*deck.step, height: bounds.height)
        layingOutDeck = false
        let labelHeight = ceil(modeLabel.font.lineHeight)
        modeLabel.bounds = CGRect(x: 0, y: 0, width: bounds.width-32, height: labelHeight)
        // A little under the Dynamic Island, above the cards' titles.
        modeLabel.center = CGPoint(x: bounds.midX, y: topInset-4+labelHeight/2)
        emptyLabel.frame = CGRect(x: 16, y: topInset, width: bounds.width-32, height: max(0, bounds.height-topInset-bottomInset))
        layoutDeck()
    }

    private func layoutDeck() {
        guard !layingOutDeck else { return }
        layingOutDeck = true
        defer { layingOutDeck = false }
        grid.bounds = bounds
        grid.center = CGPoint(x: scroll.contentOffset.x+bounds.midX, y: bounds.midY)
        flightContainer.bounds = bounds
        flightContainer.center = grid.center
        if let closing { closing.apply(); fadeCoveringFavicons(); return }
        if let focusedIndex, focusedIndex != previewFocus {
            previewFocus = focusedIndex; onFocusChange?(focusedIndex)
        }
        let blend = min(1, abs(scroll.contentOffset.x-caughtOffset)/90)
        for (index, cell) in cells.enumerated() {
            let slot = slots[index] ?? 0
            let distance = CGFloat(slot)-focus
            let visible = distance >= -5 && distance <= 2.2
            if cell.isHidden && !visible { continue }
            cell.isHidden = !visible
            guard visible else { continue }
            let frame = cellFrame(index)
            cell.bounds = CGRect(origin: .zero, size: frame.size)
            cell.center = CGPoint(x: frame.midX, y: frame.midY)
            cell.shadeAmount = deck.shadeOpacity(at: slot)
            // A card just off the left edge keeps its favicon 4 pt in, as Arc does, tucked
            // under the next one's; further off, the favicon goes with its card.
            let icon = frame.minX+TabCell.captionOffset
            cell.captionNudge = max(icon, min(4, 3*frame.minX+43))-icon
            cell.title.alpha = deck.titleOpacity(at: slot)
            cell.card.layer.cornerRadius = Self.cornerRadius*frame.width/max(1, cardSize.width)
            cell.canClose = cells.count > 1 || cell.isPrivateBrowsing
            cell.layoutIfNeeded()
            if entrance.isPrepared, index != current {
                entrance.place(cell, depth: max(0, displayOrder.count-2-slot))
            } else if let caught = caughtCells[ObjectIdentifier(cell)] {
                cell.center.x += caught.offset.x*(1-blend)
                cell.center.y += caught.offset.y*(1-blend)
                let t = caught.transform
                cell.transform = CGAffineTransform(a: t.a+(1-t.a)*blend, b: t.b*(1-blend),
                    c: t.c*(1-blend), d: t.d+(1-t.d)*blend, tx: t.tx*(1-blend), ty: t.ty*(1-blend))
                let targetRadius = Self.cornerRadius*frame.width/max(1, cardSize.width)
                cell.card.layer.cornerRadius = caught.radius+(targetRadius-caught.radius)*blend
                cell.setNeedsLayout(); cell.layoutIfNeeded()
            }
        }
        fadeCoveringFavicons()
    }

    /// A card's favicon fades where it would sit over another card's title, so the title can be
    /// read: the next card's icon over a long title of the centred one. It fades as that title
    /// shows, and with how far the title reaches under it.
    private func fadeCoveringFavicons() {
        let titles = cells.compactMap { cell -> (cell: TabCell, frame: CGRect, shown: CGFloat)? in
            let shown = cell.title.alpha*cell.caption.alpha
            guard !cell.isHidden, shown > 0.01 else { return nil }
            return (cell, cell.caption.convert(cell.title.frame, to: grid), shown)
        }
        for cell in cells where !cell.isHidden {
            let icon = cell.caption.convert(cell.favicon.frame, to: grid)
            var covered: CGFloat = 0
            for title in titles where title.cell !== cell && abs(title.frame.midY-icon.midY) < icon.height {
                // From 8 points short of the icon to 4 points under it.
                let reach = min(1, max(0, (title.frame.maxX+8-icon.minX)/12))
                    * min(1, max(0, (icon.maxX-title.frame.minX)/12))
                covered = max(covered, reach*title.shown)
            }
            cell.favicon.alpha = 1-covered
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
        previewFocus = nil
        closing = nil; reflowing = false; focusMove += 1
        entrance.stop(cells: cells)
        cells.forEach { $0.removeFromSuperview() }
        tabIDs = tabs.map(\.id)
        // The other set's order is kept for when it shows again, such as the tabs after Incognito.
        let currentID = tabIDs.indices.contains(current) ? tabIDs[current] : nil
        recentIDs.removeAll { $0 == currentID }
        recentIDs.append(contentsOf: tabIDs.filter { !recentIDs.contains($0) && $0 != currentID })
        if let currentID { recentIDs.append(currentID) }
        displayOrder = recentIDs.compactMap { tabIDs.firstIndex(of: $0) }
        cells = tabs.map { tab in
            let cell = TabCell()
            cell.isPrivateBrowsing = tab.isPrivateBrowsing
            cell.card.image.image = tab.snapshot
            tab.onSnapshotChange = { [weak tab, weak cell] in cell?.card.image.image = tab?.snapshot }
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
            cell.onGestureActivity = { [weak self] active in
                guard let self else { return }
                holdRate(active || moving != nil || closing != nil || reflowing)
            }
            cell.canBeginClose = { [weak self] in self?.closing == nil }
            cell.onCloseGesture = { [weak self, weak cell] gesture in
                guard let self, let cell, let index = cells.firstIndex(of: cell) else { return }
                self.closeGesture(gesture, at: index)
            }
            grid.addSubview(cell)
            return cell
        }
        self.current = current
        for index in displayOrder { grid.bringSubviewToFront(cells[index]) }
        updateEmptyLabel(animated: false)
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
        grid.alpha = 1
        grid.transform = .identity
        entrance.prepare(size: bounds.size, bottomInset: bottomInset, radius: pageRadius)
        layoutDeck()
        showStationaryCaptions()
        cells[current].caption.alpha = 0
        cells[current].caption.transform = CGAffineTransform(translationX: 0, y: 6)
        cells[current].setCardOpacity(0)
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
        BlurCrossfade.stop(in: scroll)
        UIView.performWithoutAnimation {
            grid.layer.removeAllAnimations()
            grid.alpha = 1
            grid.transform = .identity
        }
        showStationaryCaptions()
        settle(button: true, alongside: { self.animateDeckEntry() })
    }

    private func animateDeckEntry() {
        entrance.animate(cells: cells, current: current, order: displayOrder, cardWidth: cardSize.width) { self.deck.frame(at: $0) }
    }

    /// Catches the page as it grows back out of its card, for a swipe to shrink it again from there.
    func catchPage() {
        guard let card = moving else { return }
        move += 1
        heading = nil
        freeze(card)
        showStationaryCaptions()
        holdRate(true)
        BlurCrossfade.stop(in: scroll)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.grid.alpha = 1
        }
        let shape = shape(of: card)
        let progress = min(1, max(0, (1-shape.scale)/max(0.01, 1-cardShape(current).scale)))
        caught = (CGFloat(progress), shape)
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
        let target = cardShape(current), width = Double(bounds.width), height = Double(bounds.height)
        let s = progress <= 1 ? 1-(1-target.scale)*progress : target.scale*exp(-(progress-1))
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
        grid.alpha = 1
        entrance.follow(swipeProgress)
        layoutDeck()
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
            settle(velocity: velocity, alongside: { self.animateDeckEntry() })
            completion()
            return
        }
        UIView.animate(springDuration: Self.returnSpring.duration, bounce: Self.returnSpring.bounce, initialSpringVelocity: 0,
                       delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.grid.alpha = 0
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

    /// The stationary cards already have their titles, including when a closing flight is caught.
    private func showStationaryCaptions() {
        UIView.performWithoutAnimation {
            for (index, cell) in cells.enumerated() where index != current {
                cell.caption.layer.removeAllAnimations()
                cell.caption.alpha = 1
                cell.caption.transform = .identity
            }
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
            apply(cardShape(index, asShown: true), to: card)
        }
        cell.setCardOpacity(0)
        anchorGridOnScreen()
        grow(card, alongside: {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.grid.alpha = 0
                self.emptyLabel.alpha = 0
            }
            self.setIncognitoLabel(false, animated: true)
            self.fadeCaptions()
        }, completion: completion)
    }

    /// Closes a tab's card, the others moving up to fill its place.
    func remove(at index: Int, current: Int) {
        guard cells.indices.contains(index) else { return }
        if moving != nil { land() }
        entrance.freeze(cells: cells)
        let oldSlot = displayOrder.firstIndex(of: index) ?? 0
        let dragged = closing.flatMap { $0.cell === cells[index] ? $0 : nil }
        let continuingDrag = dragged?.committed == true
        let next = dragged?.nextFocus ?? TabDeckDismissal.focusAfterRemoving(slot: oldSlot, from: deck)
        closing = nil
        let cell = cells.remove(at: index)
        let id = tabIDs.remove(at: index)
        recentIDs.removeAll { $0 == id }
        displayOrder = recentIDs.compactMap { tabIDs.firstIndex(of: $0) }
        self.current = current
        caughtCells = [:]
        updateEmptyLabel(animated: true)
        if cell.isUserInteractionEnabled {
            // Closed from VoiceOver's action, it shrinks and fades where it is.
            cell.isUserInteractionEnabled = false
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .curveEaseOut]) {
                cell.alpha = 0
                cell.transform = cell.transform.scaledBy(x: 0.8, y: 0.8)
            } completion: { _ in cell.removeFromSuperview() }
        } else {
            // A swiped card is already off screen. Never animate its translation
            // back to zero as the remaining cards close the gap.
            cell.removeFromSuperview()
        }
        UIView.performWithoutAnimation {
            // Offset and viewport anchoring must change together. Otherwise UIScrollView
            // clamps the shorter content first and momentarily shifts every card.
            self.layingOutDeck = true
            self.scroll.setContentOffset(self.scroll.contentOffset, animated: false)
            self.scroll.contentSize = CGSize(width: self.bounds.width+CGFloat(max(0, self.cells.count-1))*self.deck.step,
                                             height: self.bounds.height)
            self.scroll.contentOffset = CGPoint(x: next*self.deck.step, y: 0)
            self.grid.center = CGPoint(x: self.scroll.contentOffset.x+self.bounds.midX, y: self.bounds.midY)
            self.flightContainer.center = self.grid.center
            self.layingOutDeck = false
            if continuingDrag { self.layoutDeck() }
        }
        // The release spring is already moving the survivors to these exact poses.
        // Removing the offscreen tab must not restart or delay that animation.
        if continuingDrag { CATransaction.flush(); return }
        focusMove += 1
        let reflow = focusMove
        reflowing = true
        holdRate(true)
        UIView.animate(springDuration: 0.36, bounce: 0.06, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            // A close can catch the entrance before its cards reach full size.
            // Their frozen transforms must settle along with their new positions.
            for cell in self.cells { cell.transform = .identity }
            self.layoutDeck()
        } completion: { _ in
            if self.focusMove == reflow {
                self.reflowing = false
                if self.moving == nil && !self.scroll.isDragging && !self.scroll.isDecelerating { self.holdRate(false) }
            }
        }
        CATransaction.flush()
    }

    /// Brings back a closed tab's card, focused, where it was in the deck: before `next`, the tab
    /// that followed it. It drops back in from above, where it was swiped away, as the others
    /// move from where they are to make room.
    func restore(_ tabs: [BrowserTab], current: Int, restored index: Int, before next: UUID?) {
        guard tabs.indices.contains(index) else { return }
        var shown: [UUID: (centre: CGPoint, bounds: CGRect, radius: CGFloat)] = [:]
        for (id, cell) in zip(tabIDs, cells) where !cell.isHidden {
            shown[id] = (cell.center, cell.bounds, cell.card.layer.cornerRadius)
        }
        let id = tabs[index].id
        recentIDs.removeAll { $0 == id }
        recentIDs.insert(id, at: next.flatMap { recentIDs.firstIndex(of: $0) } ?? recentIDs.count)
        load(tabs, current: current)
        guard let slot = displayOrder.firstIndex(of: index) else { return }
        let restored = cells[index]
        UIView.performWithoutAnimation {
            scroll.contentOffset = CGPoint(x: CGFloat(slot)*deck.step, y: 0)
            layoutDeck()
            for (id, cell) in zip(tabIDs, cells) {
                guard let was = shown[id] else { continue }
                cell.center = was.centre; cell.bounds = was.bounds
                cell.card.layer.cornerRadius = was.radius
                cell.layoutIfNeeded()
            }
            restored.transform = CGAffineTransform(translationX: 0, y: -restored.frame.maxY-40)
        }
        focusMove += 1
        let reflow = focusMove
        reflowing = true
        holdRate(true)
        UIView.animate(springDuration: 0.42, bounce: 0.08, initialSpringVelocity: 0, delay: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction]) {
            for cell in self.cells { cell.transform = .identity }
            self.layoutDeck()
        } completion: { _ in
            if self.focusMove == reflow {
                self.reflowing = false
                if self.moving == nil && !self.scroll.isDragging && !self.scroll.isDecelerating { self.holdRate(false) }
            }
        }
    }

    private func closeGesture(_ gesture: TabCell.CloseGesture, at index: Int) {
        switch gesture {
        case .began:
            guard closing == nil, cells.count > 1 || cells[index].isPrivateBrowsing else { return }
            if moving != nil { land() }
            entrance.freeze(cells: cells)
            caughtCells = [:]
            scroll.setContentOffset(scroll.contentOffset, animated: false)
            let reflow = TabDeckDismissal(cells: cells, order: displayOrder, closing: index, layout: deck)
            closing = reflow
            focusMove += 1
            reflowing = false
            // Freeze any previous release at its displayed pose before following the finger.
            UIView.performWithoutAnimation { reflow.catchMotion() }
            holdRate(true)
        case .changed(let offset):
            guard let closing, closing.cell === cells[index], !closing.committed else { return }
            UIView.performWithoutAnimation { closing.follow(offset: offset) }
        case .ended(let committed, let velocity):
            guard let reflow = closing, reflow.cell === cells[index] else { return }
            let move = focusMove
            let speed = committed ? reflow.releaseVelocity(velocity) : 0
            reflowing = true
            UIView.animate(springDuration: 0.36, bounce: 0.06, initialSpringVelocity: speed, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                if committed { reflow.commit() }
                else { self.closing = nil; self.layoutDeck() }
            } completion: { _ in
                if self.focusMove == move {
                    self.reflowing = false
                    if self.moving == nil && !self.scroll.isDragging && !self.scroll.isDecelerating { self.holdRate(false) }
                }
            }
            CATransaction.flush()
        }
    }

    /// Hides the switcher at once.
    func hide() {
        stop()
        setIncognitoLabel(false, animated: false)
        emptyLabel.alpha = 0
        isHidden = true
        grid.alpha = 0
        grid.transform = .identity
        for cell in cells { cell.setCardOpacity(1) }
    }

    private func makeMovingCard(image: UIImage?) -> TabCard {
        moving?.removeFromSuperview()
        movingShadow?.removeFromSuperview()
        let shadow = UIView()
        TabCell.styleShadow(shadow)
        shadow.layer.shadowOpacity = 0
        flightContainer.addSubview(shadow)
        movingShadow = shadow
        let card = TabCard()
        card.image.image = image
        card.pageSize = pageSize
        card.stripHeight = stripHeight
        card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(movingTapped)))
        flightContainer.addSubview(card)
        moving = card
        return card
    }

    /// A tap on the page as it lands grows it back.
    @objc private func movingTapped() {
        if heading == .card { onSelect(current) }
    }

    /// Moves the page into its card, with its own title coming in after it: let go, at the speed it
    /// was going, and otherwise turning round from however it was already moving.
    private func settle(velocity: Shape? = nil, button: Bool = false, alongside: () -> Void = {}) {
        guard let card = moving, cells.indices.contains(current) else { return }
        move += 1
        let move = move
        heading = .card
        fly(card, to: cardShape(current), velocity: velocity ?? flightVelocity(),
            scale: button ? TabDeckMotion.entryScale : TabDeckMotion.releaseScale,
            place: button ? TabDeckMotion.entryMove : TabDeckMotion.releaseMove,
            shape: TabDeckMotion.entryShape, alongside: alongside) { [weak self] in
            guard let self, self.move == move else { return }
            land()
        }
    }

    /// Grows the page to fill the window, then hides the switcher: as Summarise's card grows back,
    /// or, let go short, springing back from the speed it was going.
    private func grow(_ card: TabCard, velocity: Shape? = nil, alongside: () -> Void = {}, completion: @escaping () -> Void) {
        move += 1
        let move = move
        heading = .page
        let done = { [weak self] in
            guard let self, self.move == move else { return }
            hide()
            completion()
        }
        // Already moving, it turns round from that speed.
        if let speed = velocity ?? (flight != nil ? flightVelocity() : nil) {
            fly(card, to: pageShape, velocity: speed, scale: TabDeckMotion.cancel, place: TabDeckMotion.cancel,
                shape: TabDeckMotion.cancel, alongside: alongside, done: done)
        } else {
            fly(card, to: pageShape, velocity: nil, scale: TabDeckMotion.open, place: TabDeckMotion.open,
                shape: TabDeckMotion.open, alongside: alongside, done: done)
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
    private func cardShape(_ index: Int, asShown: Bool = false) -> Shape {
        let frame = asShown ? cells[index].shownCardFrame(in: self) : cardFrame(index)
        let scale = Double(frame.width/max(1, bounds.width))
        let pressScale = frame.width/max(1, cardSize.width)
        return Shape(x: Double(frame.midX), y: Double(frame.midY), scale: scale, height: Double(frame.height)/scale,
                     crop: 1, radius: Double(Self.cornerRadius*pressScale))
    }

    /// The shadow grows smoothly as the full page becomes a card, and fades as it reopens.
    private func shadowOpacity(for shape: Shape) -> Float {
        let target = cardShape(current).scale
        let progress = min(1, max(0, (1-shape.scale)/max(0.01, 1-target)))
        return Float(progress*progress*(3-2*progress))*0.10
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
        if card === moving, let shadow = movingShadow {
            shadow.bounds = card.bounds
            shadow.center = card.center
            shadow.layer.shadowPath = UIBezierPath(roundedRect: shadow.bounds, cornerRadius: card.layer.cornerRadius).cgPath
            shadow.layer.shadowOpacity = shadowOpacity(for: shape)
        }
        if card === moving, heading != .page { placeCaptions(for: shape) }
    }

    /// Only the moving page's title rides under it and fades in as it reaches its card.
    private func placeCaptions(for shape: Shape) {
        guard let captions = captions(for: shape) else { return }
        cells[current].caption.alpha = captions.alpha
        cells[current].caption.transform = captions.transform
    }

    private func captions(for shape: Shape) -> (alpha: Double, transform: CGAffineTransform)? {
        guard cells.indices.contains(current) else { return nil }
        let target = cardShape(current)
        let k = min(1, max(0, ((1-shape.scale)/max(0.01, 1-target.scale)-Self.captionFrom)/(1-Self.captionFrom)))
        let shown = k*k*(3-2*k)
        // Its own above the page, wherever it is, rather than above its eventual card.
        let height = shape.height*shape.scale
        return (shown, CGAffineTransform(translationX: shape.x-target.x,
            y: (shape.y-height/2)-(target.y-target.height*target.scale/2)-6*(1-shown)))
    }

    /// Flies the page along its springs on Core Animation: the whole path is worked out at once,
    /// as nothing but a new touch changes it, and played as keyframes 120 times a second, so it
    /// carries on smoothly while the main thread is busy, as it is for the keyboard coming up.
    private func fly(_ card: TabCard, to target: Shape, velocity: Shape?,
                     scale: SummariseSpring, place: SummariseSpring, shape: SummariseSpring,
                     alongside: () -> Void = {}, done: @escaping () -> Void) {
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
        // Commit the moving page before drawing/filtering the grid's blurred copies. The
        // render server can start its 120 Hz flight while that CPU work runs on the main thread.
        CATransaction.flush()
        #if DEBUG
        onFlightCommit()
        #endif
        alongside()
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
        if let shadow = movingShadow {
            let bounds = frames.map { CGRect(origin: .zero, size: $0.size) }
            keyframes(shadow.layer, "bounds", bounds.map { NSValue(cgRect: $0) })
            keyframes(shadow.layer, "position", frames.map { NSValue(cgPoint: CGPoint(x: $0.midX, y: $0.midY)) })
            keyframes(shadow.layer, "shadowPath", zip(bounds,path).map { frame, shape in
                UIBezierPath(roundedRect: frame, cornerRadius: max(0, shape.radius)).cgPath
            })
            keyframes(shadow.layer, "shadowOpacity", path.map { shadowOpacity(for: $0) })
        }
        let pages = zip(path, frames).map { shape, frame in
            TabCard.pageLayout(width: frame.width, crop: min(1, max(0, shape.crop)), pageSize: card.pageSize, stripHeight: card.stripHeight)
        }
        keyframes(card.image.layer, "bounds", pages.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.frame.size)) })
        keyframes(card.image.layer, "position", pages.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        if let replica = card.replica {
            keyframes(replica.layer, "transform", pages.map { NSValue(caTransform3D: CATransform3DMakeScale($0.scale, $0.scale, 1)) })
            keyframes(replica.layer, "position", pages.map { NSValue(cgPoint: CGPoint(x: $0.frame.midX, y: $0.frame.midY)) })
        }
        // Only the moving page's title rides along on the way in.
        if heading != .page {
            let titles = path.compactMap { captions(for: $0) }
            if titles.count == path.count {
                let caption = cells[current].caption.layer
                keyframes(caption, "opacity", titles.map { Float($0.alpha) })
                keyframes(caption, "transform",
                          titles.map { NSValue(caTransform3D: CATransform3DMakeAffineTransform($0.transform)) })
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
        if let shadow = movingShadow { layers.append(shadow.layer) }
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
        cell?.setCardOpacity(1)
        card.removeFromSuperview()
        movingShadow?.removeFromSuperview()
        movingShadow = nil
        moving = nil
        heading = nil
    }

    /// Leaves the page where it shows, its flight dropped.
    private func freeze(_ card: TabCard) {
        stopFlight()
    }

    /// Ends whatever was moving, so a new move starts clean.
    private func stop() {
        move += 1
        stopFlight()
        entrance.stop(cells: cells)
        closing = nil
        reflowing = false
        caughtCells = [:]; scrollCatch = nil
        holdRate(false)
        history = []
        moving?.removeFromSuperview()
        movingShadow?.removeFromSuperview()
        movingShadow = nil
        moving = nil
        heading = nil
        caught = nil
    }

    /// Arc leaves the active page at the right, with the previous tab ready in front.
    private func scrollToCurrent() {
        layoutIfNeeded()
        guard let slot = displayOrder.firstIndex(of: current) else { return }
        scroll.contentOffset = CGPoint(x: CGFloat(max(0, slot-1))*deck.step, y: 0)
        layoutDeck()
    }

    /// The grid grows in around the middle of what shows, rather than of all of it.
    private func anchorGridOnScreen() {
        grid.layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        grid.center = CGPoint(x: scroll.contentOffset.x+bounds.midX, y: bounds.midY)
    }

    /// Also used by keyboard/VoiceOver navigation and deterministic native motion checks.
    func focusTab(_ index: Int, animated: Bool = false) {
        guard let slot = displayOrder.firstIndex(of: index) else { return }
        // This takes over from any reflow, whose completion no longer clears it.
        reflowing = false
        focusMove += 1
        let move = focusMove
        let changes = {
            self.scroll.contentOffset = CGPoint(x: CGFloat(slot)*self.deck.step, y: 0)
            self.layoutDeck()
        }
        if animated {
            holdRate(true)
            UIView.animate(springDuration: 0.34, bounce: 0.10, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) { _ in
                if self.focusMove == move && self.moving == nil && !self.scroll.isDragging { self.holdRate(false) }
            }
        } else {
            UIView.performWithoutAnimation {
                for cell in cells { TabDeckDismissal.stopMotion(cell.layer); cell.transform = .identity }
                changes()
            }
        }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let step: Int
        switch direction {
        case .left, .next: step = 1
        case .right, .previous: step = -1
        default: return false
        }
        let slot = Int(focus.rounded())+step
        guard displayOrder.indices.contains(slot) else { return false }
        let index = displayOrder[slot]
        focusTab(index, animated: true)
        UIAccessibility.post(notification: .pageScrolled, argument: cells[index].title.text)
        return true
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutDeck()
        if let caught = scrollCatch, let card = moving {
            let target = cardShape(current)
            var shape = caught.shape
            shape.x += target.x-caught.target.x
            shape.y += target.y-caught.target.y
            shape.scale *= target.scale/caught.target.scale
            apply(shape, to: card)
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The ancestor scroll pan may recognise alongside the upward close. Its
        // callbacks must not steal that gesture's focus or completion token.
        guard closing == nil else { return }
        // This takes over from any reflow, whose completion no longer clears it.
        reflowing = false
        focusMove += 1
        holdRate(true)
        let speed = scroll.panGestureRecognizer.velocity(in: self)
        guard abs(speed.x) >= abs(speed.y) else { return }
        caughtCells = [:]; caughtOffset = scroll.contentOffset.x
        // A sideways swipe can catch either an incoming stack or a close reflow.
        // Carry the displayed size and position into the gesture, shedding offsets over 90 pt.
        for cell in cells where (cell.layer.animationKeys() ?? []).contains(where: {
            $0.hasPrefix("deck.") || $0.hasPrefix("position") || $0.hasPrefix("bounds") || $0.hasPrefix("transform")
        }) {
            let shown = cell.layer.presentation() ?? cell.layer
            let target = cellFrame(cells.firstIndex(of: cell)!)
            let transform = CATransform3DGetAffineTransform(shown.transform).scaledBy(
                x: shown.bounds.width/max(1, target.width), y: shown.bounds.height/max(1, target.height))
            caughtCells[ObjectIdentifier(cell)] = (CGPoint(x: shown.position.x-target.midX,
                                                         y: shown.position.y-target.midY),
                                                  transform,
                                                  cell.card.layer.presentation()?.cornerRadius ?? cell.card.layer.cornerRadius)
            TabDeckDismissal.stopMotion(cell.layer)
        }
        entrance.stop(cells: cells)
        if let card = moving, heading == .card {
            let shown = shape(of: card, asShown: true)
            scrollCatch = (shown, cardShape(current))
            stopFlight(); heading = nil
            apply(shown, to: card)
        }
        layoutDeck()
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let slot = min(CGFloat(max(0, cells.count-1)), max(0, (targetContentOffset.pointee.x/deck.step).rounded()))
        targetContentOffset.pointee = CGPoint(x: slot*deck.step, y: 0)
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { finishDeckScroll() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishDeckScroll() }
    private func finishDeckScroll() {
        guard closing == nil else { return }
        if !caughtCells.isEmpty {
            caughtCells = [:]
            UIView.animate(springDuration: 0.26, bounce: 0.08, initialSpringVelocity: 0, delay: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction]) {
                for cell in self.cells { cell.transform = .identity }
                self.layoutDeck()
            }
        }
        if scrollCatch != nil, moving != nil {
            scrollCatch = nil
            settle()
        } else if moving == nil { holdRate(false) }
        let slot = min(max(0, cells.count-1), max(0, Int(focus.rounded())))
        if displayOrder.indices.contains(slot), abs(scroll.contentOffset.x-CGFloat(slot)*deck.step) > 0.5 {
            focusTab(displayOrder[slot], animated: true)
        }
    }
}

/// A tab's press starts immediately, but dragging it still hands control to grid scrolling.
final class TabGridScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// Keep the close recognizer's direction policy separate from UIView's gesture admission
/// method, which UIKit also calls for ancestor pans before velocity is available.
private final class TabClosePanDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let cell = pan.view as? TabCell else { return true }
        let speed = pan.velocity(in: cell)
        // Up to close it; down, even the last tab, to pull it against resistance.
        return cell.canBeginClose() && (speed.y > 0 || cell.canClose) && abs(speed.y) > abs(speed.x)*1.15
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer.view is UIScrollView
    }
}

/// An empty flight layer lets touches reach the resting cards beneath it.
private final class TabFlightContainer: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

