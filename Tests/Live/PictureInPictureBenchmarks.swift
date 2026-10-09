import AppKit
import WebKit
@testable import Rise

/// Floats real videos from a real Rise window: local fixtures in cross-origin frames,
/// then real sites, each played with sound, left for another tab, checked in the
/// floating window (a moving picture, its play button reaching the video) and brought
/// back to find the page as it was. RISE_PIP_FRAMES saves screenshots of the floating
/// window; RISE_PIP_ONLY runs the named cases (fixtures, sites, site:<name>).
@main @MainActor struct PictureInPictureBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = PictureInPictureVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}

/// Collects each frame as it loads, so a script can run inside a cross-origin frame.
final class PlayerFrames: NSObject, WKScriptMessageHandler {
    var frames: [String: WKFrameInfo] = [:]
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let href = message.body as? String { frames[href] = message.frameInfo }
    }
}

@MainActor final class PictureInPictureVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    var failures = 0, passes = 0
    var servers: [Process] = []
    let shots = ProcessInfo.processInfo.environment["RISE_PIP_FRAMES"].map { URL(fileURLWithPath: $0) }
    let only = ProcessInfo.processInfo.environment["RISE_PIP_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    let collector = PlayerFrames()
    let fixturePort = 8881, framePort = 8882

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ✓ \(message)" : "  ✗ \(message)"); if condition { passes += 1 } else { failures += 1 }
    }
    func capture(_ name: String, window: NSWindow?) {
        guard let shots, let window else { return }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", shots.appendingPathComponent("\(name).png").path]
        try? process.run(); process.waitUntilExit()
    }
    func wait(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }
    func shouldRun(_ name: String) -> Bool { only.map { $0.contains(name) } ?? true }

    @discardableResult func js(_ web: WKWebView, _ source: String, frame: WKFrameInfo? = nil) async -> Any? {
        do { return try await web.evaluateJavaScript(source, in: frame, contentWorld: .page) }
        catch { print("    (script error: \(error.localizedDescription))"); return nil }
    }
    func string(_ web: WKWebView, _ source: String, frame: WKFrameInfo? = nil) async -> String {
        let value = await js(web, source, frame: frame)
        if let value = value as? String { return value }
        return value.map { "\($0)" } ?? "nil"
    }
    func waitFor(_ web: WKWebView, _ condition: String, frame: WKFrameInfo? = nil, timeout: Double = 20) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await js(web, "(() => { try { return !!(\(condition)) } catch { return false } })()", frame: frame) as? Bool == true { return true }
            await wait(200)
        }
        return false
    }
    func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout { if condition() { return true }; await wait(50) }
        return condition()
    }
    func frameInfo(containing part: String) async -> WKFrameInfo? {
        for _ in 0..<60 {
            if let frame = collector.frames.first(where: { $0.key.contains(part) })?.value { return frame }
            await wait(250)
        }
        return nil
    }

    /// Media loads only from a server that answers range requests, which Python's own doesn't.
    static let rangeServer = """
    import http.server, os, sys
    class Handler(http.server.SimpleHTTPRequestHandler):
        def send_head(self):
            path = self.translate_path(self.path)
            spec = self.headers.get('Range')
            if not spec or not os.path.isfile(path): return super().send_head()
            size = os.path.getsize(path)
            start, _, end = spec.replace('bytes=', '').partition('-')
            start = int(start or 0); end = min(int(end) if end else size-1, size-1)
            handle = open(path, 'rb'); handle.seek(start)
            self.send_response(206)
            self.send_header('Content-Type', self.guess_type(path))
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
            self.send_header('Content-Length', str(end-start+1))
            self.send_header('Accept-Ranges', 'bytes')
            self.end_headers()
            self.range_left = end-start+1
            return handle
        def copyfile(self, source, destination):
            left = getattr(self, 'range_left', None)
            if left is None: return super().copyfile(source, destination)
            destination.write(source.read(left))
        def log_message(self, *args): pass
    os.chdir(sys.argv[2])
    http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
    """
    static let deep = "const deep = (sel, root = document) => { const hit = root.querySelector(sel); if (hit) return hit; for (const el of root.querySelectorAll('*')) if (el.shadowRoot) { const found = deep(sel, el.shadowRoot); if (found) return found; } return null; };"
    /// The largest video, in shadow roots too.
    static let video = "(() => { const all = []; const walk = root => { all.push(...root.querySelectorAll('video')); for (const el of root.querySelectorAll('*')) if (el.shadowRoot) walk(el.shadowRoot); }; walk(document); return all.sort((a, b) => b.clientWidth*b.clientHeight - a.clientWidth*a.clientHeight)[0]; })()"

    /// A real click in the middle of the main frame's video, through the window like a user's.
    func mouseClick(_ web: WKWebView) async {
        guard let point = await js(web, "(() => { const r = \(Self.video).getBoundingClientRect(); return [r.left + r.width/2, r.top + r.height/2] })()") as? [Double],
              point.count == 2, let window = browser.window else { return }
        let location = web.convert(NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height-point[1]), to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
            await wait(type == .mouseMoved ? 300 : 40)
        }
        await wait(800)
    }
    /// Whether the page itself can draw its video into a canvas.
    static let drawProbe = "(() => { const v = \(video); const c = document.createElement('canvas'); c.width = 64; c.height = 36; const x = c.getContext('2d'); x.drawImage(v, 0, 0, 64, 36); try { const d = x.getImageData(0, 0, 64, 36).data; let lo = 255, hi = 0; for (let i = 0; i < d.length; i += 4) { lo = Math.min(lo, d[i], d[i+1], d[i+2]); hi = Math.max(hi, d[i], d[i+1], d[i+2]); } return 'drawn spread ' + (hi-lo) + ' src ' + v.currentSrc.slice(-50) + ' time ' + v.currentTime.toFixed(1); } catch (e) { return 'unreadable ' + e.name + ' src ' + v.currentSrc.slice(-50); } })()"
    /// A small, downsampled picture of what the floating window shows.
    func picture(_ web: WKWebView, _ panel: FloatingVideoWindow) async -> [UInt8]? {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = panel.videoHost.bounds
        guard let image = try? await web.takeSnapshot(configuration: configuration),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32*18*4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 32*4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        return bytes
    }
    func spread(_ pixels: [UInt8]) -> Int {
        let values = pixels.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }
        return (values.max() ?? 0)-(values.min() ?? 0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rise-pip-fixtures-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            writeFixtures(to: folder)
            for port in [fixturePort, framePort] {
                let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                server.arguments = ["-c", Self.rangeServer, "\(port)", folder.path]
                server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
                try? server.run(); servers.append(server)
            }
            await wait(800)
            let suite = "RisePiPLive.\(ProcessInfo.processInfo.processIdentifier)"
            browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false,
                                        preferences: UserDefaults(suiteName: suite)!)
            browser.window?.setContentSize(NSSize(width: 1280, height: 800)); browser.window?.center(); browser.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            for site in fixtureList + siteList where shouldRun("site:" + site.name) || shouldRun(site.fixture ? "fixtures" : "sites") {
                await run(site)
            }
            print("\n\(passes) passed, \(failures) failed")
            servers.forEach { $0.terminate() }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            exit(failures == 0 ? 0 : 1)
        }
    }

    struct Site {
        let name: String, url: String
        /// Part of the player frame's address, when the video plays in a frame.
        var frame: String? = nil
        /// Runs in the player's frame before playback starts, as a click on a site's own play button.
        var prepare: String? = nil
        /// Starts playback with a real click on the video, as a user would.
        var click = false
        /// Plays encrypted video, which floats in WebKit's own window.
        var encrypted = false
        /// Runs once it plays, as a seek past a black opening. VIDEO stands for the video played.
        var afterPlay: String? = nil
        var fixture = false
    }
    lazy var fixtureList: [Site] = [
        Site(name: "cross-origin-frame", url: "http://127.0.0.1:\(fixturePort)/frame.html", frame: "localhost:\(framePort)/video.html", fixture: true),
        Site(name: "nested-frames", url: "http://127.0.0.1:\(fixturePort)/nested.html", frame: "127.0.0.1:\(fixturePort)/video.html?nested", fixture: true),
        Site(name: "cross-origin-video", url: "http://127.0.0.1:\(fixturePort)/remote.html", fixture: true),
    ]
    let siteList: [Site] = [
        Site(name: "youtube", url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", prepare: "document.querySelector('#movie_player')?.unMute?.(); 0", click: true),
        Site(name: "seedbox", url: "https://seedbox.bartoszbak.org/media/e1_bW92aWU6bTFfY1dKcGRIUnZjbkpsYm5RdlFtOXlZWFF1UTNWc2RIVnlZV3d1VEdWaGNtNXBibWR6TG05bUxrRnRaWEpwWTJFdVptOXlMazFoYTJVdVFtVnVaV1pwZEM1SGJHOXlhVzkxY3k1T1lYUnBiMjR1YjJZdVMyRjZZV3RvYzNSaGJpNHlNREEyTGpFd09EQndMa2hWVEZVdVYwVkNMVVJNTGtSRVVEVXVNUzVJTGpJMk5DMUNURTlQVFM1dGEzWQ",
             prepare: "document.querySelector('button[aria-label=\"Play\"]')?.click(); 0"),
        Site(name: "vimeo", url: "https://player.vimeo.com/video/76979871", click: true, encrypted: true),
        Site(name: "youtube-embed", url: "http://127.0.0.1:8881/embed.html", frame: "youtube.com/embed",
             prepare: "document.querySelector('.ytp-large-play-button')?.click(); const p = document.querySelector('#movie_player'); p?.unMute?.(); p?.playVideo?.(); 0"),
        Site(name: "vimeo-embed", url: "http://127.0.0.1:8881/embed.html", frame: "player.vimeo.com", encrypted: true),
        Site(name: "plyr", url: "https://plyr.io"),
        Site(name: "shaka", url: "https://shaka-player-demo.appspot.com/demo/#audiolang=en-US;textlang=en-US;uilang=en-US;asset=https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd;panel=HOME;build=uncompiled",
             afterPlay: "VIDEO.currentTime = 20; 0"),
        Site(name: "w3schools", url: "https://www.w3schools.com/html/html5_video.asp"),
        Site(name: "mdn-frame", url: "https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/video", frame: "Elements/video/runner.html",
             afterPlay: "VIDEO.currentTime = 30; 0"),
        Site(name: "archive-jwplayer", url: "https://archive.org/embed/BigBuckBunny_124", prepare: "document.querySelector('.jw-display-icon-display, .jw-icon-display')?.click(); window.jwplayer?.().play?.(); 0",
             afterPlay: "VIDEO.currentTime = 30; 0"),
        Site(name: "ted", url: "https://www.ted.com/talks/sir_ken_robinson_do_schools_kill_creativity",
             afterPlay: "[...document.querySelectorAll('button')].find(b => /unmute/i.test(b.getAttribute('aria-label') || b.textContent))?.click(); 0"),
    ]

    func run(_ site: Site) async {
        print("\n\(site.fixture ? "Fixture" : "Site"): \(site.name)")
        collector.frames = [:]
        let tab = browser.addTab()
        tab.webView.configuration.userContentController.add(collector, contentWorld: .page, name: "probeFrames")
        tab.webView.configuration.userContentController.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.probeFrames.postMessage(location.href)", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        defer { tab.webView.configuration.userContentController.removeScriptMessageHandler(forName: "probeFrames", contentWorld: .page) }
        tab.load(URL(string: site.url)!)
        let web = tab.webView
        await wait(1500)
        let started = Date()
        while web.isLoading && Date().timeIntervalSince(started) < 25 { await wait(150) }
        await js(web, "[...document.querySelectorAll('button')].find(b => /^(reject all|accept all|accept|i agree|agree|allow all)$/i.test(b.textContent.trim()))?.click(); 0")
        var frame: WKFrameInfo?
        if let part = site.frame {
            frame = await frameInfo(containing: part)
            guard frame != nil else { check(false, "\(site.name): found the player frame (\(collector.frames.keys.joined(separator: ", ")))"); browser.closeTab(tab.id); return }
        }
        if let prepare = site.prepare { await wait(1500); await js(web, prepare, frame: frame); await wait(1500) }
        guard await waitFor(web, "\(Self.video)", frame: frame, timeout: 20) else {
            check(false, "\(site.name): found the video"); browser.closeTab(tab.id); return
        }
        // Plays with sound, as a user's click would.
        if site.click, await js(web, "(() => { const v = \(Self.video); return v.paused })()") as? Bool == true { await mouseClick(web) }
        await js(web, "(() => { const v = \(Self.video); v.muted = false; if (v.volume === 0) v.volume = 0.5; if (v.paused) v.play()?.catch?.(() => {}); return 0 })()", frame: frame)
        var playing = await waitFor(web, "(() => { const v = \(Self.video); return !v.paused && v.currentTime > 0.3 })()", frame: frame, timeout: 25)
        if playing, let afterPlay = site.afterPlay { await js(web, afterPlay.replacingOccurrences(of: "VIDEO", with: Self.video), frame: frame) }
        // Settled: some players pause or mute again a moment after starting.
        await wait(1500)
        playing = await waitFor(web, "(() => { const v = \(Self.video); return !v.paused && !v.muted && v.volume > 0 && v.readyState >= 2 })()", frame: frame, timeout: 3)
        check(playing, "\(site.name): plays with sound (\(await string(web, "(() => { const v = \(Self.video); return [v.paused, v.muted, v.currentTime.toFixed(1), v.readyState, v.videoWidth+'x'+v.videoHeight, !!v.mediaKeys].join() })()", frame: frame)))")
        guard playing else {
            capture("\(site.name)-not-playing", window: browser.window)
            print("    videos: \(await string(web, "[...document.querySelectorAll('video')].map(v => [v.readyState, v.videoWidth, v.currentSrc.slice(0, 50), v.error?.code].join('/')).join(' | ') + ' / ' + document.title", frame: frame))")
            browser.closeTab(tab.id); return
        }
        let liftedBefore = await string(web, "document.querySelectorAll(':popover-open').length")
        let styleBefore = await string(web, "[...document.querySelectorAll('iframe')].map(f => f.getAttribute('style')).join('|')")

        let other = browser.addTab()
        if site.encrypted {
            let native = await waitFor(web, "\(Self.video).webkitPresentationMode === 'picture-in-picture'", frame: frame, timeout: 5)
            check(native && browser.pictureInPicture.panel == nil, "\(site.name): encrypted video floats in WebKit's own picture in picture")
            if !native {
                print("    page says \(await string(web, "(() => { const v = \(Self.video); return [v.webkitPresentationMode, v.webkitSupportsPresentationMode?.('picture-in-picture'), document.pictureInPictureEnabled, v.disablePictureInPicture].join() })()", frame: frame))")
                let attempt = try? await web.evaluateJavaScript("(() => { try { return JSON.stringify([window.risePictureInPicture.describe(), window.risePictureInPicture.enterNative()]) } catch (e) { return 'threw ' + e } })()", in: frame, contentWorld: VideoPictureInPicture.contentWorld)
                print("    entering now: \(attempt ?? "nil")")
                await wait(1000)
                print("    mode after: \(await string(web, "\(Self.video).webkitPresentationMode", frame: frame))")
            }
            await wait(1500)
            let stillPlaying = await waitFor(web, "!\(Self.video).paused", frame: frame, timeout: 2)
            check(stillPlaying, "\(site.name): ...and keeps playing there")
            browser.select(tab.id)
            let inline = await waitFor(web, "\(Self.video).webkitPresentationMode === 'inline'", frame: frame, timeout: 5)
            check(inline, "\(site.name): it comes back inline when the tab is shown")
            browser.closeTab(other.id); browser.closeTab(tab.id)
            return
        }
        let floated = await waitUntil(6) { browser.pictureInPicture.panel?.alphaValue == 1 && browser.pictureInPicture.panel?.hasVideoFrame == true }
        check(floated && browser.pictureInPicture.sourceTabID == tab.id, "\(site.name): floats when its tab is left")
        if floated, let panel = browser.pictureInPicture.panel {
            await wait(400)
            capture("\(site.name)-floating", window: panel)
            let first = await picture(web, panel)
            let frames = panel.renderedFrameCount
            await wait(1500)
            let later = await picture(web, panel)
            check(panel.renderedFrameCount > frames+10, "\(site.name): the picture keeps painting (\(panel.renderedFrameCount-frames) frames in 1.5 s)")
            check(first.map(spread) ?? 0 > 30 && first != later, "\(site.name): shows the moving video, not a blank picture (spread \(first.map(spread) ?? -1))")
            if first.map(spread) ?? 0 <= 30 || first == later {
                print("    page draws: \(await string(web, Self.drawProbe, frame: frame))")
            }
            let time = await js(web, "\(Self.video).currentTime", frame: frame) as? Double ?? 0
            panel.onTogglePlayback?()
            let paused = await waitFor(web, "\(Self.video).paused", frame: frame, timeout: 3)
            check(paused, "\(site.name): the picture's play button pauses the video")
            panel.onTogglePlayback?()
            let resumed = await waitFor(web, "!\(Self.video).paused && \(Self.video).currentTime > \(time+0.2)", frame: frame, timeout: 5)
            check(resumed, "\(site.name): ...and plays it again")
            browser.pictureInPicture.returnToTab()
            let back = await waitUntil(4) { browser.pictureInPicture.panel == nil && web.superview === browser.pageClip }
            check(back && browser.selectedID == tab.id, "\(site.name): returns to its tab")
            await wait(600)
            let still = await waitFor(web, "!\(Self.video).paused", frame: frame, timeout: 3)
            check(still, "\(site.name): keeps playing after it returns")
            let liftedAfter = await string(web, "document.querySelectorAll(':popover-open').length")
            let styleAfter = await string(web, "[...document.querySelectorAll('iframe')].map(f => f.getAttribute('style')).join('|')")
            let canvases = await string(web, "[...document.querySelectorAll('canvas')].filter(c => c.style.zIndex === '2147483647').length", frame: frame)
            check(liftedAfter == liftedBefore && styleAfter == styleBefore && canvases == "0", "\(site.name): the page is left as it was (lifted \(liftedBefore)→\(liftedAfter), canvases \(canvases))")
        } else {
            capture("\(site.name)-missing", window: browser.window)
            let probe = "JSON.stringify({float: window.risePictureInPicture?.canFloat() ?? null, script: !!window.risePictureInPicture, videos: window.risePictureInPicture?.describe(), top: window === window.top, video: (() => { const v = \(Self.video); return v && [v.paused, v.muted, v.volume, v.readyState, v.currentTime.toFixed(1), v.isConnected].join() })()})"
            let state = try? await web.evaluateJavaScript(probe, in: frame, contentWorld: VideoPictureInPicture.contentWorld)
            let drawn = await string(web, Self.drawProbe, frame: frame)
            print("    \(drawn)")
            print("    floating script says \(state ?? "nil"); panel \(String(describing: browser.pictureInPicture.panel)) source \(String(describing: browser.pictureInPicture.sourceTabID))")
        }
        browser.closeTab(other.id)
        browser.closeTab(tab.id)
        _ = await waitUntil(2) { browser.pictureInPicture.panel == nil }
    }

    func writeFixtures(to folder: URL) {
        let video = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("RiseTests/Resources/PiPTestVideo.mp4")
        try? FileManager.default.copyItem(at: video, to: folder.appendingPathComponent("video.mp4"))
        let page = """
        <!doctype html><meta charset=utf-8><body style="margin:0;background:#305090">
        <video loop playsinline controls style="width:100%" src="http://127.0.0.1:\(fixturePort)/video.mp4"></video>
        """
        // The frame sits clipped and scaled under a fixed banner, as sites embed them.
        let frame = """
        <!doctype html><meta charset=utf-8><title>Framed video</title>
        <body style="margin:0;padding:20px;font:14px -apple-system;min-height:3000px;background:rgb(144,80,64)">
        <div style="overflow:hidden;width:280px;height:150px;transform:scale(0.8);position:relative;z-index:1">
        <iframe id=player style="width:320px;height:180px;border:4px solid blue" src="http://localhost:\(framePort)/video.html" allow="autoplay"></iframe>
        </div>
        <div style="position:fixed;left:0;right:0;bottom:0;height:120px;background:orange;z-index:2147483647">A banner on top of everything</div>
        """
        let nested = """
        <!doctype html><meta charset=utf-8><title>Nested frames</title>
        <body style="margin:0;padding:20px;background:rgb(144,80,64)">
        <iframe id=outer style="width:420px;height:260px" src="http://localhost:\(framePort)/middle.html" allow="autoplay"></iframe>
        """
        let middle = """
        <!doctype html><meta charset=utf-8><body style="margin:0;background:#ddd">Middle
        <iframe style="width:320px;height:180px;transform:rotate(3deg)" src="http://127.0.0.1:\(fixturePort)/video.html?nested" allow="autoplay"></iframe>
        """
        let embed = """
        <!doctype html><meta charset=utf-8><title>Embedded players</title>
        <body style="margin:0;padding:20px;font:14px -apple-system">
        <div style="transform: scale(0.9); transform-origin: top left">
        <iframe width=560 height=315 src="https://www.youtube.com/embed/aqz-KE-bpKQ?autoplay=1&mute=1" allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe>
        <iframe width=560 height=315 src="https://player.vimeo.com/video/76979871?autoplay=1&muted=1" allow="autoplay; fullscreen" allowfullscreen></iframe>
        </div>
        """
        // The video comes from another origin, which sends no CORS headers.
        let remote = """
        <!doctype html><meta charset=utf-8><title>Remote video</title>
        <body style="margin:0;padding:20px;background:rgb(144,80,64)">
        <video loop playsinline controls style="width:480px" src="http://localhost:\(framePort)/video.mp4"></video>
        """
        for (name, html) in [("video", page), ("remote", remote), ("frame", frame), ("nested", nested), ("middle", middle), ("embed", embed)] {
            try? html.write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        }
    }
}
