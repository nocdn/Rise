// Uses the same real HTTP fixtures as the iOS consent audit, through Rise's actual bridge.
// python3 scripts/test-desktop-cookie-consent.py [--real-sites]
import AppKit
import CryptoKit
import Darwin
import RiseCore
import RiseChromium
@testable import Rise

@main @MainActor struct ChromiumCookieConsentMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        for index in 0..<_dyld_image_count() {
            if let name = _dyld_get_image_name(index), let header = _dyld_get_image_header(index) {
                let path = String(cString: name)
                if index == 0 || path.contains("Chromium Framework.framework/Versions/A/Chromium Framework") {
                    print("IMAGE", String(UInt(bitPattern: header), radix: 16), path)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now()+900) { print("FAIL consent audit timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let audit = ChromiumCookieConsentRun(folder: folder)
        app.delegate = audit; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(audit) {}
    }
}

@MainActor final class ChromiumCookieConsentRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var tab: BrowserTab!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ passed: Bool, _ text: String) { print(passed ? "PASS" : "FAIL", text); if !passed { failures += 1 } }
    func write(_ object: Any, _ file: String) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]).write(to: folder.appendingPathComponent(file), options: .atomic)
    }
    func value(_ script: String, in page: WebPage? = nil, world: ScriptWorld = .page) async -> Any? {
        guard let page = page ?? tab?.page else { return nil }
        return await withCheckedContinuation { continuation in
            let completion: (Result<Any?, Error>) -> Void = { continuation.resume(returning: try? $0.get()) }
            if let page = page as? ChromiumPage {
                page.evaluate(script, arguments: [:], in: nil, world: world, userGesture: false, completion: completion)
            } else { page.evaluate(script, arguments: [:], in: nil, world: world, completion: completion) }
        }
    }
    func clearCookies() async {
        guard let page = tab.page as? ChromiumPage else { return }
        _ = await withCheckedContinuation { continuation in
            page.browserView.devTools("Network.clearBrowserCookies", params: [:]) { continuation.resume(returning: $0) }
        }
    }
    func load(_ url: URL, timeout: TimeInterval = 20) async -> Bool {
        tab.load(url)
        let deadline = Date().addingTimeInterval(timeout)
        try? await Task.sleep(for: .milliseconds(80))
        while Date() < deadline {
            if !tab.page.isLoading, await value("return document.readyState") as? String == "complete" { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, String(describing: error)) }
            try? write(["failures": failures], "done.json")
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let preferences = UserDefaults(suiteName: "Rise.CookieAudit.\(UUID())")!
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName(""); browser.window?.setContentSize(NSSize(width: 1100, height: 780)); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        tab = browser.addTab()
        let base = URL(string: ProcessInfo.processInfo.environment["RISE_COOKIE_BASE"]!)!
        var manifest = base.appendingPathComponent("manifest")
        if let names = ProcessInfo.processInfo.environment["RISE_COOKIE_CASES"], !names.isEmpty {
            manifest = URL(string: manifest.absoluteString+"?cases="+names)!
        }
        let (data, _) = try await URLSession.shared.data(from: manifest)
        let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        var reports: [[String: Any]] = []
        for item in cases {
            await clearCookies()
            let name = item["name"] as! String, negative = item["negative"] as? Bool == true
            let url = URL(string: item["url"] as! String, relativeTo: base)!.absoluteURL
            _ = await load(url)
            let start = Date(), limit = negative ? 4.5 : item["timeout"] as? Double ?? 6
            let wanted = negative ? 0 : item["repeat"] as? Bool == true ? 2 : 1
            var report: [String: Any] = [:]
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                report = await value("return window.fixtureReport?.()") as? [String: Any] ?? [:]
                if !negative, report["accepted"] as? Int == wanted, report["bannerConnected"] as? Bool == false { break }
            } while Date().timeIntervalSince(start) < limit
            var passed = report["accepted"] as? Int == wanted && report["wrong"] as? Int == 0 &&
                (negative || (report["cookie"] as? Bool == true && report["bannerConnected"] as? Bool == false && report["locked"] as? Bool == false))
            if !negative && passed {
                let usable = await value("document.getElementById('normal').click(); scrollTo(0,200); return window.normalClicked === true && scrollY > 0") as? Bool == true
                report["controlsUsable"] = usable; passed = passed && usable
            }
            report["case"] = name; report["passed"] = passed; report["elapsed"] = Date().timeIntervalSince(start)
            report["frames"] = await browser.cookieConsent.inspect(tab.page)
            reports.append(report); try write(reports, "fixtures.json")
            check(passed, "\(name) accepted=\(report["accepted"] ?? -1) wrong=\(report["wrong"] ?? -1)")
        }
        check(browser.cookieConsent.failure == nil, "The bundled rules load and verify")
        try await nativeChecks(base)
        if ProcessInfo.processInfo.environment["RISE_COOKIE_PUBLIC"] == "1" { try await publicSites() }
    }

    func nativeChecks(_ base: URL) async throws {
        await clearCookies()
        let simple = base.appendingPathComponent("case/simple")
        browser.cookieConsent.setEnabled(false, for: simple)
        _ = await load(simple); try await Task.sleep(for: .milliseconds(1300))
        var report = await value("return window.fixtureReport()") as? [String: Any] ?? [:]
        check(report["accepted"] as? Int == 0 && report["bannerConnected"] as? Bool == true, "Disabled policy leaves the banner intact")
        browser.toggleCookieConsent()
        try await Task.sleep(for: .milliseconds(1700))
        report = await value("return window.fixtureReport()") as? [String: Any] ?? [:]
        check(report["accepted"] as? Int == 1 && report["cookie"] as? Bool == true, "The popover toggle reloads and accepts when enabled")
        check(await value("return !window.__riseCookieConsent && !window.riseHandlers?.riseCookieConsent") as? Bool == true,
              "The page cannot access the isolated automation or bridge")
        try await consentWithoutUserActivation(simple)
        check(await value("const b=document.createElement('button');let n=0;b.onclick=()=>n++;b.click();return n===1") as? Bool == true,
              "Page-owned click() keeps its ordinary behavior")
        let originalToken = await browser.cookieConsent.inspect(tab.page).first?["token"] as? String
        _ = await value("window.__riseCookieConsent.stop(); dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true})); return true",
                        world: .named(CookieConsentRules.worldName))
        try await Task.sleep(for: .milliseconds(250))
        let resumed = await browser.cookieConsent.inspect(tab.page)
        check(originalToken != nil && resumed.first?["token"] as? String != originalToken && resumed.first?["active"] as? Bool == true,
              "A persisted-page resume rebinds the isolated Chromium transport")

        await clearCookies()
        _ = await load(base.appendingPathComponent("case/late-banner"))
        let background = tab!
        tab = browser.addTab(url: base.appendingPathComponent("case/late-banner"))
        try await Task.sleep(for: .milliseconds(150))
        browser.cookieConsent.setEnabled(false, for: simple)
        try await Task.sleep(for: .milliseconds(2400))
        let first = await value("return window.fixtureReport()", in: background.page) as? [String: Any] ?? [:]
        let second = await value("return window.fixtureReport()") as? [String: Any] ?? [:]
        check(first["accepted"] as? Int == 0 && second["accepted"] as? Int == 0,
              "Disabling stops delayed acceptance in every tab on that host")
        browser.cookieConsent.setEnabled(true, for: simple)
        browser.select(background.id); tab = background
        let resumeDeadline = Date().addingTimeInterval(3)
        var resumedBackground: [String: Any] = [:]
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            resumedBackground = await value("return window.fixtureReport()", in: background.page) as? [String: Any] ?? [:]
        } while resumedBackground["accepted"] as? Int != 1 && Date() < resumeDeadline
        check(resumedBackground["accepted"] as? Int == 1,
              "Re-enabling wakes a retained live page when shown without requiring a reload")
        if resumedBackground["accepted"] as? Int != 1 {
            try write(["report": resumedBackground, "frames": await browser.cookieConsent.inspect(background.page),
                       "runtime": await value("return window.__riseCookieConsent?.inspect()", in: background.page,
                                              world: .named(CookieConsentRules.worldName)) ?? NSNull()], "resume-failure.json")
        }
        await clearCookies()
        browser.showPeek(url: base.appendingPathComponent("case/cookiebot-closed-shadow"), animated: false)
        try await Task.sleep(for: .milliseconds(2200))
        let peek = browser.peekTab!
        let peekReport = await value("return window.fixtureReport?.()", in: peek.page) as? [String: Any] ?? [:]
        check(peekReport["accepted"] as? Int == 1 && peekReport["bannerConnected"] as? Bool == false,
              "Peek uses the shared closed-shadow provider API")
        browser.closePeek()
        await clearCookies()
        browser.renderPeekStandby(base.appendingPathComponent("case/cookiebot-closed-shadow"))
        try await Task.sleep(for: .milliseconds(2200))
        let preview = browser.peekStandby!.tab
        let previewReport = await value("return window.fixtureReport?.()", in: preview.page) as? [String: Any] ?? [:]
        check(previewReport["accepted"] as? Int == 1 && previewReport["bannerConnected"] as? Bool == false,
              "Background Peek previews also dismiss consent")
        browser.discardPeekStandby()
        for theme in [RiseTheme.neutral, .dark] {
            browser.theme = theme
            let controller = SiteControlsController(browser: browser)
            let view = controller.view
            view.appearance = theme.appearance; view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("popover-\(theme.rawValue).png"))
            }
        }
        _ = await load(URL(string: "rise://settings/privacy")!)
        let settings = await value("return await riseSettings.rows('privacy')") as? [[String: Any]] ?? []
        check(settings.contains { $0["key"] as? String == "notificationPermission" }, "The notifications control is available in real rise://settings")
        _ = await value("await riseSettings.set('notificationPermission','block');return true")
        check(browser.sitePermissions.defaultNotifications == .block, "The settings page changes the actual notification policy")
        try await navigationRace(base)
    }

    /// Isolate consent from other browser page tools, which intentionally retain their
    /// existing gesture behavior. No browser-controller scripts run in this page.
    func consentWithoutUserActivation(_ url: URL) async throws {
        await clearCookies()
        let page = ChromiumPage()
        page.view.frame = browser.pageClip.bounds; browser.pageClip.addSubview(page.view)
        defer { page.view.removeFromSuperview(); page.stopLoading() }
        browser.cookieConsent.install(on: page); page.load(url)
        let deadline = Date().addingTimeInterval(5)
        var report: [String: Any] = [:]
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            report = await value("return window.fixtureReport?.()", in: page) as? [String: Any] ?? [:]
        } while report["accepted"] as? Int != 1 && Date() < deadline
        _ = await browser.cookieConsent.inspect(page)
        let inactive = await value("return !navigator.userActivation.isActive", in: page) as? Bool == true
        check(report["accepted"] as? Int == 1 && inactive,
              "Consent automation and inspection do not synthesize a trusted user gesture")
    }

    /// Deliberately navigate between the isolated token check and the page-world call.
    /// The verified test snippet would click a terms button if the document guard failed.
    func navigationRace(_ base: URL) async throws {
        browser.cookieConsent.setEnabled(false, for: base)
        await clearCookies(); _ = await load(base.appendingPathComponent("case/simple"))
        let directory = folder.appendingPathComponent("race-rules")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let assets = ["cookie-consent.js": "/* audit fixture */", "cookie-consent-evals.json":
                        #"{"RACE":"(()=>{document.querySelector('.panel button').click();return true})()"}"#]
        var manifest: [[String: String]] = []
        for (file, text) in assets {
            let data = Data(text.utf8)
            try data.write(to: directory.appendingPathComponent(file))
            manifest.append(["file": file, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
        }
        try JSONSerialization.data(withJSONObject: ["assets": manifest]).write(to: directory.appendingPathComponent("cookie-consent-manifest.json"))
        let rules = try CookieConsentRules.load(from: directory)
        var result: Bool?
        let session = CookieConsentSession<Int>(rules: { rules }, allowed: { true }) { [self] body, arguments, _, world in
            if world == .automation && body.contains("canAct()") {
                let time = await value("return performance.timeOrigin") as? Double ?? 0
                _ = await load(base.appendingPathComponent("case/legal-terms"))
                return ["token": "race-document", "documentTime": time]
            }
            guard let page = tab.page as? ChromiumPage else { return nil }
            let value: Any? = await withCheckedContinuation { continuation in
                page.evaluate(body, arguments: arguments, in: nil, world: .page, userGesture: false) { continuation.resume(returning: try? $0.get()) }
            }
            if world == .page { result = value as? Bool }
            return value
        }
        session.enabled = true
        session.receive(["type": "eval", "token": "race-document", "id": "race", "snippetId": "RACE"], in: 0, isMain: true)
        let deadline = Date().addingTimeInterval(8)
        while result == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let report = await value("return window.fixtureReport()") as? [String: Any] ?? [:]
        check(result == false && report["wrong"] as? Int == 0, "A queued API cannot act on another document after navigation")
        browser.cookieConsent.setEnabled(true, for: base)
    }

    func publicSites() async throws {
        var reports: [[String: Any]] = []
        let selected = ProcessInfo.processInfo.environment["RISE_COOKIE_URLS"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let sites = selected.isEmpty ? ["https://www.theguardian.com/international", "https://www.cookiebot.com/", "https://www.ikea.com/gb/en/",
                        "https://www.decathlon.co.uk/", "https://www.microsoft.com/en-gb/", "https://www.wired.com/",
                        "https://www.bbc.com/", "https://www.spiegel.de/", "https://www.wikipedia.org/", "https://news.ycombinator.com/"] : selected
        for address in sites {
            print("OPEN \(address)")
            let original = URL(string: address)!
            browser.cookieConsent.setEnabled(false, for: original)
            await clearCookies(); _ = await load(original)
            let final = tab.url ?? original
            browser.cookieConsent.setEnabled(false, for: final)
            await clearCookies(); let baselineLoaded = await load(final)
            try await Task.sleep(for: .seconds(3))
            let before = await value(Self.publicReport) as? [String: Any] ?? [:]
            browser.cookieConsent.setEnabled(true, for: original); browser.cookieConsent.setEnabled(true, for: final)
            await clearCookies(); let afterLoaded = await load(final)
            try await Task.sleep(for: .seconds(9))
            let after = await value(Self.publicReport) as? [String: Any] ?? [:]
            let report: [String: Any] = ["url": address, "finalURL": tab.url?.absoluteString ?? "", "beforeLoaded": baselineLoaded,
                                       "afterLoaded": afterLoaded, "before": before, "after": after,
                                       "frames": await browser.cookieConsent.inspect(tab.page)]
            reports.append(report); try write(reports, "sites.json")
            print("SITE \(address) before=\(before["visibleDialogs"] ?? -1) after=\(after["visibleDialogs"] ?? -1)")
        }
    }
    static let publicReport = #"""
    const visible=e=>{if(!e.getClientRects().length)return false;for(let p=e;p;p=p.parentElement){const s=getComputedStyle(p);if(p.hidden||p.inert||p.getAttribute('aria-hidden')==='true'||s.display==='none'||s.visibility==='hidden'||+s.opacity===0)return false;}return true;};
    const dialogs=[...document.querySelectorAll('dialog,[role=dialog],[role=alertdialog],#onetrust-banner-sdk,#didomi-host,#CybotCookiebotDialog,[class*=cookie-banner],[id*=cookie-banner],[id*=consent]')].filter(e=>visible(e)&&!e.matches('a,button,input,label'));
    const providers={};
    try{if(window.Cookiebot)providers.cookiebot={responded:Cookiebot.hasResponse,consent:Cookiebot.consent};}catch{}
    try{if(window.OneTrust)providers.onetrust={closed:OneTrust.IsAlertBoxClosed(),groups:window.OnetrustActiveGroups};}catch{}
    try{if(window.Didomi)providers.didomi=Didomi.getCurrentUserStatus?.();}catch{}
    return {title:document.title,textLength:document.body?.innerText.length,visibleDialogs:dialogs.length,
      dialogs:dialogs.map(e=>({id:e.id,text:e.innerText.slice(0,600)})).slice(0,8),bodyOverflow:getComputedStyle(document.body).overflow,
      providers,cookies:document.cookie.split(';').map(c=>c.trim().split('=')[0]),sample:document.body?.innerText.slice(0,500)};
    """#
}
