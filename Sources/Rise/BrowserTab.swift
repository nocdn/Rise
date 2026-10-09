import AppKit
import WebKit
import RiseCore

@MainActor final class BrowserTab: NSObject {
    let id: UUID
    let webView: WKWebView
    var title: String
    var customTitle: String?
    /// Leaves YouTube's notification count out of the title.
    var hidesYouTubeNotificationCount = true
    /// Shows a merge request's project under its title in the tab list.
    var showsRepositorySubtitle = true
    var pinned: Bool
    var developer: Bool
    var requestedURL: URL?
    var observations: [NSKeyValueObservation] = []
    /// Whether the page is making sound. WebKit only reports this privately.
    private(set) var isPlayingAudio = false
    /// The page keeps playing, but without sound.
    private(set) var isAudioMuted = false
    private var audioObserver: PrivateKeyObserver?
    var onChange: (() -> Void)?
    var prepareForLoad: ((WKWebView) async throws -> Void)?
    var onLoadError: ((Error) -> Void)?
    private var navigationTask: Task<Void, Never>?
    private var loadGeneration = 0
    private(set) var hasAttemptedNavigation = false
    var isPreparingNavigation: Bool { navigationTask != nil }
    var isLoading: Bool { isPreparingNavigation || webView.isLoading }
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
    /// WebKit's own fullscreen has the web view in its window.
    var isInNativeFullscreen: Bool { webView.fullscreenState != .notInFullscreen }
    private var thumbnailCaptureInFlight = false
    init(saved: SavedTab? = nil, configuration: WKWebViewConfiguration? = nil) {
        id = saved?.id ?? UUID(); customTitle = saved?.customTitle; title = saved?.customTitle ?? saved?.title ?? "New Tab"
        pinned = saved?.pinned ?? false; developer = saved?.developer ?? false
        requestedURL = saved.flatMap { URL(string: $0.url) }
        if let saved, let data = saved.sessionState { restoredState = (saved.url, data) }
        let configuration = configuration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = BrowserIdentity.applicationName
        // Simulated fullscreen falls back to WebKit's, and is off unless chosen.
        configuration.preferences.isElementFullscreenEnabled = true
        // WebKit's own picture in picture is off unless asked for privately. Encrypted video
        // floats there, since Rise's window can't draw it, and sites' own buttons use it.
        let allowPictureInPicture = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        if configuration.preferences.responds(to: allowPictureInPicture) {
            typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(configuration.preferences.method(for: allowPictureInPicture), to: SetBool.self)(configuration.preferences, allowPictureInPicture, true)
        }
        webView = LinkCursorWebView(frame: .zero, configuration: configuration)
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
        webView.isInspectable = true; webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = NSColor(hex: 0xFDFCFC)
        audioObserver = PrivateKeyObserver(webView, key: Self.playingAudioKey) { [weak self] in Task { @MainActor in self?.audioChanged() } }
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } })
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                // Checked when the task runs, so the end of a load the hard reload replaced doesn't clear it.
                if self?.isLoading == false { self?.isHardReloading = false }
                self?.onChange?()
            }
        })
        observations.append(webView.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onFullscreenChange?() } })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } })
    }
    var url: URL? { webView.url ?? requestedURL }
    var saved: SavedTab {
        let origin = SitePermissions.origin(url)
        let data = origin != nil && origin == iconOrigin ? faviconData : nil
        return SavedTab(id: id, url: url?.absoluteString ?? "about:blank", title: title, pinned: pinned, developer: developer, customTitle: customTitle,
                        faviconData: data, darkFaviconData: data == nil ? nil : darkFaviconData,
                        faviconOrigin: data == nil ? nil : origin, sessionState: sessionState)
    }
    /// The live history once the page has loaded; until then, the history it was restored with.
    var sessionState: Data? {
        guard webView.url != nil else { return restoredState?.data }
        guard let data = webView.interactionState as? Data, data.count <= Self.maximumSessionState else { return nil }
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
        loadGeneration += 1; let generation = loadGeneration
        navigationTask?.cancel()
        navigationTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.prepareForLoad?(self.webView)
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.navigationTask = nil
                // A restored tab reopens its saved page with its back/forward history.
                if let state = self.restoredState, state.url == url.absoluteString {
                    self.restoredState = nil
                    self.webView.interactionState = state.data
                    if self.webView.backForwardList.currentItem != nil { return }
                }
                self.restoredState = nil
                if url.isFileURL { self.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
                else { self.webView.load(URLRequest(url: url)) }
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.navigationTask = nil; self.onLoadError?(error)
            }
        }
        onChange?()
    }
    private static let playingAudioKey = "_isPlayingAudio"
    private func audioChanged() {
        let playing = webView.responds(to: NSSelectorFromString(Self.playingAudioKey)) && webView.value(forKey: Self.playingAudioKey) as? Bool == true
        guard playing != isPlayingAudio else { return }
        isPlayingAudio = playing; onChange?()
    }
    func setAudioMuted(_ muted: Bool) {
        // _WKMediaMutedState: 1 mutes audio and leaves capture devices alone.
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return }
        typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: selector), to: SetPageMuted.self)(webView, selector, muted ? 1 : 0)
        isAudioMuted = muted; onChange?()
    }
    func cancelLoad() { loadGeneration += 1; navigationTask?.cancel(); navigationTask = nil; webView.stopLoading() }
    func changed() {
        if AddressResolver.isLocal(url) { developer = true }
        if let customTitle { title = customTitle }
        else if let value = webView.title, !value.isEmpty {
            title = hidesYouTubeNotificationCount ? YouTubeVideoPage.removingNotificationCount(from: value, url: url) : value
        }
        else if let url, url.absoluteString != "about:blank" { title = AddressResolver.displayHost(url) }
        updateIcon(); onChange?()
    }
    func captureThumbnail() {
        guard !thumbnailCaptureInFlight, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        thumbnailCaptureInFlight = true
        let capturedURL = url
        let snapshot = WKSnapshotConfiguration()
        snapshot.snapshotWidth = 320; snapshot.afterScreenUpdates = false
        webView.takeSnapshot(with: snapshot) { [weak self] image, _ in
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
    deinit { navigationTask?.cancel(); iconTask?.cancel() }
}
