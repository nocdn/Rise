import XCTest
import AppKit
import WebKit
@testable import Rise

/// Picture in Picture on sites other than YouTube: any video that has played with
/// sound, in the page, a shadow root, or a frame at any depth.
final class VideoPictureInPictureTests: XCTestCase {
    private var preferenceSuites: [String] = []
    override func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.VideoPiPTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"),
                                        restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setFrameAutosaveName("")
        browser.window?.setFrameOrigin(NSPoint(x: -10000, y: -10000))
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
        let file = try XCTUnwrap(Bundle.module.url(forResource: "PiPTestVideo", withExtension: "mp4", subdirectory: "Resources"))
        return "data:video/mp4;base64," + (try Data(contentsOf: file).base64EncodedString())
    }
    /// A page whose `playing` expression turns true once its video plays.
    @MainActor private func page(_ html: String, in browser: BrowserController, playing: String) async throws -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let tab = browser.addTab(configuration: configuration)
        tab.webView.loadHTMLString("<!doctype html><title>Video</title><body style='margin:0;background:rgb(144,80,64)'>\(html)",
                                   baseURL: URL(string: "https://videos.example/"))
        try await wait("video plays") {
            guard !tab.webView.isLoading else { return false }
            return try await tab.webView.evaluateJavaScript("(() => { try { return \(playing) } catch { return false } })()") as? Bool == true
        }
        return tab
    }
    @MainActor private func value(_ script: String, in tab: BrowserTab) async throws -> Any? { try await tab.webView.evaluateJavaScript(script) }

    @MainActor private func picture(in tab: BrowserTab, panel: FloatingVideoWindow) async throws -> Data {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = panel.videoHost.bounds
        let image = try await tab.webView.takeSnapshot(configuration: configuration)
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
        let pageColor = stride(from: 0, to: first.count, by: 4).filter { abs(Int(first[$0])-144) < 6 && abs(Int(first[$0+1])-80) < 6 && abs(Int(first[$0+2])-64) < 6 }
        XCTAssertLessThan(pageColor.count, 8, "The page's own background shows in the picture", file: file, line: line)
        let frames = panel.renderedFrameCount
        try await wait("the picture advances") { panel.renderedFrameCount > frames+2 }
        let later = try await picture(in: tab, panel: panel)
        XCTAssertNotEqual(first, later, "The picture moves with the video", file: file, line: line)
    }
    @MainActor private func floatAway(_ tab: BrowserTab, in browser: BrowserController) async throws -> FloatingVideoWindow {
        _ = browser.addTab()
        try await wait("the video floats") { browser.pictureInPicture.panel?.alphaValue == 1 && browser.pictureInPicture.panel?.hasVideoFrame == true }
        XCTAssertEqual(browser.pictureInPicture.sourceTabID, tab.id)
        XCTAssertTrue(tab.webView.window === browser.pictureInPicture.panel)
        return try XCTUnwrap(browser.pictureInPicture.panel)
    }
    @MainActor private func returnHome(_ tab: BrowserTab, in browser: BrowserController) async throws {
        browser.pictureInPicture.returnToTab()
        try await wait("the page is back in its tab") { browser.pictureInPicture.panel == nil && tab.webView.superview === browser.pageClip }
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
        XCTAssertNil(tab.webView.window, "The page goes back to its hidden tab")
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
        let mode = try await value("[v.webkitPresentationMode, !v.paused].join()", in: tab) as? String
        XCTAssertEqual(mode, "inline,true", "It keeps playing in its tab without WebKit's own picture in picture")
    }

    @MainActor func testEncryptedVideoFloatsInWebKitsOwnPictureInPictureAndComesBack() async throws {
        let browser = browser(); defer { clean(browser) }
        let tab = try await page("<video id=v loop autoplay playsinline style='width:320px' src='\(try videoSource())'></video>", in: browser, playing: "v.currentTime > 0.1")
        // As a protected stream announces itself; Rise's window would draw it black.
        _ = try await value("v.dispatchEvent(new Event('encrypted')); 0", in: tab)
        try await Task.sleep(for: .milliseconds(150))
        let other = browser.addTab()
        try await wait("WebKit's own picture in picture") { try await self.value("v.webkitPresentationMode", in: tab) as? String == "picture-in-picture" }
        XCTAssertNil(browser.pictureInPicture.panel, "Rise's window stays closed")
        browser.select(tab.id)
        try await wait("back inline with its tab") { try await self.value("v.webkitPresentationMode", in: tab) as? String == "inline" }
        let playing = try await value("!v.paused", in: tab) as? Bool
        XCTAssertEqual(playing, true)
        browser.closeTab(other.id)
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
