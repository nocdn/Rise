#if DEBUG
import UIKit
import WebKit

/// Opt-in, ephemeral running-app audit. Uses Rise's real navigation policy, isolated
/// script, bridge and settings reload, without driving or touching the user's tabs.
@MainActor enum CookieConsentAudit {
    static let argument = "-RiseCookieConsentAudit"
    static func makeBlocker() -> MobileAdBlocker {
        let name = "Rise.CookieConsent.Audit"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return MobileAdBlocker(preferences: defaults)
    }
    static func runIfRequested(in browser: BrowserViewController) {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: argument), args.indices.contains(index+2) else { return }
        let folder = URL.cachesDirectory.appendingPathComponent(args[index+1].replacingOccurrences(of: "caches:", with: ""))
        let target = args[index+2]
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if target.hasPrefix("http://127.0.0.1") { try await fixtures(in: browser, base: URL(string: target)!, folder: folder) }
                else { try await realSites(in: browser, selection: target, folder: folder) }
                try "Finished\n".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch {
                try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8)
                print("Rise.CookieAudit FAILED \(error)")
            }
        }
    }
    private static func page(in browser: BrowserViewController) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(InputZoomPolicy.userScript)
        let page = WKWebView(frame: .zero, configuration: configuration)
        PagePaintWatcher.shared.install(on: page)
        browser.adopt(page)
        return page
    }
    private static func write(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: url, options: .atomic)
    }
    private static func snapshot(_ page: WKWebView, to url: URL) async {
        let image: UIImage? = await withCheckedContinuation { c in page.takeSnapshot(with: nil) { image, _ in c.resume(returning: image) } }
        try? image?.pngData()?.write(to: url)
    }
    @discardableResult private static func load(_ page: WKWebView, url: URL, timeout: Double = 20) async -> Bool {
        let marker = UUID().uuidString
        let world = WKContentWorld.world(name:"Rise.CookieAudit.Navigation")
        _ = try? await page.callAsyncJavaScript("return window.__riseAuditDocumentMarker=token;", arguments:["token":marker], in:nil,contentWorld:world)
        page.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
        let start = CACurrentMediaTime()
        while CACurrentMediaTime()-start < timeout {
            try? await Task.sleep(for: .milliseconds(50))
            let fresh = (try? await page.callAsyncJavaScript("return window.__riseAuditDocumentMarker!==token && document.readyState==='complete';",arguments:["token":marker],in:nil,contentWorld:world)) as? Bool == true
            if !page.isLoading && fresh { return true }
        }
        return false
    }
    private static func fixtures(in browser: BrowserViewController, base: URL, folder: URL) async throws {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("manifest"))
        let cases = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let page = page(in: browser)
        browser.adBlocker.setEnabled(false, for: base)
        let cookie = browser.adBlocker.cookieBanners
        var results: [[String: Any]] = []
        try write(results,to:folder.appendingPathComponent("fixtures.json"))
        for item in cases {
            await page.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            let name = item["name"] as! String
            let url = URL(string:item["url"] as! String,relativeTo:base)!.absoluteURL
            let negative = item["negative"] as? Bool == true
            await load(page, url: url)
            let start = CACurrentMediaTime(), timeout = item["timeout"] as? Double ?? 6
            var report: [String: Any] = [:]
            while CACurrentMediaTime()-start < (negative ? 4.5 : timeout) {
                try? await Task.sleep(for: .milliseconds(100))
                report = (try? await page.evaluateJavaScript("window.fixtureReport?.()")) as? [String: Any] ?? [:]
                let wanted = item["repeat"] as? Bool == true ? 2 : 1
                if !negative, report["accepted"] as? Int == wanted, report["bannerConnected"] as? Bool == false { break }
            }
            let wanted = negative ? 0 : item["repeat"] as? Bool == true ? 2 : 1
            var passed = report["accepted"] as? Int == wanted && report["wrong"] as? Int == 0 &&
                (negative || (report["cookie"] as? Bool == true && report["bannerConnected"] as? Bool == false && report["locked"] as? Bool == false))
            report["case"] = name; report["passed"] = passed; report["elapsed"] = CACurrentMediaTime()-start
            report["frames"] = await cookie.inspect(page)
            if !negative && passed {
                _ = try? await page.evaluateJavaScript("document.getElementById('normal').click(); window.scrollTo(0,200)")
                report["controlsUsable"] = (try? await page.evaluateJavaScript("window.normalClicked===true && window.scrollY>0")) as? Bool ?? false
                passed = report["controlsUsable"] as? Bool == true
            }
            report["passed"] = passed
            if !passed { await snapshot(page, to: folder.appendingPathComponent(name+".png")) }
            results.append(report); try write(results, to: folder.appendingPathComponent("fixtures.json"))
            print("Rise.CookieAudit \(name) \(passed ? "PASS" : "FAIL") accepted=\(report["accepted"] ?? -1) wrong=\(report["wrong"] ?? -1)")
        }
        // Per-site toggle: disable really leaves the banner present; re-enable reloads,
        // saves consent, and removes the native spinner without closing Site settings.
        let url = base.appendingPathComponent("case/simple")
        await page.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        cookie.setEnabled(false, for: url); await load(page, url: url)
        try? await Task.sleep(for: .seconds(2))
        var settings: [String: Any] = [:]
        settings["disabledLeavesBanner"] = (try? await page.evaluateJavaScript("window.accepted===0 && window.banner?.isConnected")) as? Bool ?? false
        browser.openPanel(.menu); browser.openSiteSettings()
        try? await Task.sleep(for: .milliseconds(650))
        let panel = browser.bottomBar.siteSettings
        panel.switches[2].setOn(true, animated: false); panel.switches[2].sendActions(for: .valueChanged)
        settings["spinnerStarts"] = panel.isUpdatingCookieBanners && !panel.switches[2].isEnabled
        for _ in 0..<200 {
            try? await Task.sleep(for: .milliseconds(50))
            let accepted = (try? await page.evaluateJavaScript("window.accepted===1")) as? Bool == true
            if !panel.isUpdatingCookieBanners && accepted { break }
        }
        settings["enabledAccepts"] = (try? await page.evaluateJavaScript("window.accepted===1 && !window.banner?.isConnected")) as? Bool ?? false
        settings["spinnerStops"] = !panel.isUpdatingCookieBanners && panel.switches[2].isEnabled
        settings["panelStaysOpen"] = browser.isPanelOpen && browser.bottomBar.shown === panel
        settings["adsRemainOff"] = !browser.adBlocker.isInstalled(on: page)
        await load(page, url: url)
        try? await Task.sleep(for: .seconds(1))
        settings["consentPersistsOnReload"] = (try? await page.evaluateJavaScript("window.accepted===0 && window.fixtureReport().cookie && !window.banner")) as? Bool ?? false
        // An old document's queued work must not click after disabling; page-owned click()
        // remains normal because the guarded prototype is isolated from the website.
        await page.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        await load(page,url:base.appendingPathComponent("case/disabled-then-enabled"))
        let siblingConfiguration = WKWebViewConfiguration()
        siblingConfiguration.websiteDataStore = .nonPersistent()
        let sibling = WKWebView(frame:browser.view.bounds,configuration:siblingConfiguration)
        browser.view.insertSubview(sibling,at:0)
        try await cookie.prepare(sibling,for:base)
        await load(sibling,url:base.appendingPathComponent("case/disabled-then-enabled"))
        cookie.setEnabled(false,for:base);try await cookie.prepare(page,for:base)
        try? await Task.sleep(for:.seconds(3))
        settings["disabledStopsPendingWork"] = (try? await page.evaluateJavaScript("window.accepted===0 && window.banner.isConnected")) as? Bool ?? false
        settings["disabledStopsOtherTabs"] = (try? await sibling.evaluateJavaScript("window.accepted===0 && window.banner.isConnected")) as? Bool ?? false
        sibling.removeFromSuperview();sibling.stopLoading()
        _ = try? await page.evaluateJavaScript("document.getElementById('normal').click()")
        settings["pageClickPrototypeUnaffected"] = (try? await page.evaluateJavaScript("window.normalClicked===true")) as? Bool ?? false
        cookie.setEnabled(true,for:base)
        await load(page,url:url)
        browser.changeCookieBanners(false)
        for _ in 0..<200 where browser.adBlockingNavigation == nil { try? await Task.sleep(for:.milliseconds(1)) }
        page.load(URLRequest(url:base.appendingPathComponent("case/no-cookie-purpose")))
        for _ in 0..<200 { if !panel.isUpdatingCookieBanners { break };try? await Task.sleep(for:.milliseconds(25)) }
        settings["interruptedCookieReloadSettles"] = !panel.isUpdatingCookieBanners && panel.switches[2].isEnabled
        await load(page,url:url)
        browser.changeCookieBanners(true)
        for _ in 0..<200 where browser.adBlockingNavigation == nil { try? await Task.sleep(for:.milliseconds(1)) }
        page.load(URLRequest(url:URL(string:"http://127.0.0.1:1/unavailable")!))
        for _ in 0..<200 { if !panel.isUpdatingCookieBanners { break };try? await Task.sleep(for:.milliseconds(25)) }
        settings["failedCookieReloadSettles"] = !panel.isUpdatingCookieBanners && panel.switches[2].isEnabled
        // Fast cross-host history must not leave a restored isolated engine stopped.
        cookie.setEnabled(true,for:base)
        let second = URL(string:base.absoluteString.replacingOccurrences(of:"127.0.0.1",with:"localhost"))!
        browser.adBlocker.setEnabled(false,for:second)
        await load(page,url:base.appendingPathComponent("case/very-late-banner"))
        await load(page,url:second.appendingPathComponent("case/no-cookie-purpose"))
        page.goBack()
        for _ in 0..<300 {
            try? await Task.sleep(for:.milliseconds(50))
            if (try? await page.evaluateJavaScript("window.accepted===1")) as? Bool == true { break }
        }
        settings["historyRestoresAutomation"] = (try? await page.evaluateJavaScript("window.accepted===1 && !window.banner?.isConnected")) as? Bool ?? false
        await load(page,url:url)
        // Preview-only pages use the same engine and wait for closed-shadow API acceptance.
        let previewFolder = folder.appendingPathComponent("preview-cache")
        let defaultCookies = WKWebsiteDataStore.default().httpCookieStore
        for existing in await defaultCookies.allCookies() where existing.domain == "127.0.0.1" && existing.name == "consent_cookiebot_closed_shadow" {
            await withCheckedContinuation { c in defaultCookies.delete(existing) { c.resume() } }
        }
        let previews = BackgroundTabPreviews(cacheURL:previewFolder,adBlocker:browser.adBlocker)
        previews.host.frame = browser.view.bounds;browser.view.insertSubview(previews.host,at:0)
        previews.canRender = { true }
        let selected = BrowserTab(webView:WKWebView())
        let target = BrowserTab(webView:WKWebView(),restoring:MobileBrowserSession.Tab(url:base.appendingPathComponent("case/cookiebot-closed-shadow")))
        previews.update(tabs:[selected,target],selected:selected,viewport:browser.view.bounds.size,stripHeight:0)
        for _ in 0..<200 { if target.snapshot != nil { break };try? await Task.sleep(for:.milliseconds(50)) }
        var greenArticle = false
        if let image = target.snapshot, let cg = image.cgImage,
           let crop = cg.cropping(to:CGRect(x:Double(cg.width)*0.2,y:Double(cg.height)*0.75,width:Double(cg.width)*0.6,height:Double(cg.height)*0.1)),
           let color = PageEdgeColor.dominantColor(of:crop) {
            var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0;color.getRed(&r,green:&g,blue:&b,alpha:&a)
            greenArticle = g > r+0.02
            try? image.pngData()?.write(to:folder.appendingPathComponent("cookie-free-preview.png"))
        }
        settings["backgroundPreviewDismissesClosedShadowBanner"] = greenArticle
        settings["previewPreservesLazyTab"] = target.webView.url == nil
        previews.setActive(false);previews.cache.flush();previews.host.removeFromSuperview()
        let other = MobileCookieBannerBlocker(preferences: UserDefaults(suiteName:"Rise.CookieConsent.Audit.Other")!)
        cookie.setEnabled(false, for: url); try await cookie.prepare(page, for: url)
        try await other.prepare(page, for: url)
        settings["adoptedPageCanReenable"] = page.configuration.userContentController.userScripts.contains { $0.source.hasPrefix(MobileCookieBannerBlocker.scriptMarker) }
        let youtube = URL(string:"https://www.youtube.com/")!
        try await browser.adBlocker.prepare(page, for: youtube)
        settings["youtubeAdsStayOffCookiesIndependent"] = !browser.adBlocker.isInstalled(on: page) && cookie.isEnabled(for: youtube) && page.configuration.userContentController.userScripts.contains { $0.source.hasPrefix(MobileCookieBannerBlocker.scriptMarker) }
        settings["wwwPreferenceSharesHost"] = { cookie.setEnabled(false,for:URL(string:"https://www.example.com/")!); return !cookie.isEnabled(for:URL(string:"https://example.com/")!) }()
        settings["isolatedBridgeNotExposed"] = (try? await page.evaluateJavaScript("typeof window.__riseCookieConsent==='undefined' && !window.webkit?.messageHandlers?.riseCookieConsent")) as? Bool ?? false
        try write(settings,to:folder.appendingPathComponent("settings.json"))
        browser.closePanel()
        browser.adBlocker.setEnabled(true, for: base)
        let adChecks = try await AdBlockingChecks.run(in: browser)
        try write(adChecks, to: folder.appendingPathComponent("ad-regressions.json"))
    }
    static let sites = [
        "https://www.theguardian.com/international", "https://www.bbc.com/", "https://www.cnn.com/",
        "https://www.theverge.com/", "https://www.tomshardware.com/", "https://www.reuters.com/",
        "https://www.imdb.com/", "https://www.timeanddate.com/", "https://www.accuweather.com/",
        "https://www.ikea.com/gb/en/", "https://www.bosch.com/", "https://www.lufthansa.com/gb/en/homepage",
        "https://www.decathlon.co.uk/", "https://www.nytimes.com/", "https://www.stackoverflow.com/",
        "https://www.mozilla.org/", "https://www.cookiebot.com/", "https://www.onetrust.com/",
        "https://www.didomi.io/", "https://www.consentmanager.net/", "https://www.dailymotion.com/",
        "https://www.youtube.com/", "https://www.wikipedia.org/", "https://news.ycombinator.com/",
        "https://www.bahn.de/", "https://www.spiegel.de/", "https://www.lemonde.fr/",
        "https://www.eldiario.es/", "https://www.wired.com/", "https://www.pcgamer.com/"
    ]
    private static func realSites(in browser: BrowserViewController, selection: String, folder: URL) async throws {
        let page = page(in: browser), cookie = browser.adBlocker.cookieBanners
        let ads = selection.hasPrefix("ads:")
        let selection = ads ? String(selection.dropFirst(4)) : selection
        let selected = selection == "all" ? Array(sites.indices) : selection.split(separator:",").compactMap { Int($0) }
        var results: [[String: Any]] = []
        for index in selected where sites.indices.contains(index) {
            let url = URL(string:sites[index])!
            var policyURLs = [url]
            for enabled in [false,true] {
                page.stopLoading()
                await page.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                for policyURL in policyURLs { cookie.setEnabled(enabled,for:policyURL);browser.adBlocker.setEnabled(ads,for:policyURL) }
                let start=CACurrentMediaTime()
                var navigated = await load(page,url:url,timeout:22)
                // A site's regional redirect is a separate host preference. Ensure the
                // baseline is really off there, then clear any premature consent cookies.
                for _ in 0..<3 {
                    guard let final = page.url, cookie.isEnabled(for: final) != enabled || browser.adBlocker.isEnabled(for: final) != (ads && !MobileAdBlocker.isYouTube(final)) else { break }
                    policyURLs.append(final);cookie.setEnabled(enabled,for:final);browser.adBlocker.setEnabled(ads,for:final)
                    await page.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
                    navigated = await load(page,url:final,timeout:22)
                }
                try? await Task.sleep(for:.seconds(enabled ? 8 : 4))
                // Some regional redirects happen after onload. Recheck after the settling
                // delay so a late redirect cannot silently enable a baseline's consent.
                for _ in 0..<3 {
                    guard let final=page.url, cookie.isEnabled(for:final) != enabled || browser.adBlocker.isEnabled(for:final) != (ads && !MobileAdBlocker.isYouTube(final)) else { break }
                    policyURLs.append(final);cookie.setEnabled(enabled,for:final);browser.adBlocker.setEnabled(ads,for:final)
                    page.stopLoading()
                    await page.configuration.websiteDataStore.removeData(ofTypes:WKWebsiteDataStore.allWebsiteDataTypes(),modifiedSince:.distantPast)
                    navigated=await load(page,url:final,timeout:22)
                    try? await Task.sleep(for:.seconds(enabled ? 8 : 4))
                }
                var report=(try? await page.evaluateJavaScript(inspect)) as? [String:Any] ?? [:]
                report["frames"] = await cookie.inspect(page)
                report["site"] = sites[index];report["enabled"] = enabled;report["index"] = index
                report["finalURL"] = page.url?.absoluteString ?? "";report["elapsed"] = CACurrentMediaTime()-start
                report["navigationSucceeded"] = navigated
                report["policyEnabled"] = cookie.isEnabled(for:page.url)
                report["adBlockingEnabled"] = browser.adBlocker.isEnabled(for:page.url)
                report["scriptInstalled"] = page.configuration.userContentController.userScripts.contains { $0.source.hasPrefix(MobileCookieBannerBlocker.scriptMarker) }
                report["acceptanceState"] = (try? await page.evaluateJavaScript(acceptanceState)) as? [String:Any] ?? [:]
                report["tcfState"] = (try? await page.callAsyncJavaScript(tcfState,arguments:[:],in:nil,contentWorld:.page)) as? [String:Any] ?? [:]
                let cookies=await page.configuration.websiteDataStore.httpCookieStore.allCookies()
                report["cookieNames"] = cookies.map(\.name).sorted()
                await snapshot(page,to:folder.appendingPathComponent("site-\(index)-\(enabled ? "on" : "off").png"))
                results.append(report);try write(results,to:folder.appendingPathComponent("sites.json"))
                print("Rise.CookieAudit site \(index) \(enabled) text=\(report["textLength"] ?? 0)")
            }
        }
    }
    private static let inspect = #"""
    (()=>{
      const visible=e=>{
        if(!e.getClientRects().length)return false;
        for(let p=e;p;p=p.parentElement){const s=getComputedStyle(p);if(p.hidden||p.inert||p.getAttribute('aria-hidden')==='true'||s.display==='none'||s.visibility==='hidden'||+s.opacity===0)return false;}
        return true;
      };
      const dialogs=[...document.querySelectorAll('dialog,[role=dialog],[role=alertdialog],#onetrust-banner-sdk,#didomi-host,#CybotCookiebotDialog,[class*=cookie-banner],[id*=cookie-banner],[id*=consent]')].filter(e=>visible(e)&&!e.matches('a,button,input,label'));
      return {title:document.title,textLength:(document.body?.innerText||'').length,headings:[...document.querySelectorAll('h1')].map(e=>e.innerText).slice(0,5),links:document.links.length,
        dialogs:dialogs.map(e=>({id:e.id,text:(e.innerText||'').slice(0,1200),buttons:[...e.querySelectorAll('button,[role=button]')].filter(visible).map(b=>b.innerText).slice(0,20)})).slice(0,12),
        bodyOverflow:getComputedStyle(document.body).overflow,htmlOverflow:getComputedStyle(document.documentElement).overflow,
        bodyClasses:document.body.className,htmlClasses:document.documentElement.className,bodyStyle:document.body.getAttribute('style'),htmlStyle:document.documentElement.getAttribute('style'),
        scrollHeight:document.scrollingElement?.scrollHeight,viewport:innerHeight,bodyPosition:getComputedStyle(document.body).position,
        ready:document.readyState,sample:(document.body?.innerText||'').slice(0,1500)};
    })()
    """#
    private static let acceptanceState = #"""
    (()=>{
      const result={};
      try { if(window.Cookiebot)result.cookiebot={responded:Cookiebot.hasResponse,preferences:Cookiebot.consent?.preferences,statistics:Cookiebot.consent?.statistics,marketing:Cookiebot.consent?.marketing}; }catch{}
      try { if(window.OneTrust)result.onetrust={closed:OneTrust.IsAlertBoxClosed(),groups:window.OnetrustActiveGroups}; }catch{}
      try { if(window.Didomi){const p=Didomi.getCurrentUserStatus?.()?.purposes;result.didomi={total:p?Object.keys(p).length:0,enabled:p?Object.values(p).filter(x=>x.enabled).length:0};} }catch{}
      try { const value=document.cookie.split('; ').find(c=>c.startsWith('OptanonConsent='));if(value){const params=new URLSearchParams(decodeURIComponent(value.slice(value.indexOf('=')+1)));result.optanonGroups=params.get('groups');} }catch{}
      return result;
    })()
    """#
    private static let tcfState = #"""
    if(typeof window.__tcfapi!=='function')return {};
    return await new Promise(resolve=>{
      let done=false;const timer=setTimeout(()=>{done=true;resolve({timeout:true});},1500);
      __tcfapi('addEventListener',2,(data,success)=>{
        if(done||!success||!data)return;
        if(data.cmpStatus!=='loaded')return;
        done=true;clearTimeout(timer);
        const consents=data.purpose?.consents||{};
        resolve({status:data.eventStatus,cmp:data.cmpId,gdpr:data.gdprApplies,purposes:Object.keys(consents).length,accepted:Object.values(consents).filter(Boolean).length});
        if(data.listenerId)__tcfapi('removeEventListener',2,()=>{},data.listenerId);
      });
    });
    """#
}
#endif
