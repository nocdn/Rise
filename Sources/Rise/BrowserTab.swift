import AppKit
import RiseCore

@MainActor final class BrowserTab: NSObject {
    let id: UUID
    /// The page on show. A Peek growing into the tab trades pages with it rather than loading again.
    private(set) var page: WebPage
    /// Earlier live pages, oldest first, that Back reaches once this page's own history runs out;
    /// and later ones Forward reaches. Each holder only keeps a page; it isn't a tab in the list.
    var backPages: [BrowserTab] = []
    var forwardPages: [BrowserTab] = []
    /// Older Peek pages can be released while their URLs remain reachable and restorable.
    var archivedBackEntries: [TabNavigationHistory.Entry] = []
    var title: String
    var customTitle: String?
    /// Leaves YouTube's notification count out of the title.
    var hidesNotificationCounts = true
    /// Shows a merge request's project under its title in the tab list.
    var showsRepositorySubtitle = true
    var pinned: Bool
    var developer: Bool
    var requestedURL: URL?
    /// The address last counted as a visit (as history keys it), so the tab coming back at launch
    /// or a reload doesn't count it again.
    var visitedAddress: String?
    /// The tab whose page opened this one in a new tab and brought the user here. Back, once
    /// this tab's own history runs out, closes it and returns there.
    var returnsTo: UUID?
    /// The tab it was opened from, for closing it to go back there.
    var openedFrom: UUID?
    /// The currency Replace on Page has its page's prices in, and how many it replaced.
    var replacedCurrency: (code: String, count: Int)?
    /// Whether the page is making sound.
    var isPlayingAudio: Bool { page.isPlayingAudio }
    /// The page keeps playing, but without sound.
    private(set) var isAudioMuted = false
    var onChange: (() -> Void)?
    /// While `onChange` runs: what changed came from the page itself, as it loads, rather than
    /// from Rise, and whether only its progress moved.
    private(set) var reportingPageChange: (progressOnly: Bool, Void)?
    private(set) var hasAttemptedNavigation = false
    var isLoading: Bool { page.isLoading }
    var needsBlockingReload = false
    /// Set by a hard reload until the tab stops loading, so its progress shows in red.
    var isHardReloading = false
    var favicon: NSImage? { didSet { if !keepsSavedIcon { faviconData = FaviconSnapshot.encode(favicon) } } }
    private(set) var faviconData: Data?
    var darkFavicon: NSImage? { didSet { if !keepsSavedIcon { darkFaviconData = FaviconSnapshot.encode(darkFavicon) } } }
    private var keepsSavedIcon = false
    /// An icon with the PNG already kept for it, as the suggestion icons have.
    func setFavicon(_ image: NSImage, data: Data, dark: Bool = false) {
        keepsSavedIcon = true; defer { keepsSavedIcon = false }
        if dark { darkFavicon = image; darkFaviconData = data } else { favicon = image; faviconData = data }
    }
    private(set) var darkFaviconData: Data?
    func favicon(for theme: RiseTheme) -> NSImage? { theme == .dark ? darkFavicon ?? favicon : favicon }
    var iconOrigin: String?
    var iconTask: URLSessionDataTask?
    var thumbnail: NSImage?
    /// The address a background picture for the tab switcher was last tried at, so a page that
    /// can't be pictured isn't tried again until it goes somewhere else.
    var backgroundPictureURL: URL?
    /// The page was loaded out of sight for its picture: muted and paused until it's first shown.
    var heldSinceBackgroundPicture = false
    /// The saved back/forward history, restored when the tab first loads its saved page.
    private var restoredState: (url: String, data: Data)?
    private var restoredHistory: (url: String, history: TabNavigationHistory)?
    static let maximumSessionState = 2_000_000
    var onThumbnailChange: (() -> Void)?
    var onFullscreenChange: (() -> Void)?
    /// The page finished loading, as after a reload.
    var onLoadFinished: (() -> Void)?
    private var wasLoading = false
    /// The engine's own fullscreen has the page in its window.
    var isInNativeFullscreen: Bool { page.isInNativeFullscreen }
    private var thumbnailCaptureInFlight = false
    /// Makes each tab's page: Chromium's, or a blank one where the engine isn't running, as in unit tests.
    static func makePage() -> WebPage { ChromiumEngine.isRunning ? ChromiumPage() : BlankPage() }
    /// What a tab restored from a session, or put to sleep, holds until it loads: a stand-in that
    /// costs no renderer process (`DormantPage`). Without the engine, as in unit tests, a blank page.
    static func makeWaitingPage() -> WebPage { ChromiumEngine.isRunning ? DormantPage() : BlankPage() }
    /// The tab took a real page in its stand-in's place, which needs Rise's scripts and handlers.
    var onWake: (() -> Void)?
    var isDormant: Bool { page is DormantPage }
    /// Given `page`, the tab shows that page, as a window a site opened. A tab restored from a
    /// session waits with a stand-in until it's shown or loaded; a new one gets its page at once.
    init(saved: SavedTab? = nil, page: WebPage? = nil) {
        id = saved?.id ?? UUID(); customTitle = saved?.customTitle; title = saved?.customTitle ?? saved?.title ?? "New Tab"
        pinned = saved?.pinned ?? false; developer = saved?.developer ?? false
        use = saved?.use ?? TabUse(lastUsed: Date())
        requestedURL = saved.flatMap { URL(string: $0.url) }
        visitedAddress = BrowsingHistory.key(requestedURL)
        if let saved, let data = saved.sessionState { restoredState = (saved.url, data) }
        if let saved, let history = saved.navigationHistory?.validated(for: saved.url) { restoredHistory = (saved.url, history) }
        self.page = page ?? (saved != nil ? Self.makeWaitingPage() : Self.makePage())
        super.init()
        if let data = saved?.faviconData,
           let origin = saved?.faviconOrigin, origin == SitePermissions.origin(requestedURL),
           let image = FaviconSnapshot.decode(data) {
            keepsSavedIcon = true; defer { keepsSavedIcon = false }
            iconOrigin = origin; favicon = image; faviconData = data
            if let darkData = saved?.darkFaviconData, let darkImage = FaviconSnapshot.decode(darkData) {
                darkFavicon = darkImage; darkFaviconData = darkData
            }
        }
        observePage()
    }
    private func observePage() {
        (page as? DormantPage)?.onLoad = { [weak self] url in self?.load(url) }
        page.onChange = { [weak self] change in
            guard let self else { return }
            let report = { (progressOnly: Bool) in
                let outer = self.reportingPageChange
                self.reportingPageChange = (progressOnly, ()); defer { self.reportingPageChange = outer }
                self.onChange?()
            }
            switch change {
            case .title, .url: changed(report: { report(false) })
            case .loading:
                // Checked when the change arrives, so the end of a load the hard reload replaced doesn't clear it.
                if !isLoading { isHardReloading = false }
                let finished = wasLoading && !isLoading
                wasLoading = isLoading
                report(false)
                if finished { onLoadFinished?() }
            case .fullscreen: onFullscreenChange?()
            case .progress: report(true)
            case .navigation, .audio: report(false)
            }
        }
    }
    /// Trades live pages with `other`: each takes the other's page with its history, title and
    /// icon, and nothing loads. The tab itself keeps its id, place, pin and name.
    func exchangePages(with other: BrowserTab) {
        swap(&page, &other.page)
        swap(&title, &other.title); swap(&requestedURL, &other.requestedURL); swap(&visitedAddress, &other.visitedAddress)
        swap(&favicon, &other.favicon); swap(&darkFavicon, &other.darkFavicon); swap(&iconOrigin, &other.iconOrigin)
        swap(&thumbnail, &other.thumbnail); swap(&hasAttemptedNavigation, &other.hasAttemptedNavigation)
        swap(&isAudioMuted, &other.isAudioMuted)
        swap(&backgroundPictureURL, &other.backgroundPictureURL); swap(&heldSinceBackgroundPicture, &other.heldSinceBackgroundPicture)
        swap(&restoredState, &other.restoredState)
        swap(&restoredHistory, &other.restoredHistory)
        // An icon still on its way belongs to the page that's gone; fetch the new page's again.
        for tab in [self, other] {
            tab.iconTask?.cancel(); tab.iconTask = nil
            if tab.favicon == nil { tab.iconOrigin = nil }
        }
        observePage(); other.observePage()
        changed(); other.changed()
    }
    var url: URL? { page.url ?? requestedURL }
    private var pullRequestAt: (url: URL?, request: PullRequest?)?
    /// The pull or merge request the tab shows, read from its address once per address: the
    /// sidebar asks for every tab at every update.
    var pullRequest: PullRequest? {
        let url = url
        if let pullRequestAt, pullRequestAt.url == url { return pullRequestAt.request }
        let request = PullRequest(url: url); pullRequestAt = (url, request); return request
    }
    var saved: SavedTab {
        let history = navigationHistory
        let savedURL = history?.current.flatMap { URL(string: $0.url) } ?? url
        let origin = SitePermissions.origin(savedURL)
        let data = origin != nil && origin == iconOrigin ? faviconData : nil
        return SavedTab(id: id, url: savedURL?.absoluteString ?? "about:blank", title: title, pinned: pinned, developer: developer, customTitle: customTitle,
                        faviconData: data, darkFaviconData: data == nil ? nil : darkFaviconData,
                        faviconOrigin: data == nil ? nil : origin, sessionState: sessionState, navigationHistory: history, use: use)
    }
    /// The live history once the page has loaded; until then, the history it was restored with.
    var sessionState: Data? {
        guard backPages.isEmpty, forwardPages.isEmpty, archivedBackEntries.isEmpty else { return nil }
        guard page.url != nil else { return restoredState?.data }
        guard let data = page.sessionState, data.count <= Self.maximumSessionState else { return nil }
        return data
    }
    var navigationHistory: TabNavigationHistory? {
        guard let current = page.navigationHistory ?? restoredHistory?.history else { return nil }
        let archived = archivedBackEntries.isEmpty ? [] : [TabNavigationHistory(entries: archivedBackEntries, index: archivedBackEntries.count-1)]
        return TabNavigationHistory.combining(back: archived + backPages.compactMap(\.navigationHistory), current: current,
                                             forward: forwardPages.reversed().compactMap(\.navigationHistory))
    }
    func rename(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        customTitle = value; title = value; onChange?()
    }
    /// Puts a real page where the stand-in is, in its place among its siblings and at its frame, as
    /// a Peek's card or the page area holds it, before it loads anything.
    func wake() {
        guard let dormant = page as? DormantPage else { return }
        let next = Self.makePage()
        dormant.onChange = nil; dormant.onLoad = nil
        let view = dormant.view
        if let superview = view.superview {
            let focused = view.window?.firstResponder === view
            next.view.frame = view.frame; next.view.autoresizingMask = view.autoresizingMask
            superview.replaceSubview(view, with: next.view)
            if focused { next.view.window?.makeFirstResponder(next.view) }
        }
        page = next
        // Under a Peek, it stays out of the pointer's way as the stand-in was.
        page.isCovered = dormant.isCovered
        if isAudioMuted { page.setAudioMuted(true) }
        observePage()
        onWake?()
    }
    func load(_ url: URL) {
        wake()
        hasAttemptedNavigation = true
        requestedURL = url
        if AddressResolver.isLocal(url) { developer = true }
        // A restored tab reopens its saved page with its back/forward history.
        let state = restoredState; restoredState = nil
        let history = restoredHistory
        if history?.url != url.absoluteString { restoredHistory = nil }
        defer { onChange?() }
        if let state, state.url == url.absoluteString, page.restoreSession(state.data, fallback: url) { return }
        if let history, history.url == url.absoluteString, page.restoreNavigationHistory(history.history, fallback: url) { return }
        page.load(url)
    }
    /// When the tab was last on screen, for letting it sleep.
    var lastSeen = Date()
    /// When it was last really used, for archiving it. Starts now for a tab with no record of that.
    var use: TabUse
    /// Whether the page had something part-filled when it was left, for when it's since been frozen
    /// and can't be asked. A frozen page can't have changed since.
    var leftWithEdits = false
    /// Whether `sleep()` can let the page go and bring it back as it was: it has loaded, holds no
    /// earlier pages, and the engine can give its history.
    var canSleep: Bool {
        page.url != nil && backPages.isEmpty && forwardPages.isEmpty && archivedBackEntries.isEmpty && sessionState != nil
    }
    /// Lets the page go, keeping its history, title, icon and picture; shown again, it comes back
    /// from its history as a tab restored at launch does. Returns the page let go.
    func sleep() -> WebPage? {
        (page as? ChromiumPage)?.forgetSavedState()
        guard canSleep, let state = sessionState, let url = page.url else { return nil }
        let old = page
        restoredState = (url.absoluteString, state); restoredHistory = navigationHistory.map { (url.absoluteString, $0) }
        requestedURL = url; hasAttemptedNavigation = false
        backgroundPictureURL = nil; heldSinceBackgroundPicture = false; leftWithEdits = false
        old.onChange = nil; old.stopLoading(); old.view.removeFromSuperview()
        page = Self.makeWaitingPage()
        if isAudioMuted { page.setAudioMuted(true) }
        observePage()
        return old
    }
    func setAudioMuted(_ muted: Bool) {
        guard page.setAudioMuted(muted) else { return }
        isAudioMuted = muted; onChange?()
    }
    func cancelLoad() { page.stopLoading() }
    func changed() { changed(report: { self.onChange?() }) }
    private func changed(report: () -> Void) {
        if AddressResolver.isLocal(url) { developer = true }
        if let customTitle { title = customTitle }
        else if let value = page.title, !value.isEmpty {
            title = hidesNotificationCounts ? TitleNotificationCount.removing(from: value, url: url) : value
        }
        else if let url, url.absoluteString != "about:blank" { title = AddressResolver.displayHost(url) }
        updateIcon(); report()
    }
    func captureThumbnail() {
        guard !thumbnailCaptureInFlight, page.view.bounds.width > 0, page.view.bounds.height > 0 else { return }
        thumbnailCaptureInFlight = true
        let capturedURL = url, page = page
        Task { [weak self] in
            let image = await page.snapshot(width: 320)
            var picture: NSImage?
            if let image { picture = await Self.scaledPicture(image) }
            guard let self else { return }
            self.thumbnailCaptureInFlight = false
            guard self.url == capturedURL, let picture, picture.size.width > 0 else { return }
            self.thumbnail = picture; self.onThumbnailChange?()
        }
    }
    /// The page at the width pictures are kept at (`TabPictureStore.pixelWidth`), made off the main thread.
    static func scaledPicture(_ image: NSImage) async -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = image.size
        guard cgImage.width > TabPictureStore.pixelWidth else { return image }
        nonisolated(unsafe) let source = cgImage
        let scaled: CGImage? = await Task.detached(priority: .utility) {
            let width = TabPictureStore.pixelWidth, height = max(1, Int((Double(source.height)*Double(width)/Double(source.width)).rounded()))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()
        }.value
        return scaled.map { NSImage(cgImage: $0, size: size) }
    }
    func updateIcon() {
        let origin = SitePermissions.origin(url)
        guard origin != iconOrigin else { return }
        iconTask?.cancel(); iconTask = nil; iconOrigin = origin; favicon = nil; darkFavicon = nil
        guard let url, let origin, !AddressResolver.isLocal(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.user = nil; parts.password = nil; parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil
        guard let iconURL = parts.url else { return }
        iconTask = URLSession.shared.dataTask(with: iconURL) { [weak self] data, response, _ in
            guard let data, data.count < 1_000_000, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            Task { @MainActor in
                guard let self, self.iconTask != nil, self.iconOrigin == origin, let image = FaviconImage.decode(data, dark: false), image.isValid else { return }
                self.favicon = image; self.iconTask = nil; self.onChange?()
            }
        }
        iconTask?.resume()
    }
    deinit { iconTask?.cancel() }
}
