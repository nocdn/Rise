import AppKit
import WebKit

@MainActor private final class VideoPictureInPictureBridge: NSObject, WKScriptMessageHandler {
    weak var owner: VideoPictureInPicture?
    init(_ owner: VideoPictureInPicture) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

/// Floats a tab's video when the tab is left: YouTube's video pages, and on any
/// other site a video that has played with sound, in the page or one of its frames.
/// Transfers the original web view, preserving the player's MediaSource, cookies,
/// audio, playhead, quality and playback rate. Each handoff owns its completion.
@MainActor final class VideoPictureInPicture: NSObject {
    static let contentWorld = WKContentWorld.world(name: "Rise.PictureInPicture")
    weak var browser: BrowserController?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()
    /// Each tab's floating candidate, from the frame chosen among those with a video.
    private var states: [UUID: VideoState] = [:] {
        didSet {
            // Keeps each tab's play button in step with its page.
            for id in Set(states.keys).union(oldValue.keys) where states[id]?.paused != oldValue[id]?.paused {
                browser?.refreshPlayback(id)
            }
        }
    }
    /// Every frame's video, by tab and by the frame's own key.
    private var frameVideos: [UUID: [String: FrameVideo]] = [:]
    /// Tabs whose encrypted video Rise put in WebKit's own picture in picture.
    private var nativeFloats: [UUID: Target] = [:]
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
        /// Draws as black, so it floats in WebKit's own picture in picture instead.
        let encrypted: Bool
        let aspect: CGFloat
    }
    private struct FrameVideo {
        let state: VideoState
        let info: WKFrameInfo
        /// When it last played, so the frame heard most recently floats.
        let playedAt: CFTimeInterval
    }
    /// The frame a video plays in; `info` is nil for the main frame.
    private struct Target { let key: String?; let info: WKFrameInfo? }
    @MainActor private final class Session {
        let id = UUID()
        weak var tab: BrowserTab?
        let panel: FloatingVideoWindow
        let target: Target
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
        /// A new canvas size, shown once a later paint proves it reached the screen.
        var pendingCanvas: (id: UUID, size: NSSize, origin: NSPoint, afterPaint: Int)?
        var paintsIssued = 0
        /// One seek in flight; a scrub's newer positions replace the queued one.
        var seeking = false
        var queuedSeek: (fraction: Double, final: Bool)?
        init(tab: BrowserTab, panel: FloatingVideoWindow, target: Target) { self.tab = tab; self.panel = panel; self.target = target }
        func call(_ body: String, completion: @escaping (Any?, Error?) -> Void = { _, _ in }) {
            VideoPictureInPicture.call(body, in: tab?.webView, frame: target.info, completion: completion)
        }
    }
    init(browser: BrowserController) { self.browser = browser; super.init() }

    func install(on web: WKWebView) {
        let content = web.configuration.userContentController
        guard !controllers.contains(content) else { return }
        controllers.add(content)
        content.add(VideoPictureInPictureBridge(self), contentWorld: Self.contentWorld, name: "risePictureInPicture")
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.contentWorld))
    }
    /// Whether the floating window holds this tab's page.
    func owns(_ tab: BrowserTab) -> Bool {
        sessions.contains { $0.tab === tab && !$0.released }
    }
    /// Whether the tab has a floating window, including one still fading out.
    private func floats(_ tab: BrowserTab) -> Bool { sessions.contains { $0.tab === tab } }
    private var sessions: [Session] { (current.map { [$0] } ?? []) + departing.values }
    func isPlaying(_ tab: BrowserTab) -> Bool { states[tab.id]?.playing == true }
    /// Whether Rise's own window can show it: encrypted video draws as black there.
    private func canPaint(_ tab: BrowserTab) -> Bool { states[tab.id]?.encrypted != true }
    /// Whether a YouTube video page's video is paused, or nil for any other tab,
    /// whose play button follows all of its media instead.
    func playbackPaused(_ id: UUID) -> Bool? {
        guard let tab = browser?.tabs.first(where: { $0.id == id }), YouTubeVideoPage.containsVideo(tab.url) else { return nil }
        return states[id]?.paused
    }
    /// Plays or pauses a tab's video, whether or not the tab is showing.
    func togglePlayback(_ id: UUID) {
        guard let tab = browser?.tabs.first(where: { $0.id == id }) else { return }
        Self.call("return window.risePictureInPicture?.togglePlayback() ?? null", in: tab.webView, frame: target(tab)?.info) { [weak self, weak tab] value, _ in
            // A hidden page reports late, since its timers are throttled.
            guard let self, let tab else { return }
            let paused = value as? Bool ?? self.states[tab.id]?.paused
            self.browser?.sidebar.rows[tab.id]?.setPlayback(paused: paused, confirmed: true)
            if let paused, let session = self.current, session.tab === tab, !session.leaving { session.panel.showPlayback(paused: paused) }
        }
    }
    /// YouTube floats only from its video pages; other sites, from any page.
    private func allowed(_ tab: BrowserTab) -> Bool {
        browser?.sitePermissions.automaticPictureInPicture(origin: SitePermissions.origin(tab.url)) == true
            && (!YouTubeVideoPage.isYouTube(tab.url) || YouTubeVideoPage.containsVideo(tab.url))
    }
    /// The frame whose video the tab floats: the one floating, else one playing,
    /// then the page's own, then the one heard most recently.
    private func chosenFrame(_ tab: BrowserTab) -> (key: String, video: FrameVideo)? {
        guard let frames = frameVideos[tab.id], !frames.isEmpty else { return nil }
        if let key = sessions.first(where: { $0.tab === tab && !$0.released })?.target.key, let video = frames[key] { return (key, video) }
        func rank(_ video: FrameVideo) -> (Int, Int, CFTimeInterval) { (video.state.playing ? 1 : 0, video.info.isMainFrame ? 1 : 0, video.playedAt) }
        return frames.max { rank($0.value) < rank($1.value) }.map { ($0.key, $0.value) }
    }
    private func target(_ tab: BrowserTab) -> Target? {
        chosenFrame(tab).map { Target(key: $0.key, info: $0.video.info.isMainFrame ? nil : $0.video.info) }
    }

    /// Runs before tab attachment, so a leaving player has its new window before
    /// the browser removes hidden pages. Split pages remain inline while visible.
    func reconcile(visibleIDs: Set<UUID>) {
        guard let browser else { return }
        let leaving = previousVisible.subtracting(visibleIDs)
        if previousVisible != visibleIDs { probeID = UUID() }
        previousVisible = visibleIDs; dismissed.subtract(visibleIDs); ended.subtract(visibleIDs)
        for id in visibleIDs { exitNative(id, pause: false) }
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
        if let tab = candidates.first(where: { isPlaying($0) && canPaint($0) }), let target = target(tab) {
            start(tab, aspect: states[tab.id]?.aspect ?? 16.0/9, target: target)
        } else if let tab = candidates.first(where: { isPlaying($0) && nativeFloats[$0.id] == nil }), let target = target(tab) {
            floatNatively(tab, target: target)
        } else if let tab = candidates.first {
            // A fast switch can outrun delivery of the video's play event.
            let token = UUID(); probeID = token
            let url = tab.url
            Self.call("return window.risePictureInPicture?.canFloat() ?? null", in: tab.webView) { [weak self, weak tab] value, _ in
                guard let self, self.probeID == token, let tab, tab.url == url,
                      self.browser?.tabs.contains(where: { $0 === tab }) == true,
                      !self.previousVisible.contains(tab.id), !self.dismissed.contains(tab.id), self.allowed(tab),
                      let found = value as? [String: Any], let aspect = found["aspect"] as? Double, aspect.isFinite, aspect > 0 else { return }
                self.start(tab, aspect: CGFloat(aspect), target: Target(key: found["frame"] as? String, info: nil))
            }
        }
    }

    func receive(_ message: WKScriptMessage) {
        guard let browser, let web = message.webView, let tab = browser.tabs.first(where: { $0.webView === web }),
              let body = message.body as? [String: Any], let frame = body["frame"] as? String else { return }
        let main = message.frameInfo.isMainFrame
        // The page's own reports must come from the page now showing.
        if main {
            guard SitePermissions.origin(message.frameInfo.securityOrigin) == SitePermissions.origin(web.url),
                  body["href"] as? String == web.url?.absoluteString else { return }
        }
        if let kind = body["kind"] as? String {
            guard let session = current, session.tab === tab, session.target.key == frame, !session.leaving,
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
        let youTubeElsewhere = main && YouTubeVideoPage.isYouTube(web.url) && !YouTubeVideoPage.containsVideo(web.url)
        if body["hasVideo"] as? Bool == true, !youTubeElsewhere {
            let aspect = (body["aspect"] as? Double).flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } ?? 16.0/9
            let state = VideoState(playing: body["playing"] as? Bool == true, paused: body["paused"] as? Bool != false,
                                   ended: body["ended"] as? Bool == true, encrypted: body["encrypted"] as? Bool == true, aspect: aspect)
            let playedAt = state.playing ? CACurrentMediaTime() : frameVideos[tab.id]?[frame]?.playedAt ?? 0
            frameVideos[tab.id, default: [:]][frame] = FrameVideo(state: state, info: message.frameInfo, playedAt: playedAt)
        } else {
            frameVideos[tab.id]?[frame] = nil
            if frameVideos[tab.id]?.isEmpty == true { frameVideos[tab.id] = nil }
            if let session = current, session.tab === tab, session.target.key == frame { restore(session, animated: true, pause: false) }
        }
        let chosen = chosenFrame(tab)
        states[tab.id] = chosen?.video.state
        guard let chosen, chosen.key == frame else { return }
        let state = chosen.video.state
        if state.playing { resumeAfterEnd(tab) }
        if let session = current, session.tab === tab, session.target.key == frame {
            endedTask?.cancel(); endedTask = nil
            if state.playing && !session.leaving { startPlaybackClock(session) }
            else { stopPlaybackClock(session) }
            if !session.leaving { session.panel.showPlayback(paused: state.paused) }
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
        guard ended.contains(tab.id), canPaint(tab), !floats(tab), !previousVisible.contains(tab.id), !dismissed.contains(tab.id), allowed(tab),
              browser?.tabs.contains(where: { $0 === tab }) == true else { return }
        guard let target = target(tab) else { return }
        ended.remove(tab.id); start(tab, aspect: states[tab.id]?.aspect ?? 16.0/9, target: target)
    }

    private func start(_ tab: BrowserTab, aspect: CGFloat, target: Target) {
        guard !floats(tab), let browser, allowed(tab), let screen = browser.window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        probeID = UUID()
        for id in Array(nativeFloats.keys) { exitNative(id, pause: true) }
        if let old = current {
            // Waiting for the old fade would leave the new player detached.
            departing[old.id] = old; current = nil
            restore(old, animated: true, pause: true)
        }
        let session = Session(tab: tab, panel: FloatingVideoWindow(aspectRatio: aspect, screen: screen, referenceWindow: browser.window), target: target)
        current = session
        session.panel.onClose = { [weak self] in self?.closeVideo() }
        session.panel.onReturn = { [weak self] in self?.returnToTab() }
        session.panel.onMinimize = { [weak self] in self?.minimizeVideo() }
        session.panel.onSeek = { [weak self, weak session] fraction, final in
            if let self, let session { self.seek(session, to: fraction, final: final) }
        }
        session.panel.onTogglePlayback = { [weak session] in
            session?.call("return window.risePictureInPicture?.togglePlayback() ?? null") { [weak session] value, _ in
                guard let session, !session.leaving, let paused = value as? Bool else { return }
                session.panel.showPlayback(paused: paused)
            }
        }
        session.panel.onVideoSizeChange = { [weak self, weak session] size, ratio in
            guard let self, let session, self.current === session, !session.leaving, let web = session.tab?.webView else { return }
            let zoom = web.pageZoom > 0 ? web.pageZoom : 1
            session.call("return window.risePictureInPicture?.resize(\(Self.canvasArguments(size, ratio, in: web))) ?? null") { [weak self, weak session] value, error in
                guard let self, let session, error == nil, let place = value as? [String: Any],
                      let x = place["x"] as? Double, let y = place["y"] as? Double else { return }
                // The old picture stays intact while the new one reaches the screen.
                let id = UUID()
                session.pendingCanvas = (id, size, NSPoint(x: x*zoom, y: y*zoom), session.paintsIssued)
                if session.playbackLink == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now()+0.05) { [weak self, weak session] in
                        if let self, let session, session.pendingCanvas?.id == id { self.showPendingCanvas(session) }
                    }
                }
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
        session.call("return await window.risePictureInPicture?.enter('\(token.uuidString)', \(arguments)) ?? false") { [weak self, weak session] value, error in
            guard let self, let session, self.current === session, session.transitionID == token else { return }
            if error != nil || value as? Bool != true { self.restore(session, animated: false, pause: false) }
            else if !session.leaving { session.panel.didResizeVideo(to: size); self.startPlaybackClock(session) }
        }
    }

    /// WebKit's own window can show encrypted video, which Rise's can't. It goes back
    /// inline when the tab is shown again; floating another video pauses it.
    private func floatNatively(_ tab: BrowserTab, target: Target) {
        if let old = current { departing[old.id] = old; current = nil; restore(old, animated: true, pause: true) }
        for id in Array(nativeFloats.keys) where id != tab.id { exitNative(id, pause: true) }
        nativeFloats[tab.id] = target
        Self.call("return window.risePictureInPicture?.enterNative() ?? false", in: tab.webView, frame: target.info) { [weak self, weak tab] value, _ in
            guard let self, let tab, value as? Bool != true, self.nativeFloats[tab.id]?.key == target.key else { return }
            self.nativeFloats[tab.id] = nil
        }
    }
    private func exitNative(_ id: UUID, pause: Bool) {
        guard let target = nativeFloats.removeValue(forKey: id), let tab = browser?.tabs.first(where: { $0.id == id }) else { return }
        Self.call("window.risePictureInPicture?.exitNative(\(pause))", in: tab.webView, frame: target.info) { _, _ in }
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
              session.pendingFrameID == nil, session.tab?.webView != nil else { return }
        let frameID = UUID(); session.pendingFrameID = frameID
        session.paintsIssued += 1
        let paint = session.paintsIssued
        session.call("return window.risePictureInPicture?.paint() ?? null") { [weak self, weak session] value, error in
            guard let self, let session, session.pendingFrameID == frameID else { return }
            session.pendingFrameID = nil
            // The video's frame went away, taking its picture with it.
            if error != nil, session.target.info != nil, self.current === session { self.restore(session, animated: true, pause: false); return }
            if let pending = session.pendingCanvas, paint > pending.afterPaint { self.showPendingCanvas(session) }
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

    private func showPendingCanvas(_ session: Session) {
        guard let pending = session.pendingCanvas else { return }
        session.pendingCanvas = nil
        guard current === session, !session.leaving else { return }
        session.panel.didResizeVideo(to: pending.size, at: pending.origin)
    }

    func returnToTab() {
        guard let sourceTabID, let browser, browser.tabs.contains(where: { $0.id == sourceTabID }) else { return }
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true); browser.select(sourceTabID)
    }
    private func seek(_ session: Session, to fraction: Double, final: Bool) {
        guard current === session, !session.leaving, fraction.isFinite else { return }
        if session.seeking { session.queuedSeek = (fraction, final); return }
        session.seeking = true
        session.call("return window.risePictureInPicture?.seek(\(fraction), \(final)) ?? null") { [weak self, weak session] value, _ in
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
        if pause { session.call("window.risePictureInPicture?.pause()") }
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
            configuration.rect = CGRect(origin: .zero, size: session.panel.videoHost.bounds.size)
            web.takeSnapshot(with: configuration) { image, _ in frozen = image; finish() }
        }
        session.call("window.risePictureInPicture?.exit()") { _, _ in finish() }
        // The page goes back to its tab with its frames in place.
        if session.target.info != nil { waiting += 1; lowerFrames(session) { finish() } }
    }
    /// A frame's video floats with the frames above it lifted over their pages.
    /// Putting them back from the top also covers a frame that has gone away.
    private func lowerFrames(_ session: Session, completion: @escaping () -> Void = {}) {
        guard session.target.info != nil else { completion(); return }
        Self.call("window.risePictureInPicture?.release()", in: session.tab?.webView) { _, _ in completion() }
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
        states.removeValue(forKey: tab.id); frameVideos.removeValue(forKey: tab.id); nativeFloats.removeValue(forKey: tab.id); dismissed.remove(tab.id); ended.remove(tab.id)
        var disposed = false
        if let session = current, session.tab === tab { dispose(session); current = nil; disposed = true }
        for session in departing.values.filter({ $0.tab === tab }) { dispose(session); departing.removeValue(forKey: session.id); disposed = true }
        return disposed
    }
    func tearDown() {
        endedTask?.cancel(); endedTask = nil; probeID = UUID()
        for id in Array(nativeFloats.keys) { exitNative(id, pause: true) }
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
        session.call("window.risePictureInPicture?.exit()"); lowerFrames(session)
        session.panel.closeImmediately()
    }

    static func call(_ body: String, in web: WKWebView?, frame: WKFrameInfo? = nil, completion: @escaping (Any?, Error?) -> Void) {
        guard let web else { completion(nil, nil); return }
        web.callAsyncJavaScript(body, arguments: [:], in: frame, in: contentWorld) { result in
            switch result {
            case .success(let value): completion(value, nil)
            case .failure(let error): completion(nil, error)
            }
        }
    }
}
