import XCTest
import AppKit
import WebKit
import RiseCore
@testable import Rise

final class YouTubePictureInPictureTests: XCTestCase {
    private var preferenceSuites: [String] = []
    override func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.PiPTests.\(UUID().uuidString)"
        preferenceSuites.append(suite)
        let preferences = UserDefaults(suiteName: suite)!
        let browser = BrowserController(sessionURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("session.json"), restore: false, preferences: preferences)
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
        throw NSError(domain: "PiPTests", code: 1)
    }
    @MainActor private func fixture(in browser: BrowserController, url: String = "https://www.youtube.com/watch?v=rise-fixture") async throws -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let tab = browser.addTab(configuration: configuration)
        let file = try XCTUnwrap(Bundle.module.url(forResource: "PiPTestVideo", withExtension: "mp4", subdirectory: "Resources"))
        let video = try Data(contentsOf: file).base64EncodedString()
        tab.iconOrigin = SitePermissions.origin(URL(string: url))
        tab.webView.loadHTMLString("""
          <!doctype html><title>PiP fixture</title><style>body{background:#905040}#container{transform:translate(0,0);overflow:hidden;width:600px;height:300px}video{width:600px;height:300px}</style>
          <p id="original">Original page</p><div id="container"><video style="width:600px;height:300px" loop muted autoplay playsinline src="data:video/mp4;base64,\(video)"></video></div>
          """, baseURL: URL(string: url))
        try await wait("fixture playing at its YouTube URL") {
            guard !tab.webView.isLoading, tab.webView.url?.host == URL(string: url)?.host else { return false }
            return try await tab.webView.evaluateJavaScript("document.querySelector('video')?.currentTime > 0.1") as? Bool == true
        }
        if YouTubeVideoPage.containsVideo(tab.url) {
            try await wait("media state bridge") { browser.pictureInPicture.isPlaying(tab) }
        }
        return tab
    }
    @MainActor private func value(_ script: String, in tab: BrowserTab) async throws -> Any? { try await tab.webView.evaluateJavaScript(script) }
    @MainActor private func assertValue<T: Equatable>(_ script: String, in tab: BrowserTab, equals expected: T, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = try await value(script, in: tab) as? T
        XCTAssertEqual(result, expected, file: file, line: line)
    }

    @MainActor private func picture(in tab: BrowserTab, panel: FloatingVideoWindow) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: panel.videoFrame.size)
        let image = try await tab.webView.takeSnapshot(configuration: configuration)
        return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    }

    private func pixels(_ image: CGImage) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32*18*4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 32, height: 18, bitsPerComponent: 8,
                bytesPerRow: 32*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 18))
        }
        return Data(bytes)
    }
    private func hasVisibleColor(_ pixels: Data) -> Bool {
        // Ignore alpha: opaque black contains 255-valued alpha bytes too.
        pixels.enumerated().contains { $0.offset % 4 != 3 && $0.element > 40 }
    }

    @MainActor func testOriginalVideoKeepsPlayingThroughPiPAndReturnWithoutReload() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        let originalViewport = source.webView.frame.size
        let originalInlineStyle = try await value("document.querySelector('video').getAttribute('style') || ''", in: source) as? String
        _ = try await value("window.originalVideo = document.querySelector('video'); originalVideo.playbackRate = 1.25; originalVideo.volume = 0.4; originalVideo.currentTime = 1", in: source)
        let other = browser.addTab()
        try await wait("floating player appears") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        XCTAssertEqual(browser.selectedID, other.id)
        let visible = try XCTUnwrap(panel.screen).visibleFrame
        XCTAssertEqual(panel.videoFrame.minX-visible.minX, panel.videoFrame.minY-visible.minY, accuracy: 0.5, "Left and bottom gaps must match")
        XCTAssertTrue(source.webView.window === panel)
        XCTAssertTrue(source.webView.superview === panel.videoHost)
        XCTAssertEqual(source.webView.frame.size, originalViewport, "The page viewport must stay stable throughout PiP")
        let beforeValue = try await value("originalVideo.currentTime", in: source) as? Double
        let before = try XCTUnwrap(beforeValue)
        try await Task.sleep(for: .milliseconds(200))
        let afterValue = try await value("originalVideo.currentTime", in: source) as? Double
        let after = try XCTUnwrap(afterValue)
        XCTAssertGreaterThan(after, before)
        try await assertValue("originalVideo === document.querySelector('video')", in: source, equals: true)
        try await assertValue("originalVideo.playbackRate", in: source, equals: 1.25)
        try await assertValue("originalVideo.volume", in: source, equals: 0.4)
        // Assert the picture itself, not just the HTML video clock: a remote
        // video layer can be black while audio/currentTime keep advancing.
        let firstFrame = try await picture(in: source, panel: panel)
        let firstPixels = try pixels(firstFrame)
        XCTAssertTrue(hasVisibleColor(firstPixels), "The synthetic color chart must not render black")
        let frameCount = panel.renderedFrameCount
        try await wait("new video frames reach the native picture") { panel.renderedFrameCount > frameCount+2 }
        let laterPixels = try pixels(await picture(in: source, panel: panel))
        XCTAssertNotEqual(firstPixels, laterPixels, "The PiP image must advance with the moving chart")
        try await assertValue("originalVideo.getAttribute('style') || ''", in: source, equals: originalInlineStyle ?? "")
        let dimensions = try await value("[innerWidth, innerHeight]", in: source) as? [Double]
        XCTAssertEqual(dimensions?[0], Double(originalViewport.width)); XCTAssertEqual(dimensions?[1], Double(originalViewport.height))
        browser.update(); browser.attachVisiblePages()
        XCTAssertTrue(source.webView.window === panel, "Background updates must not detach PiP")

        browser.pictureInPicture.returnToTab()
        try await wait("original tab restored") { browser.pictureInPicture.panel == nil && source.webView.superview === browser.pageClip }
        XCTAssertEqual(browser.selectedID, source.id)
        XCTAssertTrue(browser.window?.firstResponder === source.webView, "The returned page takes keyboard focus")
        try await assertValue("originalVideo.paused", in: source, equals: false)
        try await assertValue("document.documentElement.hasAttribute('data-rise-video-pip')", in: source, equals: false)
        try await assertValue("document.querySelector('#original').textContent", in: source, equals: "Original page")
        try await assertValue("originalVideo === document.querySelector('video')", in: source, equals: true)
        try await assertValue("originalVideo.getAttribute('style') || ''", in: source, equals: originalInlineStyle ?? "")
    }

    @MainActor func testSixtyFPSVideoPaintsWithoutTheJPEGFrameCapAndKeepsScreenGapsEqual() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("60fps PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        try await Task.sleep(for: .seconds(1)) // Allow the offscreen test player to warm up.
        let count = panel.renderedFrameCount
        let before = try await value("document.querySelector('video').getVideoPlaybackQuality().totalVideoFrames", in: source) as? Int ?? 0
        try await Task.sleep(for: .seconds(2))
        let after = try await value("document.querySelector('video').getVideoPlaybackQuality().totalVideoFrames", in: source) as? Int ?? 0
        let intervals = panel.videoFrameIntervals.sorted()
        let percentile95 = try XCTUnwrap(intervals.isEmpty ? nil : intervals[min(intervals.count-1, Int(Double(intervals.count)*0.95))])
        print("PiP cadence over 2s: \(panel.renderedFrameCount-count) paints; \(after-before) source frames; 95th-percentile interval \(percentile95)")
        XCTAssertGreaterThan(panel.renderedFrameCount-count, 90)
        XCTAssertGreaterThan(after-before, 0, "The original video decoder must keep advancing")
        XCTAssertLessThan(percentile95, 1.0/30, "Frame pacing must remain smooth rather than periodically halving the cadence")
        let screen = try XCTUnwrap(panel.screen)
        XCTAssertEqual(panel.videoFrame.minX-screen.visibleFrame.minX, panel.videoFrame.minY-screen.visibleFrame.minY, accuracy: 0.5)
        let beforeImage = try pixels(await picture(in: source, panel: panel))
        try await Task.sleep(for: .milliseconds(100))
        let afterImage = try pixels(await picture(in: source, panel: panel))
        XCTAssertNotEqual(beforeImage, afterImage)
    }

    @MainActor func testLiveYouTubeFramesWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["RISE_TEST_LIVE_YOUTUBE"] == "1" else {
            throw XCTSkip("Set RISE_TEST_LIVE_YOUTUBE=1 for the opt-in network playback check")
        }
        let browser = browser(); defer { clean(browser) }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let source = browser.addTab(configuration: configuration)
        source.load(URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!)
        try await wait("real YouTube movie after preroll ads", timeout: 30) {
            try await self.value("""
              (() => {
                const video = document.querySelector('video');
                const movie = !!video && video.readyState >= 2 && Number.isFinite(video.duration) && video.duration > 600;
                if (!movie) [...document.querySelectorAll('button')].find(button => /^Skip(\\s+Ads?)?$/i.test(button.textContent.trim()))?.click();
                return movie;
              })()
              """, in: source) as? Bool == true
        }
        _ = try await value("document.querySelector('video').muted = true; document.querySelector('video').play(); true", in: source)
        try await wait("real YouTube playback") { browser.pictureInPicture.isPlaying(source) }
        _ = browser.addTab()
        try await wait("real YouTube frame in PiP") { browser.pictureInPicture.panel?.hasVideoFrame == true }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        try await Task.sleep(for: .milliseconds(500))
        let before = try pixels(await picture(in: source, panel: panel))
        let count = panel.renderedFrameCount
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(panel.renderedFrameCount-count, 80, "PiP must paint at display cadence, without the former 30fps cap")
        let after = try pixels(await picture(in: source, panel: panel))
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(hasVisibleColor(after))
        browser.pictureInPicture.returnToTab()
        try await wait("real YouTube restored") { browser.pictureInPicture.panel == nil && source.webView.superview === browser.pageClip }
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
    }

    @MainActor func testClosePausesAndClosingSourceTabRemovesFloatingPlayer() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        let other = browser.addTab()
        try await wait("first PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        browser.pictureInPicture.closeVideo()
        try await wait("PiP closes") { browser.pictureInPicture.panel == nil }
        XCTAssertEqual(browser.selectedID, other.id)
        try await assertValue("document.querySelector('video').paused", in: source, equals: true)
        XCTAssertNil(source.webView.superview)
        browser.select(source.id)
        _ = try await value("document.querySelector('video').play(); true", in: source)
        try await Task.sleep(for: .milliseconds(100))
        browser.select(other.id)
        try await wait("second PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        browser.closeTab(source.id)
        XCTAssertNil(browser.pictureInPicture.panel)
        XCTAssertNil(browser.pictureInPicture.sourceTabID)
    }

    @MainActor func testPausedAndBlockedVideosDoNotFloatAndSplitVisibilityIsRespected() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = try await value("document.querySelector('video').pause()", in: source)
        try await Task.sleep(for: .milliseconds(100))
        let other = browser.addTab()
        XCTAssertNil(browser.pictureInPicture.panel)
        browser.select(source.id)
        _ = try await value("document.querySelector('video').play(); true", in: source)
        try await Task.sleep(for: .milliseconds(100))
        browser.sitePermissions.setAutomaticPictureInPicture(false, origin: SitePermissions.origin(source.url)!)
        browser.select(other.id)
        XCTAssertNil(browser.pictureInPicture.panel)
        browser.sitePermissions.setAutomaticPictureInPicture(true, origin: SitePermissions.origin(source.url)!)
        browser.select(source.id); browser.showSplit(other)
        browser.select(other.id)
        XCTAssertNil(browser.pictureInPicture.panel, "A visible split video remains inline")
        let third = browser.addTab()
        try await wait("leaving split starts PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        XCTAssertEqual(browser.selectedID, third.id)
        browser.select(other.id)
        try await wait("returning to visible split restores video") { browser.pictureInPicture.panel == nil }
        XCTAssertTrue(source.webView.superview === browser.pageClip)
    }

    @MainActor func testRapidSwitchDuringPresentationAndReturnKeepsOnePlayerAndCorrectOwner() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        let other = browser.addTab()
        browser.select(source.id); browser.select(other.id)
        try await wait("PiP survives an interrupted entry") { browser.pictureInPicture.panel?.alphaValue == 1 && browser.pictureInPicture.panel?.isDismissing == false }
        XCTAssertEqual(browser.pictureInPicture.sourceTabID, source.id)
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        browser.pictureInPicture.returnToTab()
        XCTAssertTrue(source.webView.window === panel, "The returning player stays live until its picture is frozen")
        browser.select(other.id)
        try await wait("PiP reopens after an interrupted return") { browser.pictureInPicture.panel?.alphaValue == 1 && browser.pictureInPicture.panel?.isDismissing == false }
        XCTAssertTrue(source.webView.window === browser.pictureInPicture.panel)
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
        browser.select(source.id)
        try await wait("final return") { browser.pictureInPicture.panel == nil }
        XCTAssertTrue(source.webView.superview === browser.pageClip)
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
    }

    @MainActor func testNavigationAndVideoEndCleanUpPiPAndOtherSitesStayInline() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("navigation PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        source.webView.loadHTMLString("<title>Navigated</title><p>No video</p>", baseURL: URL(string: "https://www.youtube.com/"))
        try await wait("navigation cleans up PiP") { browser.pictureInPicture.panel == nil && !source.webView.isLoading }
        XCTAssertNil(browser.pictureInPicture.sourceTabID)

        let ended = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("ending PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        _ = try await value("const v = document.querySelector('video'); v.loop = false; v.currentTime = v.duration-0.1; true", in: ended)
        try await wait("ended video closes PiP") { browser.pictureInPicture.panel == nil }
        _ = try await fixture(in: browser, url: "https://vimeo.com/123")
        _ = browser.addTab()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(browser.pictureInPicture.panel)
    }

    @MainActor func testAutoplayAfterTheVideoEndsFloatsAgain() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("PiP before end") { browser.pictureInPicture.panel?.alphaValue == 1 }
        _ = try await value("const v = document.querySelector('video'); v.loop = false; v.currentTime = v.duration-0.1; true", in: source)
        try await wait("ended video closes PiP") { browser.pictureInPicture.panel == nil && source.webView.superview == nil }
        // YouTube's countdown autoplays the next video well after ended.
        _ = try await value("(() => { const v = document.querySelector('video'); v.loop = true; v.currentTime = 0; v.play(); return true })()", in: source)
        try await wait("next video floats again") { browser.pictureInPicture.panel?.alphaValue == 1 }
        XCTAssertEqual(browser.pictureInPicture.sourceTabID, source.id)
        XCTAssertTrue(source.webView.window === browser.pictureInPicture.panel)
    }

    @MainActor func testNavigationDuringReturnReattachesThePageAndZoomedCanvasFitsThePicture() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        source.webView.pageZoom = 1.5
        _ = browser.addTab()
        try await wait("zoomed PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        try await wait("canvas reaches the picture size") {
            let width = try await self.value("parseFloat(document.querySelector('html > canvas[aria-hidden]')?.style.width)", in: source) as? Double
            return abs((width ?? 0)*1.5-Double(panel.videoFrame.width)) < 0.5
        }
        browser.pictureInPicture.returnToTab()
        XCTAssertTrue(source.webView.window === panel, "Still fading back")
        browser.pictureInPicture.navigationStarted(in: source.webView)
        XCTAssertNil(browser.pictureInPicture.panel)
        XCTAssertTrue(source.webView.superview === browser.pageClip, "A page interrupted mid-return must not leave the tab blank")
    }

    @MainActor func testReturningPageIsBackInItsTabWhileTheFrozenPictureFades() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.pictureInPicture.reduceMotion = { false }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        try await wait("frames") { panel.renderedFrameCount > 3 }
        browser.pictureInPicture.returnToTab()
        try await wait("page returns", timeout: 2) { source.webView.superview === browser.pageClip }
        XCTAssertTrue(panel.isVisible && panel.isDismissing, "The page must not wait for the fade")
        XCTAssertTrue(panel.showsFrozenFrame)
        XCTAssertTrue(browser.window?.firstResponder === source.webView)
        try await assertValue("document.querySelector('html > canvas[aria-hidden]') === null", in: source, equals: true)
        try await wait("fade finishes") { browser.pictureInPicture.panel == nil }
        XCTAssertTrue(source.webView.superview === browser.pageClip)
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
    }

    @MainActor func testSwitchingAwayDuringTheReturnFadeFloatsTheLivePageAgain() async throws {
        let browser = browser(); defer { clean(browser) }
        browser.pictureInPicture.reduceMotion = { false }
        let source = try await fixture(in: browser)
        let other = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        browser.pictureInPicture.returnToTab()
        try await wait("page returns", timeout: 2) { source.webView.superview === browser.pageClip }
        browser.select(other.id)
        try await wait("PiP resumes") { panel.alphaValue == 1 && !panel.isDismissing && !panel.showsFrozenFrame }
        XCTAssertTrue(browser.pictureInPicture.panel === panel)
        XCTAssertTrue(source.webView.window === panel)
        let frames = panel.renderedFrameCount
        try await wait("live frames again") { panel.renderedFrameCount > frames+2 }
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
    }

    @MainActor func testAbandonedTwoFingerDragSettlesWithoutItsLiftOff() async throws {
        _ = NSApplication.shared
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: try XCTUnwrap(NSScreen.main)); defer { panel.closeImmediately() }
        panel.orderFrontRegardless(); panel.alphaValue = 1; panel.abandonedDragTimeout = 0.2
        panel.handleGesture(.init(phase: .began, timestamp: 10))
        panel.handleGesture(.init(phase: .changed, translation: CGVector(dx: 40, dy: 40), timestamp: 10.01))
        XCTAssertTrue(panel.isDragging)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(panel.isDragging, "Resting fingers keep the drag")
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertFalse(panel.isDragging)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let limits = FloatingVideoMotion.originBounds(size: panel.frame.size, visibleFrame: screen.visibleFrame, contentInset: FloatingVideoWindow.shadowInset)
        XCTAssertEqual(panel.frame.minX, limits.minX, accuracy: 0.5, "Without lift-off momentum it settles to the nearest corner")
        XCTAssertEqual(panel.frame.minY, limits.minY, accuracy: 0.5)
    }

    /// A real magnify event, as the window server delivers it: to the key
    /// browser window rather than the floating panel under the pointer.
    @MainActor private func pinch(_ phase: Int64, _ value: Double, at point: NSPoint, in window: NSWindow?) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = try XCTUnwrap(CGEventType(rawValue: 29)) // gesture
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 110)), value: 8) // zoom
        event.setDoubleValueField(try XCTUnwrap(CGEventField(rawValue: 113)), value: value)
        event.setIntegerValueField(try XCTUnwrap(CGEventField(rawValue: 132)), value: phase) // 1 began, 2 changed, 4 ended
        let primary = try XCTUnwrap(NSScreen.screens.first).frame
        event.location = CGPoint(x: point.x, y: primary.maxY-point.y)
        let pinch = try XCTUnwrap(NSEvent(cgEvent: event))
        XCTAssertEqual(pinch.type, .magnify)
        return pinch
    }

    @MainActor func testPinchOverThePictureResizesItWhenDeliveredToTheBrowserWindow() async throws {
        let browser = browser(); defer { clean(browser) }
        _ = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        let original = panel.videoFrame
        let center = NSPoint(x: original.midX, y: original.midY)
        // Through AppKit's own queue and event monitors.
        for event in [try pinch(1, 0, at: center, in: browser.window), try pinch(2, 0.2, at: center, in: browser.window)] {
            NSApp.postEvent(event, atStart: false)
        }
        while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        XCTAssertEqual(panel.videoFrame.width, original.width*1.2, accuracy: 1, "A pinch over the picture resizes it")
        // Ends even though the picture grew out from under the pointer.
        XCTAssertNil(panel.routePinch(try pinch(4, 0, at: NSPoint(x: -50000, y: -50000), in: nil)))
        try await wait("pinch settles") { !panel.isDragging }
        let elsewhere = try pinch(1, 0.2, at: NSPoint(x: panel.videoFrame.maxX+300, y: panel.videoFrame.maxY+300), in: nil)
        if !panel.videoFrame.contains(NSEvent.mouseLocation) {
            XCTAssertNotNil(panel.routePinch(elsewhere), "Pinches elsewhere stay with their window")
        }
    }

    @MainActor func testATrackpadPinchReachesWhicheverPartOfThePictureIsUnderThePointer() async throws {
        let browser = browser(); defer { clean(browser) }
        _ = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        let content = try XCTUnwrap(panel.contentView)
        // A real pinch reaches the panel as a raw gesture, which AppKit turns
        // into magnify(with:) on the view under the pointer.
        let video = panel.videoFrame
        let points = [NSPoint(x: video.midX, y: video.midY), NSPoint(x: video.minX+26, y: video.maxY-26),
                      NSPoint(x: video.midX, y: video.minY+17), NSPoint(x: video.minX+70, y: video.midY+20)]
        for (index, point) in points.enumerated() {
            let view = try XCTUnwrap(content.hitTest(panel.convertPoint(fromScreen: point)))
            XCTAssertFalse(view is WKWebView)
            let before = panel.videoFrame.width, delta = index.isMultiple(of: 2) ? 0.1 : -0.1
            for (phase, value) in [(Int64(1), 0.0), (2, delta), (4, 0)] {
                view.magnify(with: try pinch(phase, value, at: point, in: panel))
            }
            XCTAssertEqual(panel.videoFrame.width, before*(1+delta), accuracy: 1, "A pinch over \(type(of: view)) resizes the picture")
        }
    }

    @MainActor func testTheShadowMarginPassesClicksAndHoverToTheWindowsBeneath() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        let video = panel.videoFrame
        func takesMouse(at point: NSPoint) -> Bool {
            panel.pointerLocation = { point }; panel.updateMousePassThrough()
            return !panel.ignoresMouseEvents
        }
        XCTAssertTrue(takesMouse(at: NSPoint(x: video.midX, y: video.midY)))
        XCTAssertTrue(takesMouse(at: NSPoint(x: video.minX+1, y: video.midY)))
        XCTAssertFalse(takesMouse(at: NSPoint(x: video.minX-1, y: video.midY)), "The shadow margin beside the picture")
        XCTAssertFalse(takesMouse(at: NSPoint(x: video.maxX+30, y: video.maxY+30)))
        XCTAssertFalse(takesMouse(at: NSPoint(x: video.minX+1, y: video.minY+1)), "Outside the rounded corner")
        XCTAssertTrue(takesMouse(at: NSPoint(x: video.maxX-26, y: video.maxY-26)), "The return button")
        XCTAssertGreaterThan(panel.frame.width, video.width, "The shadow keeps its margin")
        browser.select(source.id)
        try await wait("PiP returns") { panel.isDismissing || !panel.isVisible }
        XCTAssertFalse(takesMouse(at: NSPoint(x: video.midX, y: video.midY)), "A fading picture never takes clicks")
    }

    @MainActor func testSpaceTogglesPlaybackOnlyWhileThePointerIsOverThePicture() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        func space(repeat isARepeat: Bool = false, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: browser.window?.windowNumber ?? 0,
                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: isARepeat, keyCode: 49))
        }
        let inside = NSPoint(x: panel.videoFrame.midX, y: panel.videoFrame.minY+8)
        let outside = NSPoint(x: panel.videoFrame.maxX+40, y: panel.videoFrame.midY)
        XCTAssertNotNil(panel.routeSpace(try space(), pointer: outside), "Space elsewhere belongs to the browser")
        XCTAssertNotNil(panel.routeSpace(try space(modifiers: .command), pointer: inside))
        XCTAssertNil(panel.routeSpace(try space(), pointer: inside))
        XCTAssertTrue(panel.overlay.playButton.paused)
        try await wait("video pauses") { try await self.value("document.querySelector('video').paused", in: source) as? Bool == true }
        XCTAssertNil(panel.routeSpace(try space(repeat: true), pointer: inside), "Held Space is consumed without toggling again")
        try await Task.sleep(for: .milliseconds(100))
        try await assertValue("document.querySelector('video').paused", in: source, equals: true)
        XCTAssertNil(panel.routeSpace(try space(), pointer: inside))
        try await wait("video resumes") { try await self.value("document.querySelector('video').paused", in: source) as? Bool == false }
    }

    @MainActor func testSpaceOverThePictureNeverScrollsThePageBehindIt() async throws {
        let browser = browser(); defer { clean(browser) }
        _ = try await fixture(in: browser)
        let page = browser.addTab()
        page.webView.loadHTMLString("<body style='height:5000px'>Tall</body>", baseURL: URL(string: "https://example.com/"))
        try await wait("page loads") { !page.webView.isLoading && page.webView.url != nil }
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        browser.window?.makeKeyAndOrderFront(nil); browser.window?.makeFirstResponder(page.webView)
        func press(pointer: NSPoint) throws {
            panel.pointerLocation = { pointer }
            // Through AppKit's queue and event monitors, as the keyboard delivers it.
            for type in [NSEvent.EventType.keyDown, .keyDown, .keyUp] {
                NSApp.postEvent(try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: browser.window?.windowNumber ?? 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                    isARepeat: false, keyCode: 49)), atStart: false)
            }
            while let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
        try press(pointer: NSPoint(x: panel.videoFrame.midX, y: panel.videoFrame.minY+8))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(panel.overlay.playButton.paused, "Two presses toggled twice")
        try await assertValue("scrollY", in: page, equals: 0)
        // The same presses with the pointer elsewhere do scroll, so the check above is meaningful.
        try press(pointer: NSPoint(x: panel.videoFrame.maxX+400, y: panel.videoFrame.maxY+400))
        try await wait("Space scrolls the page when not over the picture") {
            (try await self.value("scrollY", in: page) as? Double ?? 0) > 0
        }
    }

    @MainActor func testMinimizeHidesThePictureAndKeepsPlayingUntilTheTabIsShownAgain() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        let other = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        browser.pictureInPicture.minimizeVideo()
        try await wait("PiP hides") { browser.pictureInPicture.panel == nil }
        XCTAssertNil(source.webView.superview)
        let before = try await value("document.querySelector('video').currentTime", in: source) as? Double ?? 0
        try await Task.sleep(for: .milliseconds(300))
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
        let after = try await value("document.querySelector('video').currentTime", in: source) as? Double ?? 0
        XCTAssertGreaterThan(after, before, "Minimized video keeps playing in its hidden tab")
        let third = browser.addTab(); browser.select(other.id); browser.select(third.id)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(browser.pictureInPicture.panel, "Switching among other tabs does not bring it back")
        browser.select(source.id); browser.select(other.id)
        try await wait("floats again after the tab was shown") { browser.pictureInPicture.panel?.alphaValue == 1 }
    }

    @MainActor func testTabPlayButtonPlaysAndPausesItsVideoShownOrInTheBackground() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        let row = try XCTUnwrap(browser.sidebar.rows[source.id])
        try await wait("row knows the video plays") { row.playbackPaused == false }
        let hover = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        XCTAssertTrue(row.playback.isHidden, "Only on hover")
        row.mouseEntered(with: hover); row.layoutSubtreeIfNeeded()
        XCTAssertFalse(row.playback.isHidden); XCTAssertFalse(row.close.isHidden)
        XCTAssertEqual(row.playback.frame.size, row.close.frame.size)
        XCTAssertEqual(row.playback.frame.midY, row.close.frame.midY)
        XCTAssertLessThan(row.playback.frame.maxX, row.close.frame.minX, "Just left of the close button")
        XCTAssertTrue(row.hitTest(row.convert(NSPoint(x: row.playback.frame.midX, y: row.playback.frame.midY), to: row.superview)) === row.playback)
        func video(paused: Bool) async throws {
            try await wait(paused ? "video pauses" : "video plays") {
                try await self.value("document.querySelector('video').paused", in: source) as? Bool == paused
            }
        }
        XCTAssertFalse(row.playback.paused)
        _ = row.playback.accessibilityPerformPress()
        XCTAssertTrue(row.playback.paused, "The button swaps at once")
        try await video(paused: true)
        _ = row.playback.accessibilityPerformPress()
        try await video(paused: false)

        // In a background tab, its page out of the window.
        let other = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        browser.pictureInPicture.minimizeVideo()
        try await wait("PiP hides") { browser.pictureInPicture.panel == nil }
        XCTAssertNil(source.webView.superview)
        _ = row.playback.accessibilityPerformPress()
        try await video(paused: true)
        XCTAssertTrue(row.playbackPaused == true)
        _ = row.playback.accessibilityPerformPress()
        try await video(paused: false)
        try await wait("row follows") { row.playbackPaused == false && !row.playback.paused }

        let plain = try XCTUnwrap(browser.sidebar.rows[other.id])
        plain.mouseEntered(with: hover)
        XCTAssertFalse(plain.close.isHidden); XCTAssertTrue(plain.playback.isHidden, "Tabs without a video have no play button")
    }

    @MainActor func testProgressFollowsPlaybackSeeksAndThePlayButtonFollowsThePage() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        let progress = panel.overlay.progress
        try await wait("progress shows") { !progress.isHidden && progress.fraction > 0 }
        let durationValue = try await value("document.querySelector('video').duration", in: source) as? Double
        let duration = try XCTUnwrap(durationValue)
        panel.onSeek?(0.25, false); panel.onSeek?(0.6, true)
        try await wait("seek lands") {
            let time = try await self.value("document.querySelector('video').currentTime", in: source) as? Double ?? 0
            return abs(time-duration*0.6) < 0.4
        }
        try await wait("progress follows") { abs(progress.fraction-0.6) < 0.1 }
        _ = try await value("document.querySelector('video').pause(); true", in: source)
        try await wait("button shows play") { panel.overlay.playButton.paused }
        panel.onTogglePlayback?()
        try await wait("video resumes") { try await self.value("document.querySelector('video').paused", in: source) as? Bool == false }
        try await wait("button shows pause") { !panel.overlay.playButton.paused }
    }

    @MainActor func testControlsShowOnHoverAndGlassControlsClickWithoutTogglingPlayback() throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let panel = FloatingVideoWindow(aspectRatio: 16.0/9, screen: screen); defer { panel.closeImmediately() }
        var closes = 0, returns = 0, toggles = 0, minimizes = 0
        panel.onClose = { closes += 1 }; panel.onReturn = { returns += 1 }; panel.onTogglePlayback = { toggles += 1 }
        panel.onMinimize = { minimizes += 1 }
        panel.orderFrontRegardless(); panel.alphaValue = 1; panel.contentView?.layoutSubtreeIfNeeded()
        let overlay = panel.overlay
        XCTAssertFalse(overlay.controlsVisible, "Controls stay hidden until the pointer is over the video")
        overlay.mouseEntered(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertTrue(overlay.controlsVisible)
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                panel.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
        }
        let video = panel.videoFrame.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
        click(NSPoint(x: video.minX+26, y: video.maxY-26))
        XCTAssertEqual(closes, 1); XCTAssertEqual(toggles, 0, "A glass control click must not reach the video")
        click(NSPoint(x: video.maxX-26, y: video.maxY-26))
        XCTAssertEqual(returns, 1); XCTAssertEqual(toggles, 0)
        click(NSPoint(x: video.minX+61, y: video.maxY-26))
        XCTAssertEqual(minimizes, 1); XCTAssertEqual(toggles, 0)
        XCTAssertFalse(panel.overlay.playButton.paused)
        click(NSPoint(x: video.midX, y: video.midY))
        XCTAssertEqual(toggles, 1); XCTAssertTrue(panel.overlay.playButton.paused, "The button swaps at once")
        click(NSPoint(x: video.midX+video.width/4, y: video.midY))
        XCTAssertEqual(toggles, 2, "The rest of the picture still toggles"); XCTAssertFalse(panel.overlay.playButton.paused)
        overlay.mouseExited(with: try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        XCTAssertFalse(overlay.controlsVisible)
    }

    @MainActor func testTrackpadFingerPhaseFlicksTheRealWindowAndSystemMomentumDoesNotDismissIt() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        _ = browser.addTab()
        try await wait("gesture PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        let original = panel.frame
        panel.handleGesture(.init(phase: .began, timestamp: 10))
        for step in 1...8 {
            panel.handleGesture(.init(phase: .changed, translation: CGVector(dx: 150, dy: 150), timestamp: 10+Double(step)/120))
            try await Task.sleep(for: .milliseconds(9))
        }
        panel.handleGesture(.init(phase: .ended, momentumPhase: .began, timestamp: 10.07))
        // Some devices include a changed phase in momentum events. This must
        // not start another drag or replace the custom corner spring.
        panel.handleGesture(.init(phase: .changed, momentumPhase: .changed, translation: CGVector(dx: 10000, dy: -10000), timestamp: 10.08))
        try await Task.sleep(for: .milliseconds(1600))
        XCTAssertNotEqual(panel.frame.origin, original.origin)
        let visible = try XCTUnwrap(panel.screen).visibleFrame
        let area = FloatingVideoMotion.placementArea(visibleFrame: visible, browserFrame: browser.window?.frame)
        let limits = FloatingVideoMotion.originBounds(size: panel.frame.size, visibleFrame: area, contentInset: FloatingVideoWindow.shadowInset)
        XCTAssertTrue(visible.contains(panel.videoFrame))
        XCTAssertTrue(abs(panel.frame.minX-limits.minX) < 0.5 || abs(panel.frame.minX-limits.maxX) < 0.5)
        XCTAssertTrue(abs(panel.frame.minY-limits.minY) < 0.5 || abs(panel.frame.minY-limits.maxY) < 0.5)
        XCTAssertTrue(panel.isVisible); XCTAssertFalse(panel.isDismissing)
        XCTAssertTrue(source.webView.window === panel)
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
    }

    @MainActor func testPinchResizesTheRealWindowAndRestoresBothLimitsWithoutChangingPlayback() async throws {
        let browser = browser(); defer { clean(browser) }
        let source = try await fixture(in: browser)
        let viewport = source.webView.frame.size
        _ = browser.addTab()
        try await wait("pinch PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        let panel = try XCTUnwrap(browser.pictureInPicture.panel)
        let original = panel.videoFrame
        panel.handleMagnification(0, phase: .began)
        panel.handleMagnification(0.3, phase: .changed)
        XCTAssertEqual(panel.videoFrame.width, original.width*1.3, accuracy: 0.01)
        XCTAssertEqual(panel.videoFrame.minX, original.minX, accuracy: 0.01)
        XCTAssertEqual(panel.videoFrame.minY, original.minY, accuracy: 0.01)
        panel.handleMagnification(0, phase: .ended)
        let visible = try XCTUnwrap(panel.screen).visibleFrame
        for delta: CGFloat in [100, -100] {
            let sizing = FloatingVideoResizeMotion(videoFrame: panel.videoFrame, visibleFrame: visible)
            let limit = delta > 0 ? sizing.maximumWidth : sizing.minimumWidth
            panel.handleMagnification(0, phase: .began)
            panel.handleMagnification(delta, phase: .changed)
            XCTAssertGreaterThan(abs(panel.videoFrame.width-limit), 0)
            XCTAssertLessThanOrEqual(abs(panel.videoFrame.width-limit), 20.5)
            panel.handleMagnification(0, phase: .ended)
            try await wait("pinch spring restores limit") { abs(panel.videoFrame.width-limit) <= 0.5 }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertEqual(panel.videoFrame.width, limit, accuracy: 0.5)
            XCTAssertTrue(visible.contains(panel.videoFrame))
        }
        XCTAssertEqual(source.webView.frame.size, viewport)
        let frames = panel.renderedFrameCount
        try await wait("frames still update after pinching") { panel.renderedFrameCount > frames+2 }
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
        browser.pictureInPicture.returnToTab()
        try await wait("pinched player returns") { browser.pictureInPicture.panel == nil && source.webView.superview === browser.pageClip }
        try await assertValue("document.querySelector('video').paused", in: source, equals: false)
    }

    @MainActor func testSwitchCanProbePlaybackBeforeMediaStateArrivesAndNewVideoReplacesOldPiP() async throws {
        let browser = browser(); defer { clean(browser) }
        let first = try await fixture(in: browser)
        browser.pictureInPicture.navigationStarted(in: first.webView)
        XCTAssertFalse(browser.pictureInPicture.isPlaying(first))
        _ = browser.addTab()
        try await wait("DOM probe starts PiP") { browser.pictureInPicture.panel?.alphaValue == 1 }
        XCTAssertEqual(browser.pictureInPicture.sourceTabID, first.id)
        let second = try await fixture(in: browser)
        let other = browser.addTab()
        try await wait("new video replaces the old floating player") {
            browser.pictureInPicture.sourceTabID == second.id && browser.pictureInPicture.panel?.alphaValue == 1
        }
        XCTAssertEqual(browser.selectedID, other.id)
        try await wait("old player finishes its return") { first.webView.superview == nil }
        try await assertValue("document.querySelector('video').paused", in: first, equals: true)
        try await assertValue("document.querySelector('video').paused", in: second, equals: false)
        XCTAssertTrue(second.webView.window === browser.pictureInPicture.panel)
    }
}
