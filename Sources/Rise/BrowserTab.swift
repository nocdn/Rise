import AppKit
import WebKit
import RiseCore

@MainActor final class BrowserTab: NSObject {
    let id: UUID
    let webView: WKWebView
    var title: String
    var customTitle: String?
    var pinned: Bool
    var developer: Bool
    var requestedURL: URL?
    var observations: [NSKeyValueObservation] = []
    var onChange: (() -> Void)?
    var prepareForLoad: ((WKWebView) async throws -> Void)?
    var onLoadError: ((Error) -> Void)?
    private var navigationTask: Task<Void, Never>?
    private var loadGeneration = 0
    private(set) var hasAttemptedNavigation = false
    var isPreparingNavigation: Bool { navigationTask != nil }
    var isLoading: Bool { isPreparingNavigation || webView.isLoading }
    var needsBlockingReload = false
    var favicon: NSImage? { didSet { faviconData = FaviconSnapshot.encode(favicon) } }
    private(set) var faviconData: Data?
    var iconOrigin: String?
    var iconTask: URLSessionDataTask?
    var thumbnail: NSImage?
    var onThumbnailChange: (() -> Void)?
    private var thumbnailCaptureInFlight = false
    init(saved: SavedTab? = nil, configuration: WKWebViewConfiguration? = nil) {
        id = saved?.id ?? UUID(); customTitle = saved?.customTitle; title = saved?.customTitle ?? saved?.title ?? "New Tab"
        pinned = saved?.pinned ?? false; developer = saved?.developer ?? false
        requestedURL = saved.flatMap { URL(string: $0.url) }
        let configuration = configuration ?? WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        if let data = saved?.faviconData, data.count <= FaviconSnapshot.maximumBytes,
           let origin = saved?.faviconOrigin, origin == SitePermissions.origin(requestedURL),
           let image = NSImage(data: data), image.isValid {
            iconOrigin = origin; favicon = image; faviconData = data
        }
        webView.isInspectable = true; webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = NSColor(hex: 0xFDFCFC)
        observations.append(webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } })
        observations.append(webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.changed() } })
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } })
        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } })
        observations.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } })
        observations.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?() } })
    }
    var url: URL? { webView.url ?? requestedURL }
    var saved: SavedTab {
        let origin = SitePermissions.origin(url)
        let data = origin != nil && origin == iconOrigin ? faviconData : nil
        return SavedTab(id: id, url: url?.absoluteString ?? "about:blank", title: title, pinned: pinned, developer: developer, customTitle: customTitle,
                        faviconData: data, faviconOrigin: data == nil ? nil : origin)
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
                if url.isFileURL { self.webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
                else { self.webView.load(URLRequest(url: url)) }
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.navigationTask = nil; self.onLoadError?(error)
            }
        }
        onChange?()
    }
    func cancelLoad() { loadGeneration += 1; navigationTask?.cancel(); navigationTask = nil; webView.stopLoading() }
    func changed() {
        if AddressResolver.isLocal(url) { developer = true }
        if let customTitle { title = customTitle }
        else if let value = webView.title, !value.isEmpty { title = value }
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
        iconTask?.cancel(); iconTask = nil; iconOrigin = origin; favicon = nil
        guard let url, let origin, !AddressResolver.isLocal(url),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        parts.user = nil; parts.password = nil; parts.path = "/favicon.ico"; parts.query = nil; parts.fragment = nil
        guard let iconURL = parts.url else { return }
        iconTask = URLSession.shared.dataTask(with: iconURL) { [weak self] data, response, _ in
            guard let data, data.count < 1_000_000, (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            Task { @MainActor in
                guard let self, self.iconOrigin == origin, let image = NSImage(data: data), image.isValid else { return }
                self.favicon = image; self.iconTask = nil; self.onChange?()
            }
        }
        iconTask?.resume()
    }
    deinit { navigationTask?.cancel(); iconTask?.cancel() }
}
