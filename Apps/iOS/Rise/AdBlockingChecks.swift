#if DEBUG
import UIKit
import WebKit

/// Running-app equivalent of the native regressions, for toolchains whose Simulator
/// XCTest service is unavailable. It uses the actual catalog, settings and reload path.
@MainActor enum AdBlockingChecks {
    private struct Failed: Error { let message: String }
    static func run(in browser: BrowserViewController) async throws -> [String] {
        var checks: [String] = []
        func check(_ condition: Bool, _ description: String) throws {
            guard condition else { throw Failed(message: description) }
            checks.append(description)
        }
        let blocker = browser.adBlocker
        let page = browser.webView
        let fixture = try AdBlockHTTPFixture()
        try await fixture.start(); defer { fixture.stop() }
        page.load(URLRequest(url: fixture.url))
        try await loaded(page)
        try check(blocker.isInstalled(on: page), "Native catalog compiled and installed")
        let normal = try await page.evaluateJavaScript("window.normalLoaded") as? Bool
        let ad = try await page.evaluateJavaScript("window.adLoaded") as? Bool
        try check(normal == true && ad == nil, "Normal script loaded; real ad-pattern request blocked")
        let main = try await page.evaluateJavaScript("document.querySelector('main').textContent") as? String
        try check(main == "Normal article", "Article content preserved")
        let normalScripts = page.configuration.userContentController.userScripts.filter { !$0.source.hasPrefix(MobileAdBlocker.scriptMarker) }.map(\.source)
        browser.openPanel(.menu); browser.openSiteSettings()
        try await Task.sleep(for: .milliseconds(600))
        let panel = browser.bottomBar.siteSettings
        panel.switches[0].setOn(false, animated: false); panel.switches[0].sendActions(for: .valueChanged)
        try check(panel.isUpdatingAdBlocking && !panel.switches[0].isEnabled, "Native spinner starts and row locks during reload")
        try await settled(browser)
        let allowed = try await page.evaluateJavaScript("window.adLoaded") as? Bool
        try check(allowed == true && !blocker.isInstalled(on: page), "Turning off reloads with ads allowed")
        try check(page.configuration.userContentController.userScripts.map(\.source) == normalScripts, "Rise viewport and paint scripts preserved")
        try check(panel.switches[0].isEnabled && !panel.isUpdatingAdBlocking, "Spinner stops after reload")
        panel.switches[0].setOn(true, animated: false); panel.switches[0].sendActions(for: .valueChanged)
        try await settled(browser)
        let blockedAgain = try await page.evaluateJavaScript("window.adLoaded") as? Bool
        try check(blockedAgain == nil && blocker.isInstalled(on: page) && fixture.pageRequests >= 3, "Turning on installs filtering before the second real reload")
        try check(browser.isPanelOpen && browser.bottomBar.shown === panel, "Settings panel remains open over the reloading page")
        browser.changeAdBlocking(false)
        for _ in 0..<200 where browser.adBlockingNavigation == nil { try await Task.sleep(for: .milliseconds(1)) }
        page.load(URLRequest(url: fixture.url.appendingPathComponent("replacement"))); try await settled(browser)
        try check(!panel.isUpdatingAdBlocking && panel.switches[0].isEnabled, "Interrupted reload clears spinner")
        browser.closePanel()

        let cosmetic = WKWebView(), url = URL(string: "https://example.com/")!
        let html = "<html><body><main>Normal article</main><div id='ad-slot-1'>Advertisement</div></body></html>"
        try await blocker.prepare(cosmetic, for: url)
        cosmetic.loadHTMLString(html, baseURL: url); try await loaded(cosmetic)
        let hidden = try await cosmetic.evaluateJavaScript("getComputedStyle(document.getElementById('ad-slot-1')).display") as? String
        try check(hidden == "none", "Native cosmetic filtering hides the ad slot on a public origin")
        blocker.setEnabled(false, for: url); try await blocker.prepare(cosmetic, for: url)
        cosmetic.loadHTMLString(html, baseURL: url); try await loaded(cosmetic)
        let shown = try await cosmetic.evaluateJavaScript("getComputedStyle(document.getElementById('ad-slot-1')).display") as? String
        try check(shown == "block", "Disabling removes cosmetic filtering on the next document")
        blocker.setEnabled(true, for: url)

        let detector = WKWebView(), detectorURL = URL(string: "https://reporterpb.com.br/")!
        try await blocker.prepare(detector, for: detectorURL)
        detector.loadHTMLString("<html><body>Real content<script>window.showModal=()=> 'detected'; window.modalResult=showModal();</script></body></html>", baseURL: detectorURL)
        try await loaded(detector)
        let detection = try await detector.evaluateJavaScript("window.modalResult") as? String
        try check(detection == nil, "Maintained anti-detector fix runs before the inline script")
        for host in ["www.youtube.com", "m.youtube.com", "youtube-nocookie.com", "youtu.be", "youtubekids.com"] {
            let youtube = URL(string: "https://"+host+"/")!
            blocker.setEnabled(true, for: youtube)
            try await blocker.prepare(detector, for: youtube)
            try check(!blocker.isEnabled(for: youtube) && !blocker.isInstalled(on: detector), "Hard exclusion: "+host)
        }
        try check(!detector.configuration.userContentController.userScripts.contains { $0.source.hasPrefix(MobileAdBlocker.scriptMarker) }, "No blocker scripts remain on YouTube")

        // Test the native fallback while keeping the catalog deliberately installed.
        try await blocker.prepare(detector, for: url)
        detector.loadHTMLString(AdBlockHTTPFixture.html(scriptBase: fixture.url.absoluteString), baseURL: URL(string: "http://www.youtube.com/"))
        try await loaded(detector)
        let exemptAd = try await detector.evaluateJavaScript("window.adLoaded") as? Bool
        let exemptCSS = try await detector.evaluateJavaScript("getComputedStyle(document.getElementById('ad-slot-1')).display") as? String
        try check(exemptAd == true && exemptCSS == "block", "YouTube fallback exempts native network and cosmetic rules in every shard")
        let other = MobileAdBlocker(preferences: UserDefaults(suiteName: "Rise.AdBlock.Audit.Other")!)
        try await other.prepare(detector, for: URL(string: "https://youtu.be/"))
        try await blocker.prepare(detector, for: url)
        try check(blocker.isInstalled(on: detector), "Catalog can be reinstalled after a page changes owners")
        return checks
    }

    private static func loaded(_ page: WKWebView) async throws {
        for _ in 0..<1500 {
            if !page.isLoading, (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" {
                try await Task.sleep(for: .milliseconds(150)); return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failed(message: "Fixture navigation timed out")
    }
    private static func settled(_ browser: BrowserViewController) async throws {
        for _ in 0..<1500 {
            if !browser.bottomBar.siteSettings.isUpdatingAdBlocking { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Failed(message: "Settings spinner never completed")
    }
}
#endif
