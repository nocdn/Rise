#if DEBUG
import UIKit
import WebKit

/// Real taps use the native desktop Simulator. No fake trusted events or testing
/// bypass is added to the production guard. Start scripts/ios-popups/fixtures.py,
/// then launch with -RisePopupAudit http://127.0.0.1:8765.
@MainActor enum PopupBlockingAudit {
    static let argument = "-RisePopupAudit"
    private struct Failed: Error { let message: String }
    static func run(in browser: BrowserViewController) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index+1),
              let base = URL(string: arguments[index+1]) else { return }
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PopupAudit")
        Task {
            do {
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("cases"))
                var cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
                if let selection = URLComponents(url: base, resolvingAgainstBaseURL: true)?.queryItems?.first(where: { $0.name == "cases" })?.value {
                    let names = Set(selection.split(separator: ",").map(String.init))
                    cases = cases.filter { names.contains($0["name"] as? String ?? "") }
                }
                var results: [[String: Any]] = []
                for (index, item) in cases.enumerated() {
                    let name = item["name"] as! String
                    let page = browser.webView, url = base.appendingPathComponent("case/"+name)
                    browser.adBlocker.setEnabled(false, for: url)
                    browser.adBlocker.cookieBanners.setEnabled(false, for: url)
                    browser.adBlocker.popups.setEnabled(item["disabled"] as? Bool != true, for: url)
                    page.load(URLRequest(url: url))
                    try await loaded(page)
                    let bridgeHidden = (try? await page.evaluateJavaScript("typeof window.webkit?.messageHandlers?.risePopupIntent === 'undefined'")) as? Bool == true
                    let count = browser.tabs.count
                    let automatic = item["automatic"] as? Bool == true
                    try write(["case": name, "index": index, "automatic": automatic], to: folder.appendingPathComponent("ready.json"))
                    if automatic {
                        _ = try? await page.evaluateJavaScript("document.getElementById('run').click()")
                    } else {
                        var tapped = false
                        for _ in 0..<3600 {
                            let clicked = (try? await page.evaluateJavaScript("window.clicked === true")) as? Bool == true
                            if page.url != url || clicked { tapped = true; break }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        guard tapped else { throw Failed(message: "No native tap for "+name) }
                    }
                    try await Task.sleep(for: .milliseconds(item["wait"] as? Int ?? 950))
                    let opened = browser.tabs.count-count
                    let target = browser.webView
                    let expected = item["tabs"] as! Int
                    let sameStore = target.configuration.websiteDataStore === page.configuration.websiteDataStore
                    let privacyPreserved = browser.isPrivateBrowsing == browser.tabs.first?.isPrivateBrowsing
                    var passed = opened == expected && bridgeHidden && sameStore && privacyPreserved
                    if let path = item["path"] as? String {
                        try await loaded(target)
                        passed = passed && target.url?.path == path
                    }
                    if let text = item["text"] as? String {
                        let content = (try? await target.evaluateJavaScript("document.body.innerText")) as? String
                        passed = passed && content?.contains(text) == true
                    }
                    if item["query"] as? Bool == true {
                        passed = passed && URLComponents(url: target.url!, resolvingAgainstBaseURL: true)?.queryItems?.contains { $0.name == "q" && $0.value?.replacingOccurrences(of: "+", with: " ") == "a & b" } == true
                    }
                    if item["post"] as? Bool == true {
                        let body = (try? await target.evaluateJavaScript("document.body.innerText")) as? String ?? ""
                        passed = passed && body.contains("POST:") && body.contains("token=fixture-token")
                    }
                    if item["selfNavigation"] as? Bool == true { passed = passed && page.url?.path == "/destination/wanted" }
                    else { passed = passed && page.url == url }
                    let trace = await browser.blocker(for: page).popups.diagnostics.snapshot()
                    let own = trace.events.filter { URL(string: $0.source ?? "")?.path == "/case/"+name }
                    var tracePassed = !own.isEmpty
                    let decisions = own.filter { $0.event == "window.decision" }
                    if ["direct-link", "scripted-button", "get-form", "post-form", "async-button", "noopener-link"].contains(name) {
                        tracePassed = tracePassed && decisions.contains { $0.details["allowed"] == "true" && $0.details["reason"]?.hasPrefix("trusted_") == true }
                    }
                    if name == "known-ad-button" {
                        tracePassed = tracePassed && decisions.contains { $0.details["reason"] == "filter" && $0.rules?.blocking.first?.filter != nil && $0.rules?.catalogID.count == 64 }
                    }
                    if name == "hijacked-link" {
                        tracePassed = tracePassed && decisions.contains { $0.details["reason"] == "destination_differs_from_tapped_control" }
                    }
                    if name == "popunder" { tracePassed = tracePassed && own.contains { $0.event == "opener.navigation" && $0.details["allowed"] == "false" } }
                    if ["blank-ad-redirect", "http-ad-redirect"].contains(name) { tracePassed = tracePassed && own.contains { $0.event == "popup.navigation" && $0.details["allowed"] == "false" && $0.chainID != nil } }
                    if ["scripted-button", "blank-then-navigate", "expired-gesture", "unactivated-window-open"].contains(name) { tracePassed = tracePassed && own.contains { $0.event == "window.open.attempt" && $0.details["trust"] == "unverified_page_world" } }
                    if name == "unactivated-window-open" {
                        tracePassed = tracePassed && own.contains { $0.event == "window.open.returned" && $0.details["handle"] == "null_or_unspecified" }
                    }
                    if name == "observer-flood" {
                        tracePassed = tracePassed && own.contains { $0.event == "observer.rate_limited" }
                            && own.filter { $0.event.hasPrefix("window.open.") }.count <= 100
                    }
                    let encodedTrace = try PopupLogRecord.encoder(pretty: true).encode(trace)
                    let exportedText = String(decoding: encodedTrace, as: UTF8.self)
                    tracePassed = tracePassed && !exportedText.contains("never-log-this-token") && !exportedText.contains("never-log-this-page-id")
                    passed = passed && tracePassed
                    try encodedTrace.write(to: folder.appendingPathComponent("diagnostics.json"))
                    results.append(["case": name, "passed": passed, "newTabs": opened,
                                    "expectedTabs": expected, "target": target.url?.absoluteString ?? "nil", "bridgeHidden": bridgeHidden,
                                    "sameStore": sameStore, "privacyPreserved": privacyPreserved, "diagnosticsPassed": tracePassed])
                    try write(results, to: folder.appendingPathComponent("results.json"))
                    print("Rise.PopupAudit \(name) \(passed ? "PASS" : "FAIL")")
                    while browser.tabs.count > count { browser.webViewDidClose(browser.webView) }
                }
                let checks = try PopupBlockingChecks.run(in: browser)
                try write(checks, to: folder.appendingPathComponent("checks.json"))
                let logging = try await PopupLoggingChecks.run()
                try write(logging, to: folder.appendingPathComponent("logging-checks.json"))
                browser.openPanel(.menu); browser.openSiteSettings()
                try await Task.sleep(for: .milliseconds(600))
                let configuration = WKSnapshotConfiguration()
                if let image = try? await browser.webView.takeSnapshot(configuration: configuration) {
                    try? image.pngData()?.write(to: folder.appendingPathComponent("page.png"))
                }
                let image = UIGraphicsImageRenderer(bounds: browser.view.bounds).image { _ in browser.view.drawHierarchy(in: browser.view.bounds, afterScreenUpdates: true) }
                try image.pngData()?.write(to: folder.appendingPathComponent("settings.png"))
                try "Completed \(results.count) native cases; failures: \(results.filter { $0["passed"] as? Bool != true }.count)".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
    private static func write(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    private static func loaded(_ page: WKWebView) async throws {
        for _ in 0..<600 {
            if !page.isLoading, (try? await page.evaluateJavaScript("document.readyState")) as? String == "complete" {
                try await Task.sleep(for: .milliseconds(150)); return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failed(message: "Fixture load timed out: \(page.url?.absoluteString ?? "nil")")
    }
}
#endif
