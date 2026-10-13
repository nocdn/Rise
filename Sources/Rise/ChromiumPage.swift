import AppKit
#if RISE_CHROMIUM
import RiseChromium
#endif

/// A separate place for the session, history and website data, for trying Rise out (with
/// another engine, say) without touching the everyday ones: `RISE_PROFILE_DIR=<folder>`.
enum RiseProfile {
    static var directory: URL? { ProcessInfo.processInfo.environment["RISE_PROFILE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

/// Chrome's own pages Rise shows as its own: rise://settings is chrome://settings, with every page
/// under it. Only Rise opens them; to sites they're another app's addresses.
enum RisePages {
    static let hosts: Set<String> = ["settings"]
    static let settings = URL(string: "rise://settings")!
    /// The Chrome page to load for a Rise address. Settings open on their first section Rise shows,
    /// as Chrome's first, You and Google, isn't one.
    static func page(for url: URL) -> URL {
        guard var page = swap(url, from: "rise", to: "chrome") else { return url }
        if page.host == "settings", ["", "/"].contains(page.path) { page = URL(string: "chrome://settings/privacy")! }
        return page
    }
    /// The Rise address to show for a Chrome page.
    static func address(for url: URL?) -> URL? { url.flatMap { swap($0, from: "chrome", to: "rise") } ?? url }
    private static func swap(_ url: URL, from: String, to: String) -> URL? {
        guard url.scheme?.lowercased() == from, let host = url.host?.lowercased(), hosts.contains(host),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = to
        // Shown as typed: rise://settings, not Chromium's rise://settings/.
        if to == "rise", parts.path == "/" { parts.path = "" }
        return parts.url
    }
}

/// Chromium, where it's been built into Rise (see Engine/README.md): Rise's engine unless asked
/// for WebKit, with `RISE_ENGINE=webkit` or the `RiseEngine` default set to "webkit". New and
/// restored tabs use it. Builds without it run on WebKit alone.
@MainActor enum ChromiumEngine {
    #if RISE_CHROMIUM
    static var isRequested: Bool {
        if let engine = ProcessInfo.processInfo.environment["RISE_ENGINE"] { return engine != "webkit" }
        return UserDefaults.standard.string(forKey: "RiseEngine") != "webkit"
    }
    /// The application class Chromium needs, made before anything else asks for `NSApp`.
    static func makeApplication() -> NSApplication { isRequested ? RCApplication.shared : NSApplication.shared }
    /// Starts Chromium if asked and packaged with the app; WebKit carries on otherwise.
    static func startIfRequested() {
        guard isRequested else { return }
        let framework = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/Chromium Embedded Framework.framework")
        guard FileManager.default.fileExists(atPath: framework.path) else {
            NSLog("Rise: Chromium isn't packaged in this build; using WebKit"); return
        }
        let profile = (RiseProfile.directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rise"))
            .appendingPathComponent("Chromium")
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // A test profile is thrown away, so its key needn't outlive it in the Keychain.
        if !RCEngine.start(withCachePath: profile.path, keychain: RiseProfile.directory == nil) { NSLog("Rise: Chromium didn't start; using WebKit") }
    }
    static var isRunning: Bool { RCEngine.isRunning }
    static func shutdown() { RCEngine.shutdown() }
    #else
    static func makeApplication() -> NSApplication { NSApplication.shared }
    static func startIfRequested() {}
    static var isRunning: Bool { false }
    static func shutdown() {}
    #endif
    /// The engine new tabs open in.
    static var engineForNewTabs: WebEngine { isRunning ? .chromium : .webKit }
}

#if RISE_CHROMIUM
/// A page drawn by Chromium.
@MainActor final class ChromiumPage: NSObject, WebPage, RCBrowserViewDelegate {
    let browserView: RCBrowserView
    var engine: WebEngine { .chromium }
    var view: NSView { browserView }
    var onChange: ((WebPageChange) -> Void)?
    var onHoverLink: ((URL?) -> Void)?
    var onOpenElsewhere: ((URL, Bool) -> Bool)?
    var onOpenInPeek: ((URL) -> Void)?
    /// The page wants to save a file; where to, or nil not to.
    var onDownload: ((RCDownload, _ suggestedName: String) -> URL?)?
    /// The page asks for these; `decide` takes whether they're allowed.
    var onPermissionRequest: ((_ capabilities: [SiteCapability], _ origin: String?, _ decide: @escaping (Bool) -> Void) -> Void)?
    var onPermissionWithdrawn: (() -> Void)?
    var onEvent: ((PageEvent) -> Void)?
    private var handlers: [String: (PageMessage) -> Void] = [:]
    private var replyingHandlers: [String: (PageMessage, @escaping (Any?, String?) -> Void) -> Void] = [:]
    /// Until it's asked to load something, the page is Chromium's blank start, not a page of its own.
    private var hasLoaded = false
    private var seen: (url: URL?, title: String?, loading: Bool, back: Bool, forward: Bool, progress: Double) = (nil, nil, false, false, false, 0)

    /// A page of its own, or, given `browserView`, a window another page opened, already loading.
    init(browserView: RCBrowserView? = nil) {
        self.browserView = browserView ?? RCBrowserView(frame: .zero, url: nil)
        hasLoaded = browserView != nil
        super.init()
        self.browserView.delegate = self
    }
    /// A window this page opens itself, still its popup; returns whether Rise took it.
    var onPopup: ((_ popup: ChromiumPage, URL) -> Bool)?
    nonisolated func browserView(_ browserView: RCBrowserView, adoptPopup popup: RCBrowserView, url: URL, userGesture: Bool) -> Bool {
        MainActor.assumeIsolated { onPopup?(ChromiumPage(browserView: popup), url) ?? false }
    }
    nonisolated func browserViewDidChange(_ browserView: RCBrowserView) {
        MainActor.assumeIsolated { reportChanges() }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, didHoverLink url: URL?) {
        MainActor.assumeIsolated { onHoverLink?(url) }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, open url: URL, disposition: RCOpenDisposition, userGesture: Bool) -> Bool {
        MainActor.assumeIsolated { onOpenElsewhere?(url, disposition == .backgroundTab) ?? false }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, openLinkInPeek url: URL) {
        MainActor.assumeIsolated { onOpenInPeek?(url) }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, didReceiveMessage body: Any, handler: String, frame: RCFrame,
                                 reply: ((Any?, String?) -> Void)?) {
        MainActor.assumeIsolated {
            let message = PageMessage(body: body is NSNull ? NSNull() : body,
                                      frame: PageFrame(isMain: frame.isMain, origin: SitePermissions.origin(URL(string: frame.origin)), handle: frame),
                                      page: self)
            if let reply, let receive = replyingHandlers[handler] { receive(message) { reply($0, $1) } }
            else if let receive = handlers[handler] { receive(message); reply?(nil, nil) }
            else { reply?(nil, "No handler") }
        }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, destinationFor download: RCDownload, suggestedName: String) -> URL? {
        MainActor.assumeIsolated { onDownload?(download, suggestedName) }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, requestPermissions permissions: RCPermission, origin: String,
                                 decide: @escaping (RCPermission) -> Void) {
        MainActor.assumeIsolated {
            var capabilities: [SiteCapability] = []
            if permissions.contains(.camera) { capabilities.append(.camera) }
            if permissions.contains(.microphone) { capabilities.append(.microphone) }
            if permissions.contains(.location) { capabilities.append(.location) }
            guard let onPermissionRequest else { decide([]); return }
            onPermissionRequest(capabilities, SitePermissions.origin(URL(string: origin))) { decide($0 ? permissions : []) }
        }
    }
    nonisolated func browserViewDidWithdrawPermissionRequest(_ browserView: RCBrowserView) {
        MainActor.assumeIsolated { onPermissionWithdrawn?() }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, willNavigate kind: RCNavigationKind) {
        MainActor.assumeIsolated { onEvent?(.willNavigate(kind == .history ? .history : kind == .reload ? .reload : .newPage)) }
    }
    nonisolated func browserViewDidFinishLoad(_ browserView: RCBrowserView) {
        MainActor.assumeIsolated { onEvent?(.finished) }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, didFailLoadWithCode code: Int, description: String, url: URL?) {
        MainActor.assumeIsolated { onEvent?(.failed(Self.errorMessage(code, description))) }
    }
    nonisolated func browserViewDidCrash(_ browserView: RCBrowserView) {
        MainActor.assumeIsolated { onEvent?(.crashed) }
    }
    nonisolated func browserView(_ browserView: RCBrowserView, openInOtherApp url: URL) {
        MainActor.assumeIsolated { onEvent?(.openInOtherApp(url)) }
    }
    /// Chromium's network errors, worded as WebKit words the common ones.
    static func errorMessage(_ code: Int, _ description: String) -> String {
        switch code {
        case -105, -137: return "A server with the specified hostname could not be found."
        case -106: return "The Internet connection appears to be offline."
        case -102, -109, -104: return "Could not connect to the server."
        case -7, -118: return "The request timed out."
        case -101, -100: return "The network connection was lost."
        case -21: return "The network connection changed."
        case -299 ... -200: return "The certificate for this server is invalid."
        default: return description.replacingOccurrences(of: "net::", with: "")
        }
    }

    func addMessageHandler(_ name: String, world: ScriptWorld, receive: @escaping (PageMessage) -> Void) {
        handlers[name] = receive
        browserView.addMessageHandler(name, world: world.name, replies: false)
    }
    func addMessageHandler(_ name: String, world: ScriptWorld, replying: @escaping (PageMessage, @escaping (Any?, String?) -> Void) -> Void) {
        replyingHandlers[name] = replying
        browserView.addMessageHandler(name, world: world.name, replies: true)
    }
    func addUserScript(_ source: String, world: ScriptWorld, mainFrameOnly: Bool, handlers: [String]) {
        browserView.addUserScript(source, world: world.name, mainFrameOnly: mainFrameOnly, handlers: handlers)
    }
    func evaluate(_ body: String, arguments: [String: Any], in frame: PageFrame?, world: ScriptWorld,
                  completion: @escaping (Result<Any?, Error>) -> Void) {
        browserView.evaluateFunctionBody(body, arguments: arguments, frame: frame?.handle as? RCFrame, world: world.name) { value, error in
            MainActor.assumeIsolated { completion(error.map { .failure(PageScriptError(message: $0)) } ?? .success(value)) }
        }
    }
    private func reportChanges() {
        let now = (url: url, title: title, loading: browserView.isLoading,
                   back: browserView.canGoBack, forward: browserView.canGoForward, progress: browserView.progress)
        let before = seen; seen = now
        if now.url != before.url { onChange?(.url) }
        if now.title != before.title { onChange?(.title) }
        if now.loading != before.loading { onChange?(.loading) }
        if now.back != before.back || now.forward != before.forward { onChange?(.navigation) }
        if now.progress != before.progress { onChange?(.progress) }
        if browserView.audible != audible { audible = browserView.audible; onChange?(.audio) }
        if browserView.fullscreen != (fullscreenWindow != nil) { followFullscreen() }
    }
    private var audible = false

    var url: URL? { hasLoaded ? RisePages.address(for: browserView.url) : nil }
    var title: String? { hasLoaded ? browserView.title : nil }
    var isLoading: Bool { browserView.isLoading }
    var estimatedProgress: Double { browserView.progress }
    var canGoBack: Bool { browserView.canGoBack }
    var canGoForward: Bool { browserView.canGoForward }
    /// While an element is full screen, the page shows in a window of its own, in its own
    /// Space, as WebKit's full screen does; Rise's layout leaves it be until it's back.
    var isInNativeFullscreen: Bool { fullscreenWindow != nil }
    private var fullscreenWindow: ChromiumFullscreenWindow?
    private func followFullscreen() {
        if browserView.fullscreen, fullscreenWindow == nil {
            let window = ChromiumFullscreenWindow(showing: browserView)
            window.onLeave = { [weak self] in self?.browserView.exitFullscreen() }
            window.onClosed = { [weak self, weak window] in
                guard let self, self.fullscreenWindow === window else { return }
                self.fullscreenWindow = nil; self.onChange?(.fullscreen)
            }
            fullscreenWindow = window
            onChange?(.fullscreen)
            window.enter()
        } else if !browserView.fullscreen, let window = fullscreenWindow {
            window.leave()
        }
    }
    var isMagnified: Bool { false }
    var isCovered: Bool {
        get { browserView.covered }
        set { browserView.covered = newValue }
    }
    var isPlayingAudio: Bool { audible }
    var zoom: CGFloat {
        get { browserView.zoom }
        set { browserView.zoom = newValue }
    }
    func load(_ url: URL) { hasLoaded = true; browserView.open(RisePages.page(for: url)) }
    func goBack() { browserView.goBack() }
    func goForward() { browserView.goForward() }
    func reload() { browserView.reload() }
    func reloadIgnoringCache() { browserView.reloadIgnoringCache() }
    func stopLoading() { browserView.stopLoading() }
    @discardableResult func setAudioMuted(_ muted: Bool) -> Bool { browserView.setAudioMuted(muted); return true }
    /// Chromium's history is tagged, so a WebKit page's saved history is never handed to it.
    private static let stateTag = Data("RiseChromium1\0".utf8)
    var sessionState: Data? { browserView.navigationState.map { Self.stateTag + $0 } }
    func restoreSession(_ data: Data, fallback url: URL) -> Bool {
        guard data.starts(with: Self.stateTag) else { return false }
        hasLoaded = true
        browserView.restoreNavigationState(data.dropFirst(Self.stateTag.count), fallback: url)
        return true
    }
    /// Rise's page tools share one world, as WebKit's default client world.
    static let toolsWorld = "Rise"
    func snapshot(width: CGFloat?) async -> NSImage? {
        guard let image = await wholeSnapshot() else { return nil }
        if let width, image.size.width > 0 { image.size = NSSize(width: width, height: image.size.height*width/image.size.width) }
        return image
    }
    var showsLiveLayers: Bool { true }
    func liveLayer(showing rect: NSRect?) -> CALayer? { browserView.liveLayerShowing(rect ?? browserView.bounds) }
    func snapshot(rect: NSRect) async -> NSImage? {
        guard let image = await wholeSnapshot(), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), image.size.width > 0 else { return nil }
        // Image rows run top down; the view's may not.
        let scale = CGFloat(cg.width)/image.size.width, bounds = browserView.bounds
        let top = browserView.isFlipped ? rect.minY : bounds.height-rect.maxY
        let pixels = CGRect(x: rect.minX*scale, y: top*scale, width: rect.width*scale, height: rect.height*scale).integral
        guard let crop = cg.cropping(to: pixels) else { return nil }
        return NSImage(cgImage: crop, size: rect.size)
    }
    private func wholeSnapshot() async -> NSImage? {
        await withCheckedContinuation { continuation in browserView.snapshot { continuation.resume(returning: $0) } }
    }
    func evaluate(_ body: String, arguments: [String: Any], world: String?) async -> Any? {
        await withCheckedContinuation { continuation in
            browserView.evaluateFunctionBody(body, arguments: arguments, world: world ?? Self.toolsWorld) { continuation.resume(returning: $0) }
        }
    }
    func addScriptToEveryDocument(_ source: String, world: String) { browserView.addScript(toEveryDocument: source, world: world) }
    func setTheme(_ appearance: NSAppearance, background: NSColor) {
        browserView.prefersDark = NSNumber(value: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        if browserView.pageBackgroundColor != background { browserView.pageBackgroundColor = background }
    }
    func setMediaSuspended(_ suspended: Bool) {
        // Plays again only what was playing when it was held.
        Task { _ = await evaluate(Self.suspendMedia, arguments: ["suspend": suspended], world: nil) }
    }
    private static let suspendMedia = """
    for (const media of document.querySelectorAll('video, audio')) {
      if (suspend) { if (!media.paused) { media.dataset.riseSuspended = '1'; media.pause(); } }
      else if (media.dataset.riseSuspended) { delete media.dataset.riseSuspended; media.play().catch(() => {}); }
    }
    """
}
/// The window a Chromium page shows an element full screen in.
@MainActor final class ChromiumFullscreenWindow: NSWindow, NSWindowDelegate {
    /// Takes the page out of its full screen: the person left it, by Escape or the window's own
    /// button, or the window is going.
    var onLeave: (() -> Void)?
    /// Out of full screen; the page can go back where it was.
    var onClosed: (() -> Void)?
    init(showing page: NSView) {
        let start = page.window.map { $0.convertToScreen(page.convert(page.bounds, to: nil)) } ?? NSScreen.main?.frame ?? .zero
        super.init(contentRect: start, styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        titleVisibility = .hidden; titlebarAppearsTransparent = true
        backgroundColor = .black; isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenPrimary]; delegate = self
        let content = NSView(frame: NSRect(origin: .zero, size: start.size))
        contentView = content
        page.frame = content.bounds; page.autoresizingMask = [.width, .height]
        content.addSubview(page)
    }
    /// Going into full screen; macOS ignores a toggle until it's in.
    private var entering = false
    /// Out of full screen is where it's headed, whoever asked.
    private var wantsOut = false
    private var closed = false
    func enter() {
        makeKeyAndOrderFront(nil)
        entering = true
        toggleFullScreen(nil)
        makeFirstResponder(contentView?.subviews.first)
    }
    /// Heads out of full screen, as soon as macOS allows.
    func leave() {
        wantsOut = true
        guard !entering, !closed else { return }
        if styleMask.contains(.fullScreen) { toggleFullScreen(nil) } else { finish() }
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        entering = false
        // Not from inside this notice, which macOS ignores.
        if wantsOut { DispatchQueue.main.async { [weak self] in self?.leave() } }
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        // The window's own button, or Mission Control: the page goes too.
        if !wantsOut { wantsOut = true; onLeave?() }
    }
    func windowDidExitFullScreen(_ notification: Notification) { finish() }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { entering = false; finish() }
    private func finish() {
        guard !closed else { return }
        closed = true
        // The page leaves its full screen with the window, whichever went first.
        onLeave?()
        contentView?.subviews.first?.autoresizingMask = []
        onClosed?()
        orderOut(nil)
    }
    override func sendEvent(_ event: NSEvent) {
        // Escape leaves full screen before the page sees it, as in Chrome.
        if event.type == .keyDown, event.keyCode == 53 { onLeave?(); leave(); return }
        super.sendEvent(event)
    }
}
/// A Chromium page loaded out of sight with its scripts off, only to put a link the pointer
/// rests on into the cache the tab then loads it from.
@MainActor final class ChromiumPreload: NSObject, RCBrowserViewDelegate {
    private let view: RCBrowserView
    private var done: ((Bool) -> Void)?
    init(_ url: URL, size: NSSize, done: @escaping (Bool) -> Void) {
        view = RCBrowserView(frame: NSRect(origin: .zero, size: size), url: nil)
        self.done = done
        super.init()
        view.scriptsDisabled = true; view.delegate = self
        view.setAudioMuted(true); view.open(url)
    }
    func cancel() { done = nil; view.close() }
    private func finish(_ loaded: Bool) { let done = done; self.done = nil; done?(loaded) }
    nonisolated func browserViewDidChange(_ browserView: RCBrowserView) {}
    nonisolated func browserViewDidFinishLoad(_ browserView: RCBrowserView) { MainActor.assumeIsolated { finish(true) } }
    nonisolated func browserView(_ browserView: RCBrowserView, didFailLoadWithCode code: Int, description: String, url: URL?) {
        MainActor.assumeIsolated { finish(false) }
    }
    nonisolated func browserViewDidCrash(_ browserView: RCBrowserView) { MainActor.assumeIsolated { finish(false) } }
    // Never anything more than the page: no downloads, other apps or new tabs.
    nonisolated func browserView(_ browserView: RCBrowserView, destinationFor download: RCDownload, suggestedName: String) -> URL? { nil }
    nonisolated func browserView(_ browserView: RCBrowserView, open url: URL, disposition: RCOpenDisposition, userGesture: Bool) -> Bool { true }
}
#endif
