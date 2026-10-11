import AppKit
import WebKit
import XCTest
@testable import Rise

@MainActor final class PageFullscreenTests: XCTestCase {
    private func page(simulated: Bool, fullscreen: PageFullscreen? = nil) async throws -> (WKWebView, NSWindow) {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        if fullscreen == nil { configuration.userContentController.addUserScript(PageFullscreen.userScript(simulated: simulated)) }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        fullscreen?.install(on: web)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = web; window.orderBack(nil)
        web.loadHTMLString("""
        <style> #box:fullscreen { outline: 3px solid rgb(0, 128, 0) } .wrap { transform: scale(0.5); overflow: hidden; width: 300px; height: 200px } </style>
        <div class=wrap><div id=box style="width:100px;height:50px">box</div></div>
        <script> window.events = []; document.addEventListener('fullscreenchange', () => events.push(document.fullscreenElement?.id || 'null')); </script>
        """, baseURL: URL(string: "https://fullscreen.example/"))
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (web, window)
    }
    private func value(_ web: WKWebView, _ source: String) async throws -> String {
        let result = try await web.evaluateJavaScript(source)
        return result.map { "\($0)" } ?? "nil"
    }

    func testSimulatedFullscreenLiftsTheElementOverThePageAndLeavesCleanly() async throws {
        let (web, window) = try await page(simulated: true)
        defer { window.close() }
        _ = try await web.evaluateJavaScript("box.requestFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        let rect = try await value(web, "const r = box.getBoundingClientRect(); [r.left, r.top, r.width, r.height].join()")
        XCTAssertEqual(rect, "0,0,800,600", "A transformed, clipped ancestor can't hold the element back")
        let element = try await value(web, "document.fullscreenElement.id")
        XCTAssertEqual(element, "box")
        let outline = try await value(web, "getComputedStyle(box).outlineColor")
        XCTAssertEqual(outline, "rgb(0, 128, 0)", "The page's :fullscreen rule applies")
        XCTAssertEqual(web.fullscreenState, .notInFullscreen)
        _ = try await web.evaluateJavaScript("document.exitFullscreen(); 0")
        try await Task.sleep(for: .milliseconds(300))
        let events = try await value(web, "events.join()")
        XCTAssertEqual(events, "box,null")
        let leftovers = try await value(web, "document.querySelectorAll('[data-rise-fullscreen], [data-rise-fullscreen-ancestor], [popover]').length")
        XCTAssertEqual(leftovers, "0")
    }

    func testNativeModeLeavesTheFullscreenAPIToWebKit() async throws {
        let (web, window) = try await page(simulated: false)
        defer { window.close() }
        let simulated = try await value(web, "String(window.__riseFullscreen.simulated)")
        XCTAssertEqual(simulated, "false")
        // Long after the gesture, so WebKit refuses rather than taking over the screen during tests.
        _ = try await web.evaluateJavaScript("setTimeout(() => box.requestFullscreen().catch(e => window.refused = e.name), 1200); 0")
        try await Task.sleep(for: .milliseconds(1600))
        let refused = try await value(web, "window.refused")
        XCTAssertEqual(refused, "TypeError", "WebKit's own requestFullscreen answered")
        let pinned = try await value(web, "document.querySelectorAll('[data-rise-fullscreen]').length")
        XCTAssertEqual(pinned, "0", "Native mode never pins the element itself")
    }

    func testScriptReportsEntryReplacementExitAndElementRemovalToTheBrowser() async throws {
        let suite = "PageFullscreenTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(true, forKey: PageFullscreen.simulatedKey)
        let fullscreen = PageFullscreen(preferences: preferences)
        let (web, window) = try await page(simulated: true, fullscreen: fullscreen)
        defer { window.close() }
        var changes: [Bool] = []
        fullscreen.onChange = { changes.append(fullscreen.isActive(in: web)) }
        defer { fullscreen.onChange = nil }
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

    func testSwitchingModesRewritesTheScriptForLaterPages() async throws {
        let suite = "PageFullscreenTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let fullscreen = PageFullscreen(preferences: preferences)
        XCTAssertFalse(fullscreen.isSimulated, "Simulated fullscreen is off unless chosen")
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let other = WKUserScript(source: "window.other = 1", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        web.configuration.userContentController.addUserScript(other)
        fullscreen.install(on: web)
        fullscreen.setSimulated(true, in: [web])
        XCTAssertTrue(preferences.bool(forKey: PageFullscreen.simulatedKey))
        let scripts = web.configuration.userContentController.userScripts
        XCTAssertEqual(scripts.count, 2, "Other scripts stay; the fullscreen script is replaced, not added again")
        XCTAssertTrue(scripts.contains { $0.source.contains("let simulated = true;") })
        XCTAssertTrue(scripts.contains { $0 === other })
    }

    func testPlaqueSplitsMessagesAtTheWordsTheyShare() {
        XCTAssertEqual(InfoPlaque.split("Native full screen enabled", "Simulated full screen enabled").rest, "full screen enabled")
        XCTAssertEqual(InfoPlaque.split("Native full screen enabled", "Simulated full screen enabled").new, "Simulated")
        XCTAssertEqual(InfoPlaque.split("Saved", "Copied").rest, "", "Nothing shared swaps the whole message")
        XCTAssertEqual(InfoPlaque.split("Link copied", "copied").new, "copied", "At least one word always swaps")
    }

    func testShortcutTogglesTheSettingAndShowsThePlaque() throws {
        let suite = "PageFullscreenTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let session = FileManager.default.temporaryDirectory.appendingPathComponent("rise-fullscreen-\(UUID().uuidString)/session.json")
        let browser = BrowserController(sessionURL: session, restore: false, preferences: preferences)
        browser.toggleSimulatedFullscreen()
        XCTAssertTrue(browser.pageFullscreen.isSimulated)
        XCTAssertTrue(browser.infoPlaque.isPresented)
        XCTAssertEqual(browser.infoPlaque.text, "Simulated full screen enabled")
        let narrow = browser.infoPlaque.panelWidth
        browser.toggleSimulatedFullscreen()
        XCTAssertEqual(browser.infoPlaque.text, "Native full screen enabled")
        XCTAssertNotEqual(browser.infoPlaque.panelWidth, narrow, "The plaque fits its text")
        XCTAssertEqual(browser.infoPlaque.lead, "Native", "Toggling while it shows swaps only the word that changed")
        XCTAssertEqual(browser.infoPlaque.rest, "full screen enabled")
        browser.toggleSimulatedFullscreen()
        XCTAssertEqual(browser.infoPlaque.lead, "Simulated")
        XCTAssertEqual(browser.infoPlaque.text, "Simulated full screen enabled")
        browser.toggleSimulatedFullscreen()
        let item = browser.makeMoreSiteMenu().items.first { $0.title == "Simulated Full Screen" }
        XCTAssertEqual(item?.state, .off)
        browser.window?.close()
    }
}
