import AppKit
import WebKit

@MainActor private final class YouTubeVideoBridge: NSObject, WKScriptMessageHandler {
    weak var owner: YouTubePictureInPicture?
    init(_ owner: YouTubePictureInPicture) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

/// Transfers the original web view, preserving YouTube's MediaSource, cookies,
/// audio, playhead, quality and playback rate. Each handoff owns its completion.
@MainActor final class YouTubePictureInPicture: NSObject {
    static let contentWorld = WKContentWorld.world(name: "Rise.YouTubePictureInPicture")
    weak var browser: BrowserController?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    private var states: [UUID: VideoState] = [:] {
        didSet {
            // Keeps each tab's play button in step with its page.
            for id in Set(states.keys).union(oldValue.keys) where states[id]?.paused != oldValue[id]?.paused {
                browser?.sidebar.rows[id]?.setPlayback(paused: states[id]?.paused)
            }
        }
    }
    private var previousVisible = Set<UUID>()
    private var dismissed = Set<UUID>()
    /// Closed because the video ended. Autoplay can start the next video after
    /// that, so these float again if they resume while hidden.
    private var ended = Set<UUID>()
    private var current: Session?
    private var departing: [UUID: Session] = [:]
    private var probeID = UUID()
    private var endedTask: Task<Void, Never>?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var sourceTabID: UUID? { current?.tab?.id }
    var panel: FloatingVideoWindow? { current?.panel }

    private struct VideoState {
        let playing: Bool
        let paused: Bool
        let ended: Bool
        let aspect: CGFloat
    }
    @MainActor private final class Session {
        let id = UUID()
        weak var tab: BrowserTab?
        let panel: FloatingVideoWindow
        var transitionID = UUID()
        var returning = false
        /// Freezing the picture and leaving the page's canvas, before the page returns.
        var handingBack = false
        /// The page is back in the browser; only the frozen picture remains.
        var released = false
        var leaving: Bool { handingBack || panel.isDismissing }
        var firstFrameTimeout: Task<Void, Never>?
        var playbackLink: CADisplayLink?
        var pendingFrameID: UUID?
        /// One seek in flight; a scrub's newer positions replace the queued one.
        var seeking = false
        var queuedSeek: (fraction: Double, final: Bool)?
        init(tab: BrowserTab, panel: FloatingVideoWindow) { self.tab = tab; self.panel = panel }
    }
    init(browser: BrowserController) { self.browser = browser; super.init() }

    func install(on web: WKWebView) {
        let content = web.configuration.userContentController
        guard !controllers.contains(content) else { return }
        controllers.add(content)
        content.add(YouTubeVideoBridge(self), contentWorld: Self.contentWorld, name: "riseYouTubeVideo")
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.contentWorld))
    }
    /// Whether the floating window holds this tab's page.
    func owns(_ tab: BrowserTab) -> Bool {
        sessions.contains { $0.tab === tab && !$0.released }
    }
    /// Whether the tab has a floating window, including one still fading out.
    private func floats(_ tab: BrowserTab) -> Bool { sessions.contains { $0.tab === tab } }
    private var sessions: [Session] { (current.map { [$0] } ?? []) + departing.values }
    func isPlaying(_ tab: BrowserTab) -> Bool { states[tab.id]?.playing == true }
    /// Whether the tab's video is paused, or nil when the tab shows none.
    func playbackPaused(_ id: UUID) -> Bool? { states[id]?.paused }
    /// Plays or pauses a tab's video, whether or not the tab is showing.
    func togglePlayback(_ id: UUID) {
        guard let tab = browser?.tabs.first(where: { $0.id == id }) else { return }
        Self.call("return window.riseYouTubeVideo?.togglePlayback() ?? null", in: tab.webView) { [weak self, weak tab] value, _ in
            // A hidden page reports late, since its timers are throttled.
            guard let self, let tab else { return }
            let paused = value as? Bool ?? self.states[tab.id]?.paused
            self.browser?.sidebar.rows[tab.id]?.setPlayback(paused: paused, confirmed: true)
            if let paused, let session = self.current, session.tab === tab, !session.leaving { session.panel.showPlayback(paused: paused) }
        }
    }
    private func allowed(_ tab: BrowserTab) -> Bool {
        YouTubeVideoPage.containsVideo(tab.url)
            && browser?.sitePermissions.automaticPictureInPicture(origin: SitePermissions.origin(tab.url)) == true
    }

    /// Runs before tab attachment, so a leaving player has its new window before
    /// the browser removes hidden pages. Split pages remain inline while visible.
    func reconcile(visibleIDs: Set<UUID>) {
        guard let browser else { return }
        let leaving = previousVisible.subtracting(visibleIDs)
        if previousVisible != visibleIDs { probeID = UUID() }
        previousVisible = visibleIDs; dismissed.subtract(visibleIDs); ended.subtract(visibleIDs)
        if let session = current, let tab = session.tab {
            if !allowed(tab) { restore(session, animated: true, pause: false) }
            else if visibleIDs.contains(tab.id) { restore(session, animated: true, pause: false, returning: true) }
            else if session.returning {
                // Cancel an interrupted return in place. The frozen picture
                // stays up until the page paints into the window again.
                session.transitionID = UUID(); session.returning = false
                session.handingBack = false; session.released = false
                if session.panel.isDismissing { session.panel.cancelDismissal() }
                prepare(session)
            }
        }
        let candidates = browser.tabs.filter { leaving.contains($0.id) && !dismissed.contains($0.id) && !floats($0) && allowed($0) }
        if let tab = candidates.first(where: { isPlaying($0) }) {
            start(tab, aspect: states[tab.id]?.aspect ?? 16.0/9)
        } else if let tab = candidates.first {
            // A fast switch can outrun delivery of the video's play event.
            let token = UUID(); probeID = token
            let url = tab.url
            Self.call("return window.riseYouTubeVideo?.canFloat() ?? null", in: tab.webView) { [weak self, weak tab] value, _ in
                guard let self, self.probeID == token, let tab, tab.url == url,
                      self.browser?.tabs.contains(where: { $0 === tab }) == true,
                      !self.previousVisible.contains(tab.id), !self.dismissed.contains(tab.id), self.allowed(tab),
                      let aspect = value as? Double, aspect.isFinite, aspect > 0 else { return }
                self.start(tab, aspect: CGFloat(aspect))
            }
        }
    }

    func receive(_ message: WKScriptMessage) {
        guard let browser, message.frameInfo.isMainFrame, let web = message.webView,
              let tab = browser.tabs.first(where: { $0.webView === web }),
              SitePermissions.origin(message.frameInfo.securityOrigin) == SitePermissions.origin(web.url),
              let body = message.body as? [String: Any], let href = body["href"] as? String,
              href == web.url?.absoluteString else { return }
        if let kind = body["kind"] as? String {
            guard let session = current, session.tab === tab, !session.leaving,
                  body["token"] as? String == session.transitionID.uuidString, allowed(tab) else { return }
            if kind == "captureFailed" { restore(session, animated: false, pause: false) }
            else if kind == "rendered", let frames = body["frames"] as? Int, frames > 0 {
                session.firstFrameTimeout?.cancel(); session.firstFrameTimeout = nil
                let firstFrame = !session.panel.hasVideoFrame
                session.panel.didRenderVideo(frames: frames, interval: 0)
                if firstFrame { session.panel.present() }
            }
            return
        }
        guard YouTubeVideoPage.containsVideo(web.url), body["hasVideo"] as? Bool == true else {
            states.removeValue(forKey: tab.id)
            if let session = current, session.tab === tab { restore(session, animated: true, pause: false) }
            return
        }
        let aspect = (body["aspect"] as? Double).flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } ?? 16.0/9
        let state = VideoState(playing: body["playing"] as? Bool == true, paused: body["paused"] as? Bool != false,
                               ended: body["ended"] as? Bool == true, aspect: aspect)
        states[tab.id] = state
        if state.playing { resumeAfterEnd(tab) }
        if current?.tab === tab {
            endedTask?.cancel(); endedTask = nil
            if let session = current {
                if state.playing && !session.leaving { startPlaybackClock(session) }
                else { stopPlaybackClock(session) }
                if !session.leaving { session.panel.showPlayback(paused: state.paused) }
            }
            if state.ended && !state.playing {
                // An ad or playlist can advance immediately after ended.
                endedTask = Task { [weak self] in
                    do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
                    guard let self, let session = self.current, session.tab === tab, self.states[tab.id]?.ended == true else { return }
                    self.ended.insert(tab.id)
                    self.restore(session, animated: true, pause: false)
                }
            }
        }
    }

    private func resumeAfterEnd(_ tab: BrowserTab) {
        guard ended.contains(tab.id), !floats(tab), !previousVisible.contains(tab.id), !dismissed.contains(tab.id), allowed(tab),
              browser?.tabs.contains(where: { $0 === tab }) == true else { return }
        ended.remove(tab.id); start(tab, aspect: states[tab.id]?.aspect ?? 16.0/9)
    }

    private func start(_ tab: BrowserTab, aspect: CGFloat) {
        guard !floats(tab), let browser, allowed(tab), let screen = browser.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        probeID = UUID()
        if let old = current {
            // Waiting for the old fade would leave the new player detached.
            departing[old.id] = old; current = nil
            restore(old, animated: true, pause: true)
        }
        let session = Session(tab: tab, panel: FloatingVideoWindow(aspectRatio: aspect, screen: screen, referenceWindow: browser.window))
        current = session
        session.panel.onClose = { [weak self] in self?.closeVideo() }
        session.panel.onReturn = { [weak self] in self?.returnToTab() }
        session.panel.onMinimize = { [weak self] in self?.minimizeVideo() }
        session.panel.onSeek = { [weak self, weak session] fraction, final in
            if let self, let session { self.seek(session, to: fraction, final: final) }
        }
        session.panel.onTogglePlayback = { [weak session] in
            Self.call("return window.riseYouTubeVideo?.togglePlayback() ?? null", in: session?.tab?.webView) { [weak session] value, _ in
                guard let session, !session.leaving, let paused = value as? Bool else { return }
                session.panel.showPlayback(paused: paused)
            }
        }
        session.panel.onVideoSizeChange = { [weak self, weak session] size, ratio in
            guard let self, let session, self.current === session, !session.leaving, let web = session.tab?.webView else { return }
            Self.call("window.riseYouTubeVideo?.resize(\(Self.canvasArguments(size, ratio, in: web)))", in: web) { [weak session] _, error in
                if error == nil { session?.panel.didResizeVideo(to: size) }
            }
        }
        prepare(session)
    }

    private func prepare(_ session: Session) {
        guard let tab = session.tab else { return }
        let token = session.transitionID
        if tab.webView.window !== session.panel {
            if !session.panel.hasVideoFrame { session.panel.showForFirstFrame() }
            session.panel.attach(tab.webView)
        }
        session.firstFrameTimeout?.cancel()
        session.firstFrameTimeout = Task { [weak self, weak session] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, let session, self.current === session, session.transitionID == token,
                  !session.panel.hasVideoFrame else { return }
            self.restore(session, animated: false, pause: false)
        }
        let size = session.panel.videoFrame.size, arguments = Self.canvasArguments(size, session.panel.backingScaleFactor, in: tab.webView)
        Self.call("return window.riseYouTubeVideo?.enter('\(token.uuidString)', \(arguments)) ?? false", in: tab.webView) { [weak self, weak session] value, error in
            guard let self, let session, self.current === session, session.transitionID == token else { return }
            if error != nil || value as? Bool != true { self.restore(session, animated: false, pause: false) }
            else if !session.leaving { session.panel.didResizeVideo(to: size); self.startPlaybackClock(session) }
        }
    }

    /// The canvas is sized in CSS pixels, which page zoom scales on screen.
    private static func canvasArguments(_ size: NSSize, _ backingScale: CGFloat, in web: WKWebView) -> String {
        let zoom = web.pageZoom > 0 ? web.pageZoom : 1
        return "\(size.width/zoom), \(size.height/zoom), \(backingScale*zoom)"
    }

    private func startPlaybackClock(_ session: Session) {
        guard session.playbackLink == nil, let screen = session.panel.screen ?? NSScreen.main else { return }
        // WebKit pauses rAF/video presentation callbacks for this background
        // player. The screen clock drives local painting without reading back,
        // encoding, transferring or decoding any video pixels.
        let link = screen.displayLink(target: self, selector: #selector(paintVideo(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); session.playbackLink = link
    }
    private func stopPlaybackClock(_ session: Session) {
        session.playbackLink?.invalidate(); session.playbackLink = nil; session.pendingFrameID = nil
    }
    @objc private func paintVideo(_ link: CADisplayLink) {
        guard let session = current, session.playbackLink === link, !session.leaving,
              session.pendingFrameID == nil, let web = session.tab?.webView else { return }
        let frameID = UUID(); session.pendingFrameID = frameID
        Self.call("return window.riseYouTubeVideo?.paint() ?? null", in: web) { [weak self, weak session] value, _ in
            guard let self, let session, session.pendingFrameID == frameID else { return }
            session.pendingFrameID = nil
            guard self.current === session, !session.leaving, session.panel.hasVideoFrame,
                  let stats = value as? [String: Any], let frames = stats["frames"] as? Int else { return }
            session.panel.didRenderVideo(frames: frames, interval: stats["interval"] as? Double ?? 0)
            if let time = stats["time"] as? Double, let duration = stats["duration"] as? Double {
                session.panel.showProgress(time: time, duration: duration)
            }
            // A frame painted after this one was requested, so the canvas shows.
            session.panel.clearFrozenFrame()
        }
    }

    func returnToTab() {
        guard let sourceTabID, let browser, browser.tabs.contains(where: { $0.id == sourceTabID }) else { return }
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true); browser.select(sourceTabID)
    }
    private func seek(_ session: Session, to fraction: Double, final: Bool) {
        guard current === session, !session.leaving, fraction.isFinite else { return }
        if session.seeking { session.queuedSeek = (fraction, final); return }
        session.seeking = true
        Self.call("return window.riseYouTubeVideo?.seek(\(fraction), \(final)) ?? null", in: session.tab?.webView) { [weak self, weak session] value, _ in
            guard let self, let session else { return }
            session.seeking = false
            if let result = value as? [String: Any], let time = result["time"] as? Double, let duration = result["duration"] as? Double {
                session.panel.showProgress(time: time, duration: duration)
            }
            if let next = session.queuedSeek { session.queuedSeek = nil; self.seek(session, to: next.fraction, final: next.final) }
        }
    }

    /// Hides the floating window while the video keeps playing in its hidden
    /// tab, as it did before Picture in Picture. It floats again only after
    /// the tab has been shown.
    func minimizeVideo() {
        guard let session = current else { return }
        if let tab = session.tab { dismissed.insert(tab.id) }
        restore(session, animated: true, pause: false)
    }
    func closeVideo() {
        guard let session = current else { return }
        if let tab = session.tab { dismissed.insert(tab.id) }
        restore(session, animated: true, pause: true)
    }

    private func restore(_ session: Session, animated: Bool, pause: Bool, returning: Bool = false) {
        if pause { Self.call("window.riseYouTubeVideo?.pause()", in: session.tab?.webView) { _, _ in } }
        guard !session.leaving else { return }
        endedTask?.cancel(); endedTask = nil
        stopPlaybackClock(session)
        session.returning = returning; session.handingBack = true
        session.firstFrameTimeout?.cancel(); session.firstFrameTimeout = nil
        session.transitionID = UUID()
        let token = session.transitionID, animated = animated && !reduceMotion()
        let web = session.tab?.webView
        // Freeze the current picture, so the live page can return to its tab at
        // once while only the frozen picture fades. WebKit takes the snapshot
        // before it runs exit(), which removes the canvas from the page.
        var frozen: NSImage?, waiting = 1
        let finish = { [weak self, weak session] in
            waiting -= 1
            guard waiting == 0, let self, let session, session.transitionID == token else { return }
            self.handBack(session, frozen: frozen, animated: animated, token: token)
        }
        if animated, session.panel.hasVideoFrame, let web, web.window === session.panel {
            waiting += 1
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: session.panel.videoHost.frame.size)
            web.takeSnapshot(with: configuration) { image, _ in frozen = image; finish() }
        }
        Self.call("window.riseYouTubeVideo?.exit()", in: web) { _, _ in finish() }
    }

    private func handBack(_ session: Session, frozen: NSImage?, animated: Bool, token: UUID) {
        session.handingBack = false; session.released = true
        if let frozen { session.panel.freeze(frozen) }
        session.panel.dismiss(animated: animated) { [weak self, weak session] in
            guard let self, let session, session.transitionID == token else { return }
            if self.current === session { self.current = nil }
            self.departing.removeValue(forKey: session.id)
            if let tab = session.tab, self.states[tab.id]?.playing == true { self.resumeAfterEnd(tab) }
        }
        guard let tab = session.tab else { return }
        if tab.webView.window === session.panel { tab.webView.removeFromSuperview(); tab.webView.autoresizingMask = [] }
        guard let browser else { return }
        browser.attachVisiblePages(); browser.layoutChrome()
        // Selecting the tab could not focus a page held by the panel.
        // Give it focus now, unless something else has taken it.
        if browser.selectedID == tab.id, browser.peekTab == nil,
           let window = browser.window, window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(tab.webView)
        }
    }

    func navigationStarted(in web: WKWebView) {
        guard let browser, let tab = browser.tabs.first(where: { $0.webView === web }) else { return }
        // A page still returning to the browser window was in the panel.
        if clearMedia(for: tab) { browser.attachVisiblePages(); browser.layoutChrome() }
    }
    func remove(_ tab: BrowserTab) {
        previousVisible.remove(tab.id); clearMedia(for: tab)
    }
    @discardableResult private func clearMedia(for tab: BrowserTab) -> Bool {
        states.removeValue(forKey: tab.id); dismissed.remove(tab.id); ended.remove(tab.id)
        var disposed = false
        if let session = current, session.tab === tab { dispose(session); current = nil; disposed = true }
        for session in departing.values.filter({ $0.tab === tab }) { dispose(session); departing.removeValue(forKey: session.id); disposed = true }
        return disposed
    }
    func tearDown() {
        endedTask?.cancel(); endedTask = nil; probeID = UUID()
        if let current { dispose(current) }
        departing.values.forEach(dispose)
        current = nil; departing = [:]
    }
    private func dispose(_ session: Session) {
        stopPlaybackClock(session)
        session.firstFrameTimeout?.cancel()
        session.transitionID = UUID()
        let web = session.tab?.webView
        // A released page is already back in the browser.
        if let web, web.window === session.panel { web.removeFromSuperview(); web.autoresizingMask = [] }
        Self.call("window.riseYouTubeVideo?.exit()", in: web) { _, _ in }
        session.panel.closeImmediately()
    }

    static func call(_ body: String, in web: WKWebView?, completion: @escaping (Any?, Error?) -> Void) {
        guard let web else { completion(nil, nil); return }
        web.callAsyncJavaScript(body, arguments: [:], in: nil, in: contentWorld) { result in
            switch result {
            case .success(let value): completion(value, nil)
            case .failure(let error): completion(nil, error)
            }
        }
    }
}
