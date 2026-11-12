// Links received by the app delegate reuse a live page, and zoom's reset, notices and presence
// animations work with Chromium's real zoom values rather than only BlankPage's test values.
// RISE_LIVE_STABLE_SIGNING=1 python3 scripts/test-chromium-live.py Tests/Live/ChromiumExternalLinksZoomChecks.swift
import AppKit
import RiseChromium
@testable import Rise

@main @MainActor struct ExternalLinksZoomMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL timed out"); exit(1) }
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        let app = RCApplication.shared
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ExternalLinksZoomRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run(); withExtendedLifetime(run) {}
    }
}

@MainActor final class ExternalLinksZoomRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    func wait(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(25)) }
        if !condition() { throw NSError(domain: "Live check timed out", code: 1) }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await checks() } catch { check(false, error.localizedDescription) }
            browser?.saveWork?.cancel(); browser?.tabs.forEach { $0.cancelLoad() }; browser?.window?.close()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
    func checks() async throws {
        try "<!doctype html><title>External link fixture</title><input id='draft'><div style='height:5000px'>Keep this page's state</div>"
            .write(to: folder.appendingPathComponent("external.html"), atomically: true, encoding: .utf8)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let url = URL(string: "http://127.0.0.1:\(port)/external.html")!
        let suite = "Rise.ExternalLinksZoomLive.\(UUID())", prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        browser.window?.setContentSize(NSSize(width: 1100, height: 750)); browser.showWindow(nil)
        let tab = browser.addTab(url: url)
        try await wait { tab.page.title == "External link fixture" && !tab.isLoading }
        // Local URLs enter developer mode automatically. Exercise the normal page bar here.
        tab.developer = false; browser.update()
        try await wait { browser.navBar.developerProgress == 0 }
        _ = try await tab.page.evaluate("document.querySelector('#draft').value='keep my draft'; window.riseState='kept'; scrollTo(0,600)", arguments: [:], in: nil, world: .page)
        let other = browser.addTab(url: URL(string: "about:blank")!)
        let delegate = AppDelegate(); delegate.browser = browser
        delegate.application(NSApp, open: [url, url])
        check(browser.selectedTab === tab && browser.tabs.count == 2, "Repeated external links select the original live tab")
        let state = try await tab.page.evaluate("return [window.riseState, document.querySelector('#draft').value, Math.round(scrollY)]", arguments: [:], in: nil, world: .page) as? [Any]
        check(state?[0] as? String == "kept" && state?[1] as? String == "keep my draft" && state?[2] as? Int == 600,
              "Reusing the tab preserves JavaScript, unsaved form text and scroll")

        let bar = browser.navBar
        // Hold the hover presentation without moving the user's real pointer. Native tracking
        // can otherwise send an exit while the fixture window is becoming visible.
        bar.holdsHover = true; bar.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let normalCopyX = bar.copyButton.frame.minX
        browser.setPageZoom(1.25); bar.layoutSubtreeIfNeeded()
        check(abs(tab.page.zoom-1.25) < 0.001 && bar.notice?.text == "Set page zoom to 125%", "Chromium applies 125% and the notice agrees")
        check(bar.zoomButton.frame.minX > bar.copyButton.frame.minX, "Zoom is right of Copy Link")
        try await Task.sleep(for: .milliseconds(40))
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = bar.copyButton.layer {
            let shown = layer.presentation()?.position.x ?? layer.position.x
            check(abs(shown-layer.position.x) > 0.05 && abs(shown-normalCopyX) < 40, "The controls visibly travel into their new slots")
            if let field=bar.layer?.sublayers?.first(where:{$0.cornerRadius==PlainNavBar.Metrics.fieldRadius}) {
                let fieldEdge=field.presentation()?.frame.maxX ?? field.frame.maxX
                check(abs((fieldEdge-field.frame.maxX)-(shown-layer.position.x))<0.8,"The URL-bar edge follows the controls on the same spring")
            } else {check(false,"The address field is present")}
        }
        try await Task.sleep(for: .milliseconds(200))
        bar.zoomButton.runAction(); bar.layoutSubtreeIfNeeded()
        check(abs(tab.page.zoom-1) < 0.001 && bar.notice?.text == "Reset page zoom to 100%", "Clicking the icon resets Chromium immediately and says so")
        check(abs(bar.copyButton.frame.minX-normalCopyX) < 0.01, "The slot is released before the outgoing icon finishes fading")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            check(!bar.zoomButton.isHidden && !bar.zoomButton.allowsInteraction, "A departing icon is drawn but cannot be clicked")
        }
        try await Task.sleep(for: .milliseconds(220)); bar.layoutSubtreeIfNeeded()
        check(bar.zoomButton.isHidden, "The faded reset icon is removed")
        for _ in 0..<4 { browser.setPageZoom(1.5); bar.layoutSubtreeIfNeeded(); browser.actualSize(); bar.layoutSubtreeIfNeeded() }
        browser.setPageZoom(1.25); bar.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(220)); bar.layoutSubtreeIfNeeded()
        check(!bar.zoomButton.isHidden && bar.zoomButton.allowsInteraction && bar.zoomButton.alphaValue > 0.99,
              "Rapid zoom/reset interruptions leave the current icon visible and usable")
        bar.holdsHover = false; bar.setHovered(false); try await Task.sleep(for: .milliseconds(180))
        check(bar.zoomButton.alphaValue > 0.99 && bar.zoomButton.allowsInteraction, "Zoom stays visible outside the hover area")

        browser.setRiseSetting("reuseExternalLinks", false)
        delegate.application(NSApp, open: [url])
        check(browser.tabs.count == 3 && browser.selectedTab !== tab && browser.selectedTab !== other, "Disabling reuse opens a new tab")
    }
}
