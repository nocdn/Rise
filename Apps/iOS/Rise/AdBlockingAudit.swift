#if DEBUG
import UIKit
import WebKit

/// Optional public-site audit in the real browser. DOM/network inspection is automated;
/// snapshots are kept where visual confirmation is useful. Never runs during normal use.
@MainActor enum AdBlockingAudit {
    static let argument = "-RiseAdBlockAudit"
    static let sites = [
        "https://www.theguardian.com/international", "https://www.cnn.com/",
        "https://www.theverge.com/", "https://arstechnica.com/", "https://www.tomshardware.com/",
        "https://www.pcworld.com/", "https://www.speedtest.net/", "https://www.imdb.com/",
        "https://www.timeanddate.com/", "https://www.accuweather.com/",
        "https://www.reuters.com/", "https://www.bbc.com/", "https://www.wikipedia.org/",
        "https://news.ycombinator.com/", "https://canyoublockit.com/",
        "https://www.forbes.com/", "https://www.indiatoday.in/", "https://www.androidauthority.com/",
        "https://www.pcgamer.com/",
        "https://www.youtube.com/",
    ]
    static func makeBlocker() -> MobileAdBlocker {
        let name = "Rise.AdBlock.Audit"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return MobileAdBlocker(preferences: defaults)
    }
    static func runIfRequested(in browser: BrowserViewController) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: argument), args.indices.contains(index+1) else { return }
        let name = args[index+1].replacingOccurrences(of: "caches:", with: "")
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
        let selected = args.indices.contains(index+2) ? args[index+2].split(separator: ",").compactMap { Int($0) } : Array(sites.indices)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if args.indices.contains(index+2), args[index+2] == "fixtures" {
                do {
                    let checks = try await AdBlockingChecks.run(in: browser)
                    try checks.joined(separator: "\n").write(to: folder.appendingPathComponent("checks.txt"), atomically: true, encoding: .utf8)
                    try "Passed \(checks.count) checks\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
                    print("Rise.AdBlockAudit FIXTURES PASSED \(checks.count)")
                } catch {
                    try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
                    print("Rise.AdBlockAudit FIXTURES FAILED \(error)")
                }
                return
            }
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.addUserScript(InputZoomPolicy.userScript)
            let page = WKWebView(frame: .zero, configuration: config)
            PagePaintWatcher.shared.install(on: page)
            browser.adopt(page)
            var results: [[String: Any]] = []
            for index in selected where sites.indices.contains(index) {
                guard let url = URL(string: sites[index]) else { continue }
                for enabled in [false, true] {
                    browser.adBlocker.setEnabled(enabled, for: url)
                    let began = CACurrentMediaTime()
                    page.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
                    var reachedContent = false
                    for _ in 0..<600 {
                        try? await Task.sleep(for: .milliseconds(50))
                        let usable = (try? await page.evaluateJavaScript("document.body && document.body.innerText.length > 200 && document.readyState !== 'loading'")) as? Bool ?? false
                        if usable {
                            reachedContent = true
                            try? await Task.sleep(for: .seconds(5))
                            break
                        }
                        if !page.isLoading && CACurrentMediaTime()-began > 3 { break }
                    }
                    // Dismiss only explicit privacy-preserving consent choices in this
                    // non-persistent test session. Never subscribe or accept all cookies.
                    let dismissed = (try? await page.evaluateJavaScript(Self.rejectConsent)) as? Bool ?? false
                    if dismissed { try? await Task.sleep(for: .seconds(3)) }
                    var report = (try? await page.evaluateJavaScript(inspect)) as? [String: Any] ?? [:]
                    report["consentDismissed"] = dismissed
                    report["site"] = sites[index]; report["enabled"] = enabled
                    report["installed"] = browser.adBlocker.isInstalled(on: page)
                    report["blockerScripts"] = page.configuration.userContentController.userScripts.filter { $0.source.hasPrefix(MobileAdBlocker.scriptMarker) }.count
                    report["finalURL"] = page.url?.absoluteString ?? ""
                    report["reachedContent"] = reachedContent
                    report["elapsed"] = CACurrentMediaTime()-began
                    if MobileAdBlocker.isYouTube(page.url) {
                        browser.openPanel(.menu); browser.openSiteSettings()
                        try? await Task.sleep(for: .milliseconds(400))
                        report["youtubeSwitchOff"] = !browser.bottomBar.siteSettings.switches[0].isOn
                        report["youtubeSwitchDisabled"] = !browser.bottomBar.siteSettings.switches[0].isEnabled
                    }
                    let file = "site-\(index)-\(enabled ? "on" : "off").png"
                    // A sample of normal ad-supported pages plus every ambiguous result.
                    if index < 3 || MobileAdBlocker.isYouTube(page.url) || (report["visibleAdSlots"] as? Int ?? 0) > 0 || (report["warnings"] as? [String] ?? []).count > 0 || !reachedContent {
                        let image: UIImage? = await withCheckedContinuation { continuation in
                            page.takeSnapshot(with: nil) { image, _ in continuation.resume(returning: image) }
                        }
                        if let data = image?.pngData() {
                            try? data.write(to: folder.appendingPathComponent(file)); report["snapshot"] = file
                        }
                    }
                    results.append(report)
                    if browser.isPanelOpen { browser.closePanel(); try? await Task.sleep(for: .milliseconds(250)) }
                    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                        try? data.write(to: folder.appendingPathComponent("results.json"), options: .atomic)
                    }
                    print("Rise.AdBlockAudit \(index) \(enabled ? "on" : "off") text=\(report["textLength"] ?? 0) ads=\(report["visibleAdSlots"] ?? 0) warnings=\(report["warnings"] ?? [])")
                    page.stopLoading()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            try? "Finished \(results.count) page loads\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            print("Rise.AdBlockAudit FINISHED \(results.count)")
        }
    }

    private static let rejectConsent = #"""
    (() => {
        const allowed = /^(reject (?:all|non-essential|optional)(?: cookies)?|decline (?:all|optional)(?: cookies)?|continue without (?:accepting|agreeing)|do not accept|deny all)$/i;
        for(const e of document.querySelectorAll('button,[role="button"],input[type="button"]')) {
            const text=(e.innerText||e.value||'').trim().replace(/\s+/g,' ');
            if(allowed.test(text) && e.getClientRects().length) { e.click(); return true; }
        }
        return false;
    })()
    """#

    private static let inspect = #"""
    (() => {
        const visible = e => {
            if (!e || !e.getClientRects().length) return false;
            for (let p = e; p; p = p.parentElement) {
                const s = getComputedStyle(p); if (s.display === 'none' || s.visibility === 'hidden' || +s.opacity === 0) return false;
            }
            const r=e.getBoundingClientRect(); return r.width>10 && r.height>10;
        };
        const nodes=[...document.querySelectorAll('.adsbygoogle,[data-ad-slot],[id^="google_ads_iframe"],[id^="div-gpt-ad"],.ad-banner,.ad-container,.ad-wrapper,.advertisement,[id^="ad-slot"],[data-testid="ad-slot"]')];
        const slots=nodes.map(e=>({tag:e.tagName,id:e.id,class:e.className,visible:visible(e),text:(e.innerText||'').slice(0,100),iframe:e.querySelectorAll('iframe').length,image:e.querySelectorAll('img').length}));
        const warningPattern=/(?:disable|turn\s?off|pause|deactivate|whitelist|allowlist).{0,80}ad\s?[- ]?block|ad\s?[- ]?block(?:er|ing)?.{0,50}(?:detected|disable|prevent|access|whitelist)|please.{0,40}(?:allow|enable).{0,20}ads/i;
        const warnings=[];
        for(const e of document.querySelectorAll('[role="dialog"],dialog,[class*="modal"],[id*="adblock"],[class*="adblock"],h1,h2,p')) {
            const text=(e.innerText||'').trim();
            if(text.length>10 && text.length<1000 && visible(e) && warningPattern.test(text)) warnings.push(text.slice(0,300));
        }
        const adHost=/(?:googlesyndication|doubleclick|googleadservices|amazon-adsystem|criteo|taboola|outbrain|adsrvr|adnxs|rubiconproject|pubmatic)\./i;
        const resources=performance.getEntriesByType('resource');
        return {title:document.title,textLength:(document.body?.innerText||'').length,headings:[...document.querySelectorAll('h1')].map(e=>e.innerText).slice(0,4),
            links:document.links.length,visibleAdSlots:slots.filter(x=>x.visible).length,hiddenAdSlots:slots.filter(x=>!x.visible).length,
            slots:slots.slice(0,40),warnings:[...new Set(warnings)],resources:resources.length,
            adResources:resources.filter(r=>adHost.test(r.name)).map(r=>({url:r.name.slice(0,220),duration:r.duration,size:r.transferSize})).slice(0,50),
            frames:[...document.querySelectorAll('iframe')].filter(visible).map(e=>({src:e.src.slice(0,180),id:e.id})).slice(0,20),
            sample:(document.body?.innerText||'').slice(0,1000)};
    })()
    """#
}
#endif
