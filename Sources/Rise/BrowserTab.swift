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
    var title: String
    var customTitle: String?
    /// Leaves YouTube's notification count out of the title.
    var hidesNotificationCounts = true
    /// Shows a merge request's project under its title in the tab list.
    var showsRepositorySubtitle = true
    var pinned: Bool
    var developer: Bool
    var requestedURL: URL?
    /// The tab whose page opened this one in a new tab and brought the user here. Back, once
    /// this tab's own history runs out, closes it and returns there.
    var returnsTo: UUID?
    /// Whether the page is making sound.
    var isPlayingAudio: Bool { page.isPlayingAudio }
    /// The page keeps playing, but without sound.
    private(set) var isAudioMuted = false
    var onChange: (() -> Void)?
    private(set) var hasAttemptedNavigation = false
    var isLoading: Bool { page.isLoading }
    var needsBlockingReload = false
    /// Set by a hard reload until the tab stops loading, so its progress shows in red.
    var isHardReloading = false
    var favicon: NSImage? { didSet { faviconData = FaviconSnapshot.encode(favicon) } }
    private(set) var faviconData: Data?
    var darkFavicon: NSImage? { didSet { darkFaviconData = FaviconSnapshot.encode(darkFavicon) } }
    private(set) var darkFaviconData: Data?
    func favicon(for theme: RiseTheme) -> NSImage? { theme == .dark ? darkFavicon ?? favicon : favicon }
    var iconOrigin: String?
    var iconTask: URLSessionDataTask?
    var thumbnail: NSImage?
    /// The saved back/forward history, restored when the tab first loads its saved page.
    private var restoredState: (url: String, data: Data)?
    static let maximumSessionState = 2_000_000
    var onThumbnailChange: (() -> Void)?
    var onFullscreenChange: (() -> Void)?
    /// The engine's own fullscreen has the page in its window.
    var isInNativeFullscreen: Bool { page.isInNativeFullscreen }
    private var thumbnailCaptureInFlight = false
    /// Makes each tab's page: Chromium's, or a blank one where the engine isn't running, as in unit tests.
    static func makePage() -> WebPage { ChromiumEngine.isRunning ? ChromiumPage() : BlankPage() }
    /// Given `page`, the tab shows that page, as a window a site opened.
    init(saved: SavedTab? = nil, page: WebPage? = nil) {
        id = saved?.id ?? UUID(); customTitle = saved?.customTitle; title = saved?.customTitle ?? saved?.title ?? "New Tab"
        pinned = saved?.pinned ?? false; developer = saved?.developer ?? false
        requestedURL = saved.flatMap { URL(string: $0.url) }
        if let saved, let data = saved.sessionState { restoredState = (saved.url, data) }
        self.page = page ?? Self.makePage()
        super.init()
        if let data = saved?.faviconData, data.count <= FaviconSnapshot.maximumBytes,
           let origin = saved?.faviconOrigin, origin == SitePermissions.origin(requestedURL),
           let image = NSImage(data: data), image.isValid {
            iconOrigin = origin; favicon = image; faviconData = data
            if let darkData = saved?.darkFaviconData, darkData.count <= FaviconSnapshot.maximumBytes,
               let darkImage = NSImage(data: darkData), darkImage.isValid {
                darkFavicon = darkImage; darkFaviconData = darkData
            }
        }
        observePage()
    }
    private func observePage() {
        page.onChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case .title, .url: changed()
            case .loading:
                // Checked when the change arrives, so the end of a load the hard reload replaced doesn't clear it.
                if !isLoading { isHardReloading = false }
                onChange?()
            case .fullscreen: onFullscreenChange?()
            case .progress, .navigation, .audio: onChange?()
            }
        }
    }
    /// Trades live pages with `other`: each takes the other's page with its history, title and
    /// icon, and nothing loads. The tab itself keeps its id, place, pin and name.
    func exchangePages(with other: BrowserTab) {
        swap(&page, &other.page)
        swap(&title, &other.title); swap(&requestedURL, &other.requestedURL)
        swap(&favicon, &other.favicon); swap(&darkFavicon, &other.darkFavicon); swap(&iconOrigin, &other.iconOrigin)
        swap(&thumbnail, &other.thumbnail); swap(&hasAttemptedNavigation, &other.hasAttemptedNavigation)
        swap(&isAudioMuted, &other.isAudioMuted)
        restoredState = nil; other.restoredState = nil
        // An icon still on its way belongs to the page that's gone; fetch the new page's again.
        for tab in [self, other] {
            tab.iconTask?.cancel(); tab.iconTask = nil
            if tab.favicon == nil { tab.iconOrigin = nil }
        }
        observePage(); other.observePage()
        changed(); other.changed()
    }
    var url: URL? { page.url ?? requestedURL }
    var saved: SavedTab {
        let origin = SitePermissions.origin(url)
        let data = origin != nil && origin == iconOrigin ? faviconData : nil
        return SavedTab(id: id, url: url?.absoluteString ?? "about:blank", title: title, pinned: pinned, developer: developer, customTitle: customTitle,
                        faviconData: data, darkFaviconData: data == nil ? nil : darkFaviconData,
                        faviconOrigin: data == nil ? nil : origin, sessionState: sessionState)
    }
    /// The live history once the page has loaded; until then, the history it was restored with.
    var sessionState: Data? {
        guard page.url != nil else { return restoredState?.data }
        guard let data = page.sessionState, data.count <= Self.maximumSessionState else { return nil }
        return data
    }
    func rename(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        customTitle = value; title = value; onChange?()
    }
    func load(_ url: URL) {
        hasAttemptedNavigation = true
        requestedURL = url
        if AddressResolver.isLocal(url) { developer = true }
        // A restored tab reopens its saved page with its back/forward history.
        let state = restoredState; restoredState = nil
        defer { onChange?() }
        if let state, state.url == url.absoluteString, page.restoreSession(state.data, fallback: url) { return }
        page.load(url)
    }
    func setAudioMuted(_ muted: Bool) {
        guard page.setAudioMuted(muted) else { return }
        isAudioMuted = muted; onChange?()
    }
    func cancelLoad() { page.stopLoading() }
    func changed() {
        if AddressResolver.isLocal(url) { developer = true }
        if let customTitle { title = customTitle }
        else if let value = page.title, !value.isEmpty {
            title = hidesNotificationCounts ? TitleNotificationCount.removing(from: value, url: url) : value
        }
        else if let url, url.absoluteString != "about:blank" { title = AddressResolver.displayHost(url) }
        updateIcon(); onChange?()
    }
    func captureThumbnail() {
        guard !thumbnailCaptureInFlight, page.view.bounds.width > 0, page.view.bounds.height > 0 else { return }
        thumbnailCaptureInFlight = true
        let capturedURL = url, page = page
        Task { [weak self] in
            let image = await page.snapshot(width: 320)
            guard let self else { return }
            self.thumbnailCaptureInFlight = false
            guard self.url == capturedURL, let image, image.size.width > 0 else { return }
            self.thumbnail = image; self.onThumbnailChange?()
        }
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
                guard let self, self.iconTask != nil, self.iconOrigin == origin, let image = NSImage(data: data), image.isValid else { return }
                self.favicon = image; self.iconTask = nil; self.onChange?()
            }
        }
        iconTask?.resume()
    }
    deinit { iconTask?.cancel() }
}
