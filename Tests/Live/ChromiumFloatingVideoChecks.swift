// Rise's floating video on Chromium: a page's video, played with sound, floats in Rise's panel when
// its tab is left, keeps painting the moving video, plays and pauses from the panel, and goes back to
// its tab still playing. Run with scripts/test-chromium-live.py float.
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumFloatingVideoMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL timeout"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        _ = RCEngine.start(withCachePath: folder + "/chromium", keychain: false)
        let run = ChromiumFloatingVideoRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumFloatingVideoRun: NSObject, NSApplicationDelegate {
    let folder: URL; var browser: BrowserController!
    var passes = 0, failures = 0
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }
    func check(_ ok: Bool, _ message: String) { print("\(ok ? "PASS" : "FAIL") \(message)"); if ok { passes += 1 } else { failures += 1 } }
    func value(_ script: String, in page: WebPage) async -> Any? { (try? await page.evaluate(script, arguments: [:], in: nil, world: .page)) ?? nil }
    func waitUntil(_ seconds: Double, pollMilliseconds: Int = 100, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(pollMilliseconds)) }
        return await condition()
    }
    func pixels(_ image: NSImage?) -> [UInt8]? {
        guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32*18*4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(data: buffer.baseAddress, width: 32, height: 18, bitsPerComponent: 8, bytesPerRow: 32*4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        return bytes
    }
    func spread(_ p: [UInt8]?) -> Int { guard let p else { return -1 }; let v = p.enumerated().filter { $0.offset % 4 != 3 }.map { Int($0.element) }; return (v.max() ?? 0)-(v.min() ?? 0) }
    func shot(_ window: NSWindow, _ name: String) {
        if let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
            // The lightweight HTTP fixture server has no byte-range support. A real
            // file blob gives Chromium a seekable source, including during momentum.
            try "<!doctype html><title>Video</title><body style='margin:0;background:#222'><video id=v width=640 height=360 loop playsinline></video><script>fetch('clip.mp4').then(r=>r.blob()).then(blob=>document.querySelector('video').src=URL.createObjectURL(blob));</script>".write(to: folder.appendingPathComponent("video.html"), atomically: true, encoding: .utf8)
            try "<!doctype html><title>Other</title><h1>Other</h1>".write(to: folder.appendingPathComponent("other.html"), atomically: true, encoding: .utf8)
            let suite = "Rise.FloatingVideoCheck.\(UUID())", preferences = UserDefaults(suiteName: suite)!
            defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
            browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
            browser.window?.setFrameAutosaveName("")
            browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            let video = browser.addTab(url: URL(string: "http://localhost:\(port)/video.html")!)
            _ = await waitUntil(15) { await self.value("return document.querySelector('video').readyState >= 3", in: video.page) as? Bool == true }
            _ = await value("const v = document.querySelector('video'); v.muted = false; v.volume = 1; await v.play(); return true", in: video.page)
            let playing = await waitUntil(5) { await self.value("const v = document.querySelector('video'); return !v.paused && !v.muted && v.currentTime > 1", in: video.page) as? Bool == true }
            check(playing, "The video plays with sound")
            try? await Task.sleep(for: .seconds(1))
            let other = browser.addTab(url: URL(string: "http://localhost:\(port)/other.html")!)
            browser.select(other.id)
            let floated = await waitUntil(8) { self.browser.pictureInPicture.panel?.alphaValue == 1 && self.browser.pictureInPicture.panel?.hasVideoFrame == true }
            check(floated && browser.pictureInPicture.sourceTabID == video.id, "Leaving its tab floats it in Rise's panel")
            guard floated, let panel = browser.pictureInPicture.panel else { finish(); return }
            try? await Task.sleep(for: .milliseconds(500))
            shot(panel, "floating")
            let rect = panel.videoHost.bounds
            let first = pixels(await (video.page as? ChromiumPage)?.snapshot(rect: rect))
            let frames = panel.renderedFrameCount
            try? await Task.sleep(for: .milliseconds(1500))
            let later = pixels(await (video.page as? ChromiumPage)?.snapshot(rect: rect))
            check(panel.renderedFrameCount > frames+10, "The picture keeps painting (\(panel.renderedFrameCount-frames) frames in 1.5 s)")
            check(spread(first) > 30 && first != later, "It shows the moving video, not a blank picture (spread \(spread(first)))")
            let time = await value("return document.querySelector('video').currentTime", in: video.page) as? Double ?? 0
            panel.onTogglePlayback?()
            check(await waitUntil(3) { await self.value("return document.querySelector('video').paused", in: video.page) as? Bool == true }, "Its play button pauses the video")
            panel.onTogglePlayback?()
            check(await waitUntil(5) { await self.value("const v = document.querySelector('video'); return !v.paused && v.currentTime > \(time+0.2)", in: video.page) as? Bool == true }, "...and plays it again")
            let progress = panel.overlay.progress
            panel.onSeek?(0.25, true)
            check(await waitUntil(3) { abs(progress.fraction-0.25) < 0.04 }, "The seek bar is ready for a trackpad scrub")
            let pointer = panel.convertPoint(toScreen: progress.convert(NSPoint(x: progress.bounds.midX, y: progress.bounds.midY), to: nil))
            let placement = panel.frame
            panel.handleScroll(.init(phase: .began, timestamp: 1), pointer: pointer)
            panel.handleScroll(.init(phase: .changed, translation: CGVector(dx: 100, dy: 0), timestamp: 1.1), pointer: pointer)
            panel.handleScroll(.init(phase: .ended, timestamp: 1.2), pointer: pointer)
            panel.handleScroll(.init(phase: [], momentumPhase: .changed, translation: CGVector(dx: 100, dy: 0), timestamp: 1.3), pointer: .zero)
            let destination = progress.fraction
            panel.handleScroll(.init(phase: [], momentumPhase: .ended, timestamp: 1.4), pointer: .zero)
            check(await waitUntil(3) {
                await self.value("const v=document.querySelector('video');return !v.paused && Math.abs(v.currentTime-v.duration*\(destination))<0.8", in: video.page) as? Bool == true
            }, "Two-finger scrubbing and native flick momentum seek the playing video")
            check(panel.frame == placement && !panel.isDragging, "Scrubbing never drags the PiP window")
            check(spread(pixels(await (video.page as? ChromiumPage)?.snapshot(rect: rect))) > 30, "The still picture for going back is the video")
            browser.pictureInPicture.returnToTab()
            let back = await waitUntil(4) { self.browser.pictureInPicture.panel == nil && video.page.view.window === self.browser.window }
            check(back && browser.selectedID == video.id, "Back-to-tab returns it to its tab")
            try? await Task.sleep(for: .milliseconds(600))
            check(await waitUntil(3) { await self.value("return !document.querySelector('video').paused", in: video.page) as? Bool == true }, "It keeps playing after it returns")
            if let window = browser.window { shot(window, "returned") }
            browser.select(other.id)
            check(await waitUntil(8) { self.browser.pictureInPicture.panel?.alphaValue == 1 }, "Leaving the tab floats the video again")
            if let next = browser.pictureInPicture.panel {
                let videoRect = next.videoFrame.offsetBy(dx: -next.frame.minX, dy: -next.frame.minY)
                let at = NSPoint(x: videoRect.minX+26, y: videoRect.maxY-26)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    next.sendEvent(NSEvent.mouseEvent(with: type, location: at, modifierFlags: .shift,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: next.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                }
                check(await waitUntil(4) { self.browser.pictureInPicture.panel == nil }, "Shift-clicking X hides Picture in Picture")
                let backgroundPlaying = await value("return !document.querySelector('video').paused", in: video.page) as? Bool == true
                check(browser.selectedID == other.id && backgroundPlaying,
                      "Shift–X keeps it playing in the background without switching tabs")
            }
            browser.select(video.id); browser.setSidebarVisible(false)
            _ = await waitUntil(2) { !self.browser.sidebarFloat.isVisible }
            browser.pageFullscreen.setSimulated(true, in: browser.tabs.map(\.page))
            _ = await value("await document.querySelector('video').requestFullscreen();return true", in: video.page)
            check(await waitUntil(4) { self.browser.pageFullscreen.isActive(in: video.page.view) }, "The video enters simulated fullscreen")
            let belowBar = browser.pageClip.convert(NSPoint(x: 300, y: 100), to: nil)
            browser.refreshFullscreenNavigation(pointer: belowBar)
            check(await waitUntil(2) { self.browser.navBar.isFullscreenHidden && self.browser.navBar.frame.maxY <= 0.01 }, "The URL bar slides above simulated fullscreen")
            let fullFrame = video.page.view.frame
            let viewport = await value("return innerHeight", in: video.page) as? Double
            check(fullFrame.minY == 0 && fullFrame.height == browser.pageClip.bounds.height, "The video fills the URL bar's old space")
            let top = browser.pageClip.convert(NSPoint(x: 300, y: 20), to: nil)
            if let window = browser.window {
                window.sendEvent(NSEvent.mouseEvent(with: .mouseMoved, location: top, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
            }
            check(!browser.navBar.isFullscreenHidden, "Pointer movement into the top strip reveals the URL bar")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(await waitUntil(1, pollMilliseconds: 8) {
                    // Keep the injected hover in place without moving the user's
                    // real cursor, whose tracking events may arrive while it slides.
                    self.browser.refreshFullscreenNavigation(pointer: top)
                    let y = self.browser.navBar.frame.minY
                    return y > -PlainNavBar.Metrics.height+1 && y < -1 && self.browser.navBar.alphaValue == 1
                }, "The URL bar travels down from the top without fading")
                let moving = browser.navBar.frame
                browser.refreshFullscreenNavigation(pointer: belowBar)
                check(browser.navBar.frame == moving, "Leaving during the slide reverses from its current position")
                browser.refreshFullscreenNavigation(pointer: top)
                check(browser.navBar.frame == moving, "Re-entering during the slide continues without a jump")
            }
            check(await waitUntil(2) {
                self.browser.refreshFullscreenNavigation(pointer: top)
                return !self.browser.navBar.isFullscreenHidden && abs(self.browser.navBar.frame.minY) < 0.01
            }, "Hovering over the top slides the URL bar back in")
            check(browser.navBar.alphaValue == 1, "The sliding URL bar keeps its full opacity")
            let afterHover = await value("return innerHeight", in: video.page) as? Double
            check(video.page.view.frame == fullFrame && afterHover == viewport, "Hover does not resize the real video viewport")
            browser.setSidebarVisible(true)
            browser.refreshFullscreenNavigation(pointer: belowBar)
            check(!browser.navBar.isFullscreenHidden, "An open sidebar always keeps the URL bar visible")
            browser.setSidebarVisible(false)
            browser.setAutoHidesFullscreenNavigation(false)
            check(!browser.navBar.isFullscreenHidden && video.page.view.frame.minY == PlainNavBar.Metrics.height,
                  "Disabling auto-hide restores the permanent URL bar")
            _ = await value("await document.exitFullscreen();return true", in: video.page)
            check(await waitUntil(3) { !self.browser.pageFullscreen.isActive(in: video.page.view) }, "Leaving fullscreen restores normal navigation")
            browser.setAutoHidesFullscreenNavigation(true)
            browser.setCollapsesSidebarInSimulatedFullscreen(true)
            browser.setSidebarVisible(true)
            _ = await waitUntil(2) { abs(self.browser.sidebarFloat.dockProgress-1) < 0.001 }
            _ = await value("await document.querySelector('video').requestFullscreen();return true", in: video.page)
            _ = await waitUntil(2) { self.browser.pageFullscreen.isActive(in: video.page.view) }
            browser.refreshFullscreenNavigation(pointer: browser.pageClip.convert(NSPoint(x: 300, y: 150), to: nil))
            check(!browser.sidebarVisible && browser.navBar.isFullscreenHidden, "Entering fullscreen starts closing both bars immediately")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(await simultaneousChromeMotion(opening: false), "Both bars visibly collapse at the same time")
            }
            _ = await waitUntil(2) {
                !self.browser.sidebarFloat.isVisible && abs(self.browser.navBar.frame.maxY) < 0.01
            }
            let leavingY = browser.navBar.frame.minY
            _ = await value("await document.exitFullscreen();return true", in: video.page)
            _ = await waitUntil(2) { !self.browser.pageFullscreen.isActive(in: video.page.view) }
            check(browser.sidebarVisible && !browser.navBar.isFullscreenHidden, "Leaving fullscreen starts restoring both bars immediately")
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(leavingY < -1 && browser.navBar.frame.minY < -1, "The navigation slides back instead of snapping in on fullscreen exit")
                check(await simultaneousChromeMotion(opening: true), "Both bars visibly return at the same time")
            }
            check(await waitUntil(2) {
                abs(self.browser.sidebarFloat.dockProgress-1) < 0.001 && abs(self.browser.navBar.frame.minY) < 0.01
            }, "Both bars finish back in their normal positions")
            finish()
        }
    }
    func simultaneousChromeMotion(opening: Bool) async -> Bool {
        let end = Date().addingTimeInterval(0.7)
        while Date() < end {
            let side = browser.sidebarFloat.dockProgress
            let top = 1+browser.navBar.frame.minY/PlainNavBar.Metrics.height
            if side > 0.03 && side < 0.97 && top > 0.03 && top < 0.97 {
                print("Chrome \(opening ? "opening" : "closing") progress: sidebar \(side), navigation \(top)")
                return abs(side-top) < 0.15
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
        return false
    }
    func finish() { print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1) }
}
