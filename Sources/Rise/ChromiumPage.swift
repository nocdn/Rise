import AppKit
#if RISE_CHROMIUM
import RiseChromium
#endif

/// A separate place for the session, history and website data, for trying Rise out (with
/// another engine, say) without touching the everyday ones: `RISE_PROFILE_DIR=<folder>`.
enum RiseProfile {
    static var directory: URL? { ProcessInfo.processInfo.environment["RISE_PROFILE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

/// Chromium, where it's been built into Rise (see Engine/README.md). It only starts when
/// asked, with `RISE_ENGINE=chromium` or the `RiseEngine` default set to "chromium"; then
/// new tabs use it. Everywhere else Rise runs on WebKit alone.
@MainActor enum ChromiumEngine {
    #if RISE_CHROMIUM
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["RISE_ENGINE"] == "chromium" || UserDefaults.standard.string(forKey: "RiseEngine") == "chromium"
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
    let browserView = RCBrowserView(frame: .zero, url: nil)
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
    private var handlers: [String: (PageMessage) -> Void] = [:]
    private var replyingHandlers: [String: (PageMessage, @escaping (Any?, String?) -> Void) -> Void] = [:]
    /// Until it's asked to load something, the page is Chromium's blank start, not a page of its own.
    private var hasLoaded = false
    private var seen: (url: URL?, title: String?, loading: Bool, back: Bool, forward: Bool, progress: Double) = (nil, nil, false, false, false, 0)

    override init() {
        super.init()
        browserView.delegate = self
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
    }
    private var audible = false

    var url: URL? { hasLoaded ? browserView.url : nil }
    var title: String? { hasLoaded ? browserView.title : nil }
    var isLoading: Bool { browserView.isLoading }
    var estimatedProgress: Double { browserView.progress }
    var canGoBack: Bool { browserView.canGoBack }
    var canGoForward: Bool { browserView.canGoForward }
    var isInNativeFullscreen: Bool { false }
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
    func load(_ url: URL) { hasLoaded = true; browserView.open(url) }
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
#endif
