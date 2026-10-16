// Any site's floating video, the tab's play and sound buttons, and page full screen on Chromium: the
// XCTest cases these were written as, run in Rise windows (Tests/Live/LiveXCTest.swift), with pages
// at the addresses they name. Run with scripts/test-chromium-live.py media; RISE_CASES=<names> runs some.
import AppKit
import RiseCore
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumMediaMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+1200) { print("DONE timeout"); exit(0) }
        let app = RCApplication.shared
        _ = RCEngine.start(withCachePath: LiveFixtures.folder.path + "/chromium", keychain: false)
        let run = ChromiumMediaRun()
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumMediaRun: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await PageFullscreenCases().runAll()
            await VideoPictureInPictureCases().runAll()
            await TabMediaCases().runAll()
            await TabAudioCases().runAll()
            liveFinish()
        }
    }
}

/// Rise's full-screen script, in a Rise tab.
@MainActor final class PageFullscreenCases {
    private var suites: [String] = []
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        for (name, run) in [("SimulatedFullscreenLiftsTheElementOverThePageAndLeavesCleanly", testSimulatedFullscreenLiftsTheElementOverThePageAndLeavesCleanly),
                            ("NativeModeLeavesTheFullscreenAPIToChromium", testNativeModeLeavesTheFullscreenAPIToChromium),
                            ("ScriptReportsEntryReplacementExitAndElementRemovalToTheBrowser", testScriptReportsEntryReplacementExitAndElementRemovalToTheBrowser),
                            ("SwitchingModesChangesTheScriptForLaterPages", testSwitchingModesChangesTheScriptForLaterPages)]
        where only?.contains(name) ?? true {
            await liveCase(name) { try await run() }
            suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }; suites = []
        }
    }
    private func browser(simulated: Bool) -> BrowserController {
        let suite = "Rise.FullscreenChecks.\(UUID().uuidString)"; suites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(simulated, forKey: PageFullscreen.simulatedKey)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName(""); browser.window?.center(); browser.showWindow(nil)
        return browser
    }
    private func clean(_ browser: BrowserController) {
        browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    private func page(in browser: BrowserController) async throws -> NSView {
        let tab = browser.addTab(), web = tab.web
        web.loadHTMLString("""
        <style> #box:fullscreen { outline: 3px solid rgb(0, 128, 0) } .wrap { transform: scale(0.5); overflow: hidden; width: 300px; height: 200px } </style>
        <div class=wrap><div id=box style="width:100px;height:50px">box</div></div>
        <script> window.events = []; document.addEventListener('fullscreenchange', () => events.push(document.fullscreenElement?.id || 'null')); </script>
        """, baseURL: URL(string: "https://fullscreen.example/"))
        for _ in 0..<200 {
            if !web.isLoading, web.url?.host == "fullscreen.example", (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        return web
    }
    private func value(_ web: NSView, _ source: String) async throws -> String {
        let result = try await web.evaluateJavaScript(source)
        return result.map { "\($0)" } ?? "nil"
    }

    func testSimulatedFullscreenLiftsTheElementOverThePageAndLeavesCleanly() async throws {
        let browser = browser(simulated: true); defer { clean(browser) }
        let web = try await page(in: browser)
        _ = try await web.evaluateJavaScript("box.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        let size = try await value(web, "[innerWidth, innerHeight].join()")
        let rect = try await value(web, "const r = box.getBoundingClientRect(); [r.left, r.top, r.width, r.height].join()")
        XCTAssertEqual(rect, "0,0,\(size)", "A transformed, clipped ancestor can't hold the element back")
        let element = try await value(web, "document.fullscreenElement.id")
        XCTAssertEqual(element, "box")
        let outline = try await value(web, "getComputedStyle(box).outlineColor")
        XCTAssertEqual(outline, "rgb(0, 128, 0)", "The page's :fullscreen rule applies")
        XCTAssertFalse(browser.window?.styleMask.contains(.fullScreen) == true, "The window stays as it was")
        _ = try await web.evaluateJavaScript("document.exitFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        let events = try await value(web, "events.join()")
        XCTAssertEqual(events, "box,null")
        let leftovers = try await value(web, "document.querySelectorAll('[data-rise-fullscreen], [data-rise-fullscreen-ancestor], [popover]').length")
        XCTAssertEqual(leftovers, "0")
    }

    func testNativeModeLeavesTheFullscreenAPIToChromium() async throws {
        let browser = browser(simulated: false); defer { clean(browser) }
        let web = try await page(in: browser)
        let simulated = try await value(web, "String(window.__riseFullscreen.simulated)")
        XCTAssertEqual(simulated, "false")
        // Long after the script's click, which Chromium honours for 5 s, so it refuses rather
        // than taking over the screen.
        _ = try await web.evaluateJavaScript("setTimeout(() => box.requestFullscreen().catch(e => window.refused = e.name), 5500); 0")
        try await Task.sleep(for: .milliseconds(6000))
        let refused = try await value(web, "window.refused")
        XCTAssertEqual(refused, "TypeError", "Chromium's own requestFullscreen answered")
        let pinned = try await value(web, "document.querySelectorAll('[data-rise-fullscreen]').length")
        XCTAssertEqual(pinned, "0", "Native mode never pins the element itself")
    }

    func testScriptReportsEntryReplacementExitAndElementRemovalToTheBrowser() async throws {
        let browser = browser(simulated: true); defer { clean(browser) }
        let fullscreen = browser.pageFullscreen
        let web = try await page(in: browser)
        var changes: [Bool] = []
        let previous = fullscreen.onChange
        fullscreen.onChange = { previous?(); changes.append(fullscreen.isActive(in: web)) }
        defer { fullscreen.onChange = previous }
        _ = try await web.evaluateJavaScript("box.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fullscreen.isActive(in: web))
        _ = try await web.evaluateJavaScript("const next = document.createElement('div'); next.id = 'next'; document.body.append(next); next.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(changes, [true], "Replacing the element must not briefly reopen the sidebar")
        _ = try await web.evaluateJavaScript("document.exitFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(changes, [true, false])
        _ = try await web.evaluateJavaScript("box.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.evaluateJavaScript("box.remove(); 0")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(changes, [true, false, true, false])
    }

    func testSwitchingModesChangesTheScriptForLaterPages() async throws {
        let browser = browser(simulated: false); defer { clean(browser) }
        XCTAssertFalse(browser.pageFullscreen.isSimulated, "Simulated fullscreen is off unless chosen")
        let web = try await page(in: browser)
        let before = try await value(web, "String(window.__riseFullscreen.simulated)")
        XCTAssertEqual(before, "false")
        browser.pageFullscreen.setSimulated(true, in: browser.tabs.map(\.page))
        let reloaded = try await page(in: browser)
        let after = try await value(reloaded, "String(window.__riseFullscreen.simulated) + ' ' + document.querySelectorAll('script').length")
        XCTAssertEqual(after, "true 1", "Later pages get the simulated script, once")
    }
}
@MainActor final class VideoPictureInPictureCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("AnySitesVideoWithSoundFloatsAndReturnsUntouched") ?? true { await liveCase("AnySitesVideoWithSoundFloatsAndReturnsUntouched") { try await self.testAnySitesVideoWithSoundFloatsAndReturnsUntouched(); self.tearDown() } }
        if only?.contains("MutedPausedAndBlockedVideosStayInline") ?? true { await liveCase("MutedPausedAndBlockedVideosStayInline") { try await self.testMutedPausedAndBlockedVideosStayInline(); self.tearDown() } }
        if only?.contains("VideoInAFrameFloatsWithItsFrameLiftedAndPutBack") ?? true { await liveCase("VideoInAFrameFloatsWithItsFrameLiftedAndPutBack") { try await self.testVideoInAFrameFloatsWithItsFrameLiftedAndPutBack(); self.tearDown() } }
        if only?.contains("VideoTwoFramesDownFloats") ?? true { await liveCase("VideoTwoFramesDownFloats") { try await self.testVideoTwoFramesDownFloats(); self.tearDown() } }
        if only?.contains("VideoInAShadowRootFloats") ?? true { await liveCase("VideoInAShadowRootFloats") { try await self.testVideoInAShadowRootFloats(); self.tearDown() } }
        if only?.contains("RemovingTheFloatingFramePutsThePageBack") ?? true { await liveCase("RemovingTheFloatingFramePutsThePageBack") { try await self.testRemovingTheFloatingFramePutsThePageBack(); self.tearDown() } }
        if only?.contains("TheFrameHeardLastFloatsAndPausingInThePictureReachesIt") ?? true { await liveCase("TheFrameHeardLastFloatsAndPausingInThePictureReachesIt") { try await self.testTheFrameHeardLastFloatsAndPausingInThePictureReachesIt(); self.tearDown() } }
        if only?.contains("MinimizingLeavesNoOtherPictureBehind") ?? true { await liveCase("MinimizingLeavesNoOtherPictureBehind") { try await self.testMinimizingLeavesNoOtherPictureBehind(); self.tearDown() } }
        if only?.contains("AFrameNavigatingAwayWhileFloatingPutsThePageBack") ?? true { await liveCase("AFrameNavigatingAwayWhileFloatingPutsThePageBack") { try await self.testAFrameNavigatingAwayWhileFloatingPutsThePageBack(); self.tearDown() } }
        if only?.contains("SandboxedFrameFloats") ?? true { await liveCase("SandboxedFrameFloats") { try await self.testSandboxedFrameFloats(); self.tearDown() } }
        if only?.contains("AFrameInAHiddenContainerStaysInline") ?? true { await liveCase("AFrameInAHiddenContainerStaysInline") { try await self.testAFrameInAHiddenContainerStaysInline(); self.tearDown() } }
    }
    private var preferenceSuites: [String] = []
    func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        preferenceSuites = []
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.VideoPiPTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.center()
        browser.showWindow(nil); browser.pictureInPicture.reduceMotion = { true }
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.pictureInPicture.tearDown(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "VideoPiPTests", code: 1)
    }
    private func videoSource() throws -> String {
        let file = LiveFixtures.repository("Tests/RiseTests/Resources/PiPTestVideo.mp4")
        return "data:video/mp4;base64," + (try Data(contentsOf: file).base64EncodedString())
    }
    /// A page whose `playing` expression turns true once its video plays.
    @MainActor private func page(_ html: String, in browser: BrowserController, playing: String) async throws -> BrowserTab {
        let tab = browser.addTab()
        tab.web.loadHTMLString("<!doctype html><title>Video</title><body style='margin:0;background:rgb(144,80,64)'>\(html)",
                                   baseURL: URL(string: "https://videos.example/"))
        try await wait("video plays") {
            guard !tab.web.isLoading else { return false }
            return try await tab.web.evaluateJavaScript("(() => { try { return \(playing) } catch { return false } })()") as? Bool == true
        }
        return tab
    }
    @MainActor private func value(_ script: String, in tab: BrowserTab) async throws -> Any? { try await tab.web.evaluateJavaScript(script) }

    @MainActor private func picture(in tab: BrowserTab, panel: FloatingVideoWindow) async throws -> Data {
        let image = try await tab.web.takeSnapshot(rect: panel.videoHost.bounds)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var bytes = [UInt8](repeating: 0, count: 32*18*4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 32, height: 18, bitsPerComponent: 8,
                bytesPerRow: 32*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        return Data(bytes)
    }
    /// The window shows the moving video, not the page around it.
    @MainActor private func assertShowsVideo(_ tab: BrowserTab, _ panel: FloatingVideoWindow, file: StaticString = #filePath, line: UInt = #line) async throws {
        let first = try await picture(in: tab, panel: panel)
        func near(_ index: Int, _ value: Int) -> Bool { abs(Int(first[index])-value) < 6 }
        let pageColor = stride(from: 0, to: first.count, by: 4).filter { (i: Int) -> Bool in near(i, 144) && near(i+1, 80) && near(i+2, 64) }
        XCTAssertLessThan(pageColor.count, 8, "The page's own background shows in the picture", file: file, line: line)
        let frames = panel.renderedFrameCount
        // Long enough for the clip's clock to move, which is most of what changes between frames.
        try await wait("the picture advances") { panel.renderedFrameCount > frames+30 }
        let later = try await picture(in: tab, panel: panel)
        XCTAssertNotEqual(first, later, "The picture moves with the video", file: file, line: line)
    }
    @MainActor private func floatAway(_ tab: BrowserTab, in browser: BrowserController) async throws -> FloatingVideoWindow {
        _ = browser.addTab()
        try await wait("the video floats") { browser.pictureInPicture.panel?.alphaValue == 1 && browser.pictureInPicture.panel?.hasVideoFrame == true }
        XCTAssertEqual(browser.pictureInPicture.sourceTabID, tab.id)
        XCTAssertTrue(tab.web.window === browser.pictureInPicture.panel)
        return try XCTUnwrap(browser.pictureInPicture.panel)
    }
    @MainActor private func returnHome(_ tab: BrowserTab, in browser: BrowserController) async throws {
        browser.pictureInPicture.returnToTab()
        try await wait("the page is back in its tab") { browser.pictureInPicture.panel == nil && tab.web.superview === browser.pageClip }
    }

    @MainActor func testAnySitesVideoWithSoundFloatsAndReturnsUntouched() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("<p id=original>Article</p><video id=v loop autoplay playsinline style='width:320px;height:180px' src='\(try videoSource())'></video>",
                                 in: browser, playing: "v.currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let playing = try await value("!v.paused", in: tab) as? Bool
        XCTAssertEqual(playing, true, "It keeps playing through the return")
        let canvases = try await value("document.querySelectorAll('canvas').length", in: tab) as? Int
        XCTAssertEqual(canvases, 0)
        let style = try await value("v.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(style, "width:320px;height:180px")
    }

    @MainActor func testMutedPausedAndBlockedVideosStayInline() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let muted = try await page("<video id=v muted loop autoplay playsinline src='\(source)'></video>", in: browser, playing: "v.currentTime > 0.1")
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.pictureInPicture.panel, "A muted video stays a background loop")

        // Unmuting it while it plays counts as sound.
        browser.select(muted.id)
        _ = try await value("v.muted = false; 0", in: muted)
        try await Task.sleep(for: .milliseconds(150))
        _ = browser.addTab()
        try await wait("the unmuted video floats") { browser.pictureInPicture.panel?.alphaValue == 1 }
        browser.pictureInPicture.returnToTab()
        try await wait("back") { browser.pictureInPicture.panel == nil }

        _ = try await value("v.pause(); 0", in: muted)
        try await Task.sleep(for: .milliseconds(150))
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.pictureInPicture.panel, "A paused video stays")

        browser.select(muted.id)
        _ = try await value("v.play(); 0", in: muted)
        try await Task.sleep(for: .milliseconds(150))
        browser.sitePermissions.setAutomaticPictureInPicture(false, origin: try XCTUnwrap(SitePermissions.origin(muted.url)))
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(browser.pictureInPicture.panel, "The site's Automatic Picture-In-Picture setting is respected")
    }

    @MainActor func testVideoInAFrameFloatsWithItsFrameLiftedAndPutBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let frameStyle = "width:320px;height:180px;border:3px solid red;transform:scale(0.7);margin:200px 0 0 300px"
        let tab = try await page("""
          <div style="overflow:hidden;width:200px;height:100px;position:relative;z-index:1">
          <iframe id=frame style="\(frameStyle)" srcdoc='<body style="margin:0;background:rgb(144,80,64)"><video loop autoplay playsinline style="width:100%" src="\(try videoSource())"></video>'></iframe>
          </div><div style="position:fixed;inset:0;z-index:999;background:rgba(144,80,64,1);pointer-events:none"></div>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        let lifted = try await value("frame.matches(':popover-open')", in: tab) as? Bool
        XCTAssertEqual(lifted, true, "The frame is lifted over its clipped, covered page")
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let style = try await value("frame.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(style, frameStyle, "The frame's own style is back exactly")
        let popover = try await value("frame.hasAttribute('popover')", in: tab) as? Bool
        XCTAssertEqual(popover, false)
        let playing = try await value("!frame.contentDocument.querySelector('video').paused", in: tab) as? Bool
        XCTAssertEqual(playing, true)
        let canvases = try await value("frame.contentDocument.querySelectorAll('canvas').length", in: tab) as? Int
        XCTAssertEqual(canvases, 0)

        // Again, so a second float finds the frame as it was.
        let again = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, again)
        try await returnHome(tab, in: browser)
        let styleAgain = try await value("frame.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(styleAgain, frameStyle)
    }

    @MainActor func testVideoTwoFramesDownFloats() async throws {
        let browser = browser(); defer { clean(browser) }
        let inner = "<body style=&quot;margin:0&quot;><video loop autoplay playsinline src=&quot;\(try videoSource())&quot;></video>"
        let tab = try await page("""
          <iframe id=outer style="width:400px;height:300px" srcdoc="<body style='margin:0'><iframe id=inner style='width:320px;height:180px' srcdoc='\(inner)'></iframe>"></iframe>
          """, in: browser, playing: "outer.contentDocument.querySelector('#inner').contentDocument.querySelector('video').currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        let lifted = try await value("[outer.matches(':popover-open'), outer.contentDocument.querySelector('#inner').matches(':popover-open')].join()", in: tab) as? String
        XCTAssertEqual(lifted, "true,true", "Each frame on the way down is lifted")
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let after = try await value("[outer.hasAttribute('popover'), outer.contentDocument.querySelector('#inner').hasAttribute('popover'), outer.getAttribute('style')].join()", in: tab) as? String
        XCTAssertEqual(after, "false,false,width:400px;height:300px")
    }

    @MainActor func testVideoInAShadowRootFloats() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <rise-player id=host></rise-player>
          <script>
          host.attachShadow({mode:'open'}).innerHTML = '<video loop autoplay playsinline src="\(try videoSource())"></video>';
          </script>
          """, in: browser, playing: "host.shadowRoot.querySelector('video').currentTime > 0.1")
        let panel = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
    }

    @MainActor func testRemovingTheFloatingFramePutsThePageBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <iframe id=frame style="width:320px;height:180px" srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        _ = try await floatAway(tab, in: browser)
        _ = try await value("frame.remove(); 0", in: tab)
        try await wait("the picture closes with its frame") { browser.pictureInPicture.panel == nil }
        XCTAssertNil(tab.web.window, "The page goes back to its hidden tab")
    }

    @MainActor func testTheFrameHeardLastFloatsAndPausingInThePictureReachesIt() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let tab = try await page("""
          <video id=page loop autoplay playsinline style="width:160px" src="\(source)"></video>
          <iframe id=frame style="width:320px;height:180px" srcdoc='<video loop playsinline src="\(source)"></video>'></iframe>
          """, in: browser, playing: "page.currentTime > 0.1")
        _ = try await value("page.pause(); frame.contentDocument.querySelector('video').play(); 0", in: tab)
        try await wait("frame plays") { try await self.value("frame.contentDocument.querySelector('video').currentTime > 0.2", in: tab) as? Bool == true }
        let panel = try await floatAway(tab, in: browser)
        let lifted = try await value("frame.matches(':popover-open')", in: tab) as? Bool
        XCTAssertEqual(lifted, true, "The playing frame floats, not the page's paused video")
        panel.onTogglePlayback?()
        try await wait("the frame's video pauses") { try await self.value("frame.contentDocument.querySelector('video').paused", in: tab) as? Bool == true }
        let pagePaused = try await value("page.paused", in: tab) as? Bool
        XCTAssertEqual(pagePaused, true)
        panel.onTogglePlayback?()
        try await wait("and plays") { try await self.value("frame.contentDocument.querySelector('video').paused", in: tab) as? Bool == false }
    }

    @MainActor func testMinimizingLeavesNoOtherPictureBehind() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("<video id=v loop autoplay playsinline src='\(try videoSource())'></video>", in: browser, playing: "v.currentTime > 0.1")
        _ = try await floatAway(tab, in: browser)
        browser.pictureInPicture.minimizeVideo()
        try await wait("hidden") { browser.pictureInPicture.panel == nil }
        try await Task.sleep(for: .milliseconds(400))
        let mode = try await value("[document.pictureInPictureElement ? 'picture-in-picture' : 'inline', !v.paused].join()", in: tab) as? String
        XCTAssertEqual(mode, "inline,true", "It keeps playing in its tab without Chromium's own picture in picture")
    }

    @MainActor func testAFrameNavigatingAwayWhileFloatingPutsThePageBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let frameStyle = "width:320px;height:180px"
        let tab = try await page("""
          <iframe id=frame style="\(frameStyle)" srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        _ = try await floatAway(tab, in: browser)
        _ = try await value("frame.srcdoc = '<p>Next</p>'; 0", in: tab)
        try await wait("the picture closes as its frame moves on") { browser.pictureInPicture.panel == nil }
        try await wait("the frame is put back") { try await self.value("frame.hasAttribute('popover')", in: tab) as? Bool == false }
        let style = try await value("frame.getAttribute('style')", in: tab) as? String
        XCTAssertEqual(style, frameStyle)
    }

    @MainActor func testSandboxedFrameFloats() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <iframe id=frame sandbox="allow-scripts" style="width:320px;height:180px" srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe>
          """, in: browser, playing: "true")
        // Its opaque origin hides its document from the page, so wait on the frame's own report.
        try await wait("the frame's video plays") { browser.pictureInPicture.isPlaying(tab) }
        let panel = try await floatAway(tab, in: browser)
        try await assertShowsVideo(tab, panel)
        try await returnHome(tab, in: browser)
        let popover = try await value("frame.hasAttribute('popover')", in: tab) as? Bool
        XCTAssertEqual(popover, false)
    }

    @MainActor func testAFrameInAHiddenContainerStaysInline() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("""
          <div style="display:none"><iframe id=frame srcdoc='<video loop autoplay playsinline src="\(try videoSource())"></video>'></iframe></div>
          """, in: browser, playing: "frame.contentDocument.querySelector('video').currentTime > 0.1")
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertNil(browser.pictureInPicture.panel, "Its picture can't be shown, so nothing floats")
        let popover = try await value("frame.hasAttribute('popover')", in: tab) as? Bool
        XCTAssertEqual(popover, false, "The frame is put back")
    }
}
@MainActor final class TabMediaCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("TabPlayButtonPausesAndResumesAnySitesMedia") ?? true { await liveCase("TabPlayButtonPausesAndResumesAnySitesMedia") { try await self.testTabPlayButtonPausesAndResumesAnySitesMedia(); self.tearDown() } }
        if only?.contains("PlayButtonReachesMediaInFramesAndOutsideTheDocument") ?? true { await liveCase("PlayButtonReachesMediaInFramesAndOutsideTheDocument") { try await self.testPlayButtonReachesMediaInFramesAndOutsideTheDocument(); self.tearDown() } }
    }
    private var preferenceSuites: [String] = []
    func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        preferenceSuites = []
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.TabMediaTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.center()
        browser.showWindow(nil); browser.pictureInPicture.reduceMotion = { true }
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.pictureInPicture.tearDown(); browser.saveWork?.cancel()
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "TabMediaTests", code: 1)
    }
    private func videoSource() throws -> String {
        let file = LiveFixtures.repository("Tests/RiseTests/Resources/PiPTestVideo.mp4")
        return "data:video/mp4;base64," + (try Data(contentsOf: file).base64EncodedString())
    }
    @MainActor private func page(_ html: String, in browser: BrowserController) async throws -> BrowserTab {
        let tab = browser.addTab()
        tab.web.loadHTMLString(html, baseURL: URL(string: "https://media.example/"))
        try await wait("page loads") {
            guard !tab.web.isLoading else { return false }
            return try await tab.web.evaluateJavaScript("document.readyState") as? String == "complete"
        }
        return tab
    }
    @MainActor private func paused(_ script: String, in tab: BrowserTab) async throws -> Bool? {
        try await tab.web.evaluateJavaScript(script) as? Bool
    }

    @MainActor func testTabPlayButtonPausesAndResumesAnySitesMedia() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let tab = try await page("""
          <video id=loop muted loop autoplay playsinline src="\(source)"></video>
          <video id=main loop playsinline src="\(source)"></video>
          """, in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        try await wait("silent loop plays") { try await self.paused("loop.paused", in: tab) == false }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(row.playbackPaused, "Silent background video doesn't give the tab a play button")

        _ = try await tab.web.evaluateJavaScript("main.play(); 0")
        try await wait("row knows the media plays") { row.playbackPaused == false }
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        row.mouseEntered(with: hover); row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.playback.isHidden, "Shows beside the close button on hover")

        _ = row.playback.accessibilityPerformPress()
        XCTAssertTrue(row.playback.paused, "The button swaps at once")
        try await wait("media pauses") { try await self.paused("main.paused", in: tab) == true }
        let loopPaused = try await paused("loop.paused", in: tab)
        XCTAssertEqual(loopPaused, false, "Only media with sound is paused")
        XCTAssertEqual(row.playbackPaused, true, "Paused media keeps its button")

        _ = row.playback.accessibilityPerformPress()
        try await wait("media resumes") { try await self.paused("main.paused", in: tab) == false }
        try await wait("row follows") { row.playbackPaused == false && !row.playback.paused }

        _ = try await tab.web.evaluateJavaScript("main.pause(); 0")
        try await wait("row follows the page's own pause") { row.playbackPaused == true && row.playback.paused }

        _ = try await tab.web.evaluateJavaScript("main.remove(); 0")
        try await wait("removed media takes its button with it", timeout: 5) { row.playbackPaused == nil }

        tab.web.loadHTMLString("<p>Next page</p>", baseURL: URL(string: "https://other.example/"))
        try await wait("next page") { tab.web.url?.host == "other.example" && !tab.web.isLoading }
        XCTAssertNil(row.playbackPaused)
    }

    @MainActor func testPlayButtonReachesMediaInFramesAndOutsideTheDocument() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try videoSource()
        let tab = try await page("""
          <iframe id=frame srcdoc='<video loop playsinline src="\(source)"></video>'></iframe>
          """, in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        let framed = "frame.contentDocument.querySelector('video').paused"
        try await wait("frame ready") { try await self.paused(framed, in: tab) == true }
        _ = try await tab.web.evaluateJavaScript("frame.contentDocument.querySelector('video').play(); 0")
        try await wait("row knows the frame plays") { row.playbackPaused == false }
        _ = row.playback.accessibilityPerformPress()
        try await wait("frame's media pauses") { try await self.paused(framed, in: tab) == true }
        _ = row.playback.accessibilityPerformPress()
        try await wait("frame's media resumes") { try await self.paused(framed, in: tab) == false }
        _ = try await tab.web.evaluateJavaScript("frame.contentDocument.querySelector('video').pause(); 0")
        try await wait("row follows") { row.playbackPaused == true }

        // Media the page plays without adding it to the document.
        _ = try await tab.web.evaluateJavaScript("window.loose = document.createElement('video'); loose.loop = true; loose.src = '\(source)'; loose.play(); 0")
        try await wait("row knows the loose media plays") { row.playbackPaused == false }
        _ = row.playback.accessibilityPerformPress()
        try await wait("loose media pauses") { try await self.paused("loose.paused", in: tab) == true }
        let framePaused = try await paused(framed, in: tab)
        XCTAssertEqual(framePaused, true)
        _ = row.playback.accessibilityPerformPress()
        try await wait("loose media resumes, as it played last") { try await self.paused("loose.paused", in: tab) == false }
        let frameStill = try await paused(framed, in: tab)
        XCTAssertEqual(frameStill, true, "Play resumes only what played last")

        browser.closeTab(tab.id)
        XCTAssertNil(browser.tabMedia.paused(tab.id))
    }
}
@MainActor final class TabAudioCases {
    func runAll() async {
        let only = ProcessInfo.processInfo.environment["RISE_CASES"]?.split(separator: ",").map(String.init)
        if only?.contains("TheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing") ?? true { await liveCase("TheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing") { try await self.testTheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing(); self.tearDown() } }
    }
    private var preferenceSuites: [String] = []
    func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        preferenceSuites = []
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.TabAudioTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.center()
        browser.showWindow(nil)
        return browser
    }
    @MainActor private func clean(_ browser: BrowserController) {
        browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil)
        try? FileManager.default.removeItem(at: browser.sessionURL.deletingLastPathComponent())
    }
    @MainActor private func wait(_ description: String, timeout: TimeInterval = 10, until predicate: @escaping () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
        throw NSError(domain: "TabAudioTests", code: 1)
    }
    /// A page looping a silent clip: WebKit counts any audible track as sound,
    /// whatever its samples, so the test makes no noise.
    @MainActor private func soundTab(in browser: BrowserController) async throws -> BrowserTab {
        let tab = browser.addTab()
        tab.web.loadHTMLString("""
          <!doctype html><title>Sound fixture</title><script>
          const rate = 8000, samples = rate, buffer = new ArrayBuffer(44 + samples*2), view = new DataView(buffer);
          const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset+i, c.charCodeAt(0)));
          text(0, 'RIFF'); view.setUint32(4, 36 + samples*2, true); text(8, 'WAVEfmt ');
          view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
          view.setUint32(24, rate, true); view.setUint32(28, rate*2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
          text(36, 'data'); view.setUint32(40, samples*2, true);
          // A quiet tone: Chromium only counts a tab as making sound when it isn't silent.
          for (let i = 0; i < samples; i++) view.setInt16(44 + i*2, Math.round(Math.sin(i*2*Math.PI*440/rate)*3000), true);
          const audio = new Audio(URL.createObjectURL(new Blob([buffer], {type: 'audio/wav'})));
          audio.loop = true; audio.play(); window.sound = audio;
          </script>
          """, baseURL: URL(string: "https://example.com/sound"))
        try await wait("page plays sound") { tab.isPlayingAudio }
        return tab
    }

    @MainActor func testTheAudioButtonAppearsBeforeTheTitleAndMutesWithoutPausing() async throws {
        let browser = browser(); defer { clean(browser) }
        let quiet = browser.addTab()
        let tab = try await soundTab(in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[tab.id])
        try await wait("row shows the audio button") { row.showsAudio }
        row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.audio.isHidden)
        XCTAssertGreaterThan(row.audio.frame.minX, row.icon.frame.maxX, "After the favicon")
        XCTAssertLessThan(row.audio.frame.maxX, row.titleField.frame.minX, "Before the title")
        XCTAssertEqual(row.audio.frame.size, row.close.frame.size, "The same square as the close button")
        XCTAssertEqual(row.audio.frame.midY, row.icon.frame.midY, accuracy: 0.5)
        let quietRow = try XCTUnwrap(browser.sidebar.rows[quiet.id]); quietRow.layoutSubtreeIfNeeded()
        XCTAssertFalse(quietRow.showsAudio); XCTAssertTrue(quietRow.audio.isHidden)
        XCTAssertEqual(row.titleField.frame.minX, quietRow.titleField.frame.minX+24, "The title moves over to make room")
        XCTAssertTrue(row.hitTest(row.convert(NSPoint(x: row.audio.frame.midX, y: row.audio.frame.midY), to: row.superview)) === row.audio)

        _ = row.audio.accessibilityPerformPress()
        XCTAssertTrue(row.audio.muted, "The slash appears at once")
        XCTAssertTrue(tab.isAudioMuted)
        XCTAssertTrue((tab.page as? ChromiumPage)?.browserView.isAudioMuted == true, "Chromium mutes the page")
        try await Task.sleep(for: .milliseconds(300))
        let paused = try await tab.web.evaluateJavaScript("window.sound.paused") as? Bool
        XCTAssertEqual(paused, false, "Muting keeps it playing")
        XCTAssertTrue(row.showsAudio, "A muted tab keeps its button")

        _ = row.audio.accessibilityPerformPress()
        XCTAssertFalse(row.audio.muted); XCTAssertFalse(tab.isAudioMuted)
        XCTAssertTrue((tab.page as? ChromiumPage)?.browserView.isAudioMuted == false)

        _ = try await tab.web.evaluateJavaScript("window.sound.pause()")
        try await wait("tab stops playing") { !tab.isPlayingAudio }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(row.showsAudio, "A short pause keeps the title where it is")
        try await wait("button leaves after the sound stops", timeout: 4) { !row.showsAudio }
        row.layoutSubtreeIfNeeded()
        XCTAssertEqual(row.titleField.frame.minX, quietRow.titleField.frame.minX)
    }
}
