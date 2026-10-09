import XCTest
import AppKit
import WebKit
@testable import Rise

final class TabMediaTests: XCTestCase {
    private var preferenceSuites: [String] = []
    override func tearDown() {
        preferenceSuites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    @MainActor private func browser() -> BrowserController {
        _ = NSApplication.shared
        let suite = "Rise.TabMediaTests.\(UUID().uuidString)"
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
        throw NSError(domain: "TabMediaTests", code: 1)
    }
    private func videoSource() throws -> String {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "PiPTestVideo", withExtension: "mp4", subdirectory: "Resources"))
        return "data:video/mp4;base64," + (try Data(contentsOf: file).base64EncodedString())
    }
    @MainActor private func page(_ html: String, in browser: BrowserController) async throws -> BrowserTab {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let tab = browser.addTab(configuration: configuration)
        tab.webView.loadHTMLString(html, baseURL: URL(string: "https://media.example/"))
        try await wait("page loads") {
            guard !tab.webView.isLoading else { return false }
            return try await tab.webView.evaluateJavaScript("document.readyState") as? String == "complete"
        }
        return tab
    }
    @MainActor private func paused(_ script: String, in tab: BrowserTab) async throws -> Bool? {
        try await tab.webView.evaluateJavaScript(script) as? Bool
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

        _ = try await tab.webView.evaluateJavaScript("main.play(); 0")
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

        _ = try await tab.webView.evaluateJavaScript("main.pause(); 0")
        try await wait("row follows the page's own pause") { row.playbackPaused == true && row.playback.paused }

        _ = try await tab.webView.evaluateJavaScript("main.remove(); 0")
        try await wait("removed media takes its button with it", timeout: 5) { row.playbackPaused == nil }

        tab.webView.loadHTMLString("<p>Next page</p>", baseURL: URL(string: "https://other.example/"))
        try await wait("next page") { tab.webView.url?.host == "other.example" && !tab.webView.isLoading }
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
        _ = try await tab.webView.evaluateJavaScript("frame.contentDocument.querySelector('video').play(); 0")
        try await wait("row knows the frame plays") { row.playbackPaused == false }
        _ = row.playback.accessibilityPerformPress()
        try await wait("frame's media pauses") { try await self.paused(framed, in: tab) == true }
        _ = row.playback.accessibilityPerformPress()
        try await wait("frame's media resumes") { try await self.paused(framed, in: tab) == false }
        _ = try await tab.webView.evaluateJavaScript("frame.contentDocument.querySelector('video').pause(); 0")
        try await wait("row follows") { row.playbackPaused == true }

        // Media the page plays without adding it to the document.
        _ = try await tab.webView.evaluateJavaScript("window.loose = document.createElement('video'); loose.loop = true; loose.src = '\(source)'; loose.play(); 0")
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
