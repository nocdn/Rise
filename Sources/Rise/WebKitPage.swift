import AppKit
import WebKit

/// A page drawn by WebKit.
@MainActor final class WebKitPage: WebPage {
    let webView: WKWebView
    var engine: WebEngine { .webKit }
    var view: NSView { webView }
    var onChange: ((WebPageChange) -> Void)?
    // WebKit reports hovers, new windows and its menu through Rise's delegates and page scripts.
    var onHoverLink: ((URL?) -> Void)?
    var onOpenElsewhere: ((URL, Bool) -> Bool)?
    var onOpenInPeek: ((URL) -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var audioObserver: PrivateKeyObserver?
    private(set) var isPlayingAudio = false

    init(configuration: WKWebViewConfiguration? = nil) {
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
        webView.isInspectable = true; webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = NSColor(hex: 0xFDFCFC)
        observe()
    }

    private func observe() {
        audioObserver = PrivateKeyObserver(webView, key: Self.playingAudioKey) { [weak self] in Task { @MainActor in self?.audioChanged() } }
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?(.title) } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?(.url) } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?(.progress) } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?(.loading) } },
            webView.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?(.fullscreen) } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?(.navigation) } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.onChange?(.navigation) } },
        ]
    }

    var url: URL? { webView.url }
    var title: String? { webView.title }
    var isLoading: Bool { webView.isLoading }
    var estimatedProgress: Double { webView.estimatedProgress }
    var canGoBack: Bool { webView.canGoBack }
    var canGoForward: Bool { webView.canGoForward }
    var isInNativeFullscreen: Bool { webView.fullscreenState != .notInFullscreen }
    var isMagnified: Bool { webView.magnification != 1 }
    var isCovered: Bool {
        get { (webView as? LinkCursorWebView)?.isCovered ?? false }
        set { (webView as? LinkCursorWebView)?.isCovered = newValue }
    }
    var zoom: CGFloat {
        get { webView.pageZoom }
        set { webView.pageZoom = newValue }
    }

    func load(_ url: URL) {
        if url.isFileURL { webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { webView.load(URLRequest(url: url)) }
    }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func reloadIgnoringCache() { webView.reloadFromOrigin() }
    func stopLoading() { webView.stopLoading() }

    private static let playingAudioKey = "_isPlayingAudio"
    private func audioChanged() {
        let playing = webView.responds(to: NSSelectorFromString(Self.playingAudioKey)) && webView.value(forKey: Self.playingAudioKey) as? Bool == true
        guard playing != isPlayingAudio else { return }
        isPlayingAudio = playing; onChange?(.audio)
    }
    @discardableResult func setAudioMuted(_ muted: Bool) -> Bool {
        // _WKMediaMutedState: 1 mutes audio and leaves capture devices alone.
        let selector = NSSelectorFromString("_setPageMuted:")
        guard webView.responds(to: selector) else { return false }
        typealias SetPageMuted = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(webView.method(for: selector), to: SetPageMuted.self)(webView, selector, muted ? 1 : 0)
        return true
    }

    var sessionState: Data? { webView.interactionState as? Data }
    func restoreSession(_ data: Data, fallback url: URL) -> Bool {
        webView.interactionState = data
        return webView.backForwardList.currentItem != nil
    }
    var showsLiveLayers: Bool { false }
    func liveLayer(showing rect: NSRect?) -> CALayer? { nil }
    func snapshot(rect: NSRect) async -> NSImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect; configuration.afterScreenUpdates = false
        return try? await webView.takeSnapshot(configuration: configuration)
    }
    func evaluate(_ body: String, arguments: [String: Any], world: String?) async -> Any? {
        try? await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: world.map { .world(name: $0) } ?? .defaultClient)
    }
    func addScriptToEveryDocument(_ source: String, world: String) {
        webView.configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                                               forMainFrameOnly: true, in: .world(name: world)))
    }
    func setMediaSuspended(_ suspended: Bool) { webView.setAllMediaPlaybackSuspended(suspended) }
    func setTheme(_ appearance: NSAppearance, background: NSColor) {
        if webView.appearance?.name != appearance.name { webView.appearance = appearance }
        if webView.underPageBackgroundColor != background { webView.underPageBackgroundColor = background }
    }

    // Pages a page opens share its user content, so what's there is kept on the controller
    // itself (a table keyed by it could hand a later controller at the same address its record).
    private static var installedKey: UInt8 = 0
    /// Whether `key` is new to this page's user content, noting it if so.
    private func install(_ key: String) -> Bool {
        let controller = webView.configuration.userContentController
        let keys = objc_getAssociatedObject(controller, &Self.installedKey) as? NSMutableSet ?? NSMutableSet()
        objc_setAssociatedObject(controller, &Self.installedKey, keys, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guard !keys.contains(key) else { return false }
        keys.add(key); return true
    }
    private static func contentWorld(_ world: ScriptWorld) -> WKContentWorld {
        world.name.map { .world(name: $0) } ?? .page
    }
    static func message(_ message: WKScriptMessage) -> PageMessage {
        let frame = PageFrame(isMain: message.frameInfo.isMainFrame, origin: SitePermissions.origin(message.frameInfo.securityOrigin),
                              handle: message.frameInfo)
        return PageMessage(body: message.body, frame: frame, page: message.webView.flatMap(WebKitPage.page(of:)))
    }
    /// Each web view's page, kept on the web view, which a page owns.
    private final class PageLink { weak var page: WebKitPage?; init(_ page: WebKitPage) { self.page = page } }
    private static var pageKey: UInt8 = 0
    private func linkPage() {
        guard Self.page(of: webView) !== self else { return }
        objc_setAssociatedObject(webView, &Self.pageKey, PageLink(self), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    static func page(of webView: WKWebView) -> WebKitPage? { (objc_getAssociatedObject(webView, &pageKey) as? PageLink)?.page }
    func addMessageHandler(_ name: String, world: ScriptWorld, receive: @escaping (PageMessage) -> Void) {
        linkPage()
        guard install("handler:\(name)") else { return }
        webView.configuration.userContentController.add(ScriptHandler(receive), contentWorld: Self.contentWorld(world), name: name)
    }
    func addMessageHandler(_ name: String, world: ScriptWorld, replying: @escaping (PageMessage, @escaping (Any?, String?) -> Void) -> Void) {
        linkPage()
        guard install("handler:\(name)") else { return }
        webView.configuration.userContentController.addScriptMessageHandler(ReplyingScriptHandler(replying), contentWorld: Self.contentWorld(world), name: name)
    }
    func addUserScript(_ source: String, world: ScriptWorld, mainFrameOnly: Bool, handlers: [String]) {
        linkPage()
        guard install("script:\(source.hashValue):\(world)") else { return }
        let wrapped = "(() => {\nconst riseHandlers = globalThis.webkit?.messageHandlers ?? {};\n\(source)\n})();"
        webView.configuration.userContentController.addUserScript(WKUserScript(source: wrapped, injectionTime: .atDocumentStart,
                                                                               forMainFrameOnly: mainFrameOnly, in: Self.contentWorld(world)))
    }
    func evaluate(_ body: String, arguments: [String: Any], in frame: PageFrame?, world: ScriptWorld,
                  completion: @escaping (Result<Any?, Error>) -> Void) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: frame?.handle as? WKFrameInfo, in: Self.contentWorld(world)) { completion($0.map { $0 }) }
    }
    func capture(_ format: PageCaptureFormat) async -> Data? {
        // WebKit's PDF of the page is all of it, as it shows, on one page.
        let pdf: Data? = await withCheckedContinuation { continuation in
            webView.createPDF(configuration: WKPDFConfiguration()) { continuation.resume(returning: try? $0.get()) }
        }
        guard let pdf, format == .jpeg else { return pdf }
        guard let page = NSPDFImageRep(data: pdf) else { return nil }
        let scale = webView.window?.backingScaleFactor ?? 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(page.bounds.width*scale), pixelsHigh: Int(page.bounds.height*scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = page.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill(); NSRect(origin: .zero, size: page.bounds.size).fill()
        page.draw(in: NSRect(origin: .zero, size: page.bounds.size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
    func snapshot(width: CGFloat?) async -> NSImage? {
        let configuration = WKSnapshotConfiguration()
        if let width { configuration.snapshotWidth = NSNumber(value: Double(width)) }
        configuration.afterScreenUpdates = false
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in continuation.resume(returning: image) }
        }
    }
}
