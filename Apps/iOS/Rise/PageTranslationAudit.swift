#if DEBUG
import UIKit
import WebKit

/// Real WebKit documents, frame messaging, DOM restoration and the actual address controls.
/// Only the model is replaced on Simulator, where Apple's translation models aren't available.
@MainActor enum PageTranslationAudit {
    static let argument = "-RisePageTranslationAudit"
    struct Failure: Error { let name: String }
    static func run(in host: BrowserViewController) {
        Task {
            let folder = URL.cachesDirectory.appendingPathComponent("PageTranslationAudit")
            try? FileManager.default.removeItem(at: folder)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await exercise(in: host.view.window!, folder: folder)
                try "Passed".write(to: folder.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
            } catch { try? String(describing: error).write(to: folder.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8) }
        }
    }
    static func exercise(in window: UIWindow, folder: URL) async throws {
        var checks: [String: Bool] = [:]
        func check(_ name: String, _ valid: Bool) throws {
            checks[name] = valid
            try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("checks.json"))
            if !valid { throw Failure(name: name) }
        }
        func wait(_ name: String, _ ready: () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline { if try await ready() { try check(name, true); return }; try await Task.sleep(for: .milliseconds(40)) }
            try check(name, false)
        }
        func capture(_ name: String) throws {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            try image.pngData()?.write(to: folder.appendingPathComponent(name+".png"))
        }
        let french = "La bibliothèque municipale est ouverte tous les jours. Vous pouvez découvrir de nouveaux livres, lire les nouvelles et rencontrer vos amis dans notre café."
        let english = "The public library is open every day. You can discover new books, read the news and meet your friends in our café."
        try check("actual-french-text-overrides-an-incorrect-english-tag", PageTranslationLanguage.identify(sample: french, declared: "en") == "fr")
        try check("english-text-overrides-an-incorrect-foreign-tag", PageTranslationLanguage.identify(sample: english, declared: "fr") == "en")
        try check("short-pages-use-the-language-tag", PageTranslationLanguage.identify(sample: "Bonjour", declared: "fr-FR") == "fr")
        try check("english-variants-are-english", PageTranslationLanguage.isEnglish("en-GB"))
        try check("unknown-and-invalid-language-tags-are-ignored", PageTranslationLanguage.identify(sample: "123", declared: "not a language") == nil)
        let browser = BrowserViewController(startURL: nil, suggestionsDirectory: folder, websiteDataStore: .nonPersistent())
        window.rootViewController = browser; window.makeKeyAndVisible(); browser.view.layoutIfNeeded()
        let page = browser.webView, translation = browser.pageTranslation
        var fail = false, delay = false, calls = 0
        translation.translator = { texts, language in
            calls += 1
            if delay { try await Task.sleep(for: .milliseconds(450)) }
            if fail { throw Failure(name: "model-unavailable") }
            return texts.map { $0 == french ? english : ["Bonjour le monde": "Hello world", "Lire la suite": "Read more", "Compter": "Count", "Une image": "An image"][$0] ?? "English: "+$0 }
        }
        let html = """
        <!doctype html><html lang="fr" dir="rtl"><meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="font:18px system-ui;padding:20px;background:#fff;color:#111" dir="rtl"><h1>Bonjour le monde</h1><p id="article">  \(french)  </p>
        <a id="link" href="/article">Lire la suite</a><button id="counter" onclick="window.count=(window.count||0)+1">Compter</button>
        <img alt="Une image"><input id="input" value="texte personnel"><pre id="code">Bonjour le monde</pre>
        <p id="keep" translate="no">Bonjour le monde</p><div id="editable" contenteditable>Bonjour le monde</div>
        <p lang="en" id="alreadyEnglish">This part is already in English.</p><div id="shadow"></div>
        <iframe id="child" srcdoc="<html lang='fr'><body><p>Bonjour le monde</p></body></html>"></iframe>
        <script>window.marker=Math.random();document.querySelector('#shadow').attachShadow({mode:'open'}).innerHTML='<p>Bonjour le monde</p>'</script>
        </body></html>
        """
        page.loadHTMLString(html, baseURL: URL(string: "https://translation.example/french")!)
        try await wait("foreign-page-offers-translation") { translation.state(for: page).language == "fr" && !page.isLoading }
        try await wait("a-foreign-page-announces-translation-in-the-compact-toolbar") { browser.bottomBar.translationHint != nil }
        let hint = browser.bottomBar.translationHint!, landing = browser.bottomBar.moreLanding
        try check("the-discovery-glyph-starts-close-to-the-menu", abs(hint.destination.x-hint.origin.x-40) < 0.1 && hint.origin.y == hint.destination.y)
        try check("the-discovery-glyph-fades-and-grows-in-before-flying", hint.pose(at: 0).opacity == 0 && hint.pose(at: 0.05).opacity > 0 && hint.pose(at: PageTranslationHint.revealDuration).opacity == 1
                  && hint.pose(at: 0).scale < hint.pose(at: 0.05).scale && hint.pose(at: PageTranslationHint.revealDuration).scale == 1)
        let early = hint.pose(at: PageTranslationHint.revealDuration+0.09).position.x-hint.origin.x,
            late = hint.destination.x-hint.pose(at: PageTranslationHint.revealDuration+0.27).position.x
        try check("the-discovery-flight-starts-slow-and-accelerates", late > early*2)
        try check("the-discovery-glyph-shrinks-towards-the-menu", hint.pose(at: 0.3).scale < 1 && hint.pose(at: PageTranslationHint.arrival).scale < 0.7)
        try check("discovery-never-translates-or-intercepts-taps", !translation.state(for: page).enabled && calls == 0 && !hint.isUserInteractionEnabled && hint.accessibilityElementsHidden)
        let untilCapture = hint.startTime+PageTranslationHint.revealDuration+0.14-CACurrentMediaTime()
        if untilCapture > 0 { try await Task.sleep(for: .seconds(untilCapture)) }
        try capture("translation-available-hint")
        try check("the-hint-uses-render-server-animation-at-120-hz", hint.glyph.layer.animation(forKey: "translation.position")?.preferredFrameRateRange.preferred == 120)
        let untilImpact = hint.startTime+PageTranslationHint.arrival+0.07-CACurrentMediaTime()
        if untilImpact > 0 { try await Task.sleep(for: .seconds(untilImpact)) }
        let impact = landing.layer.presentation()?.transform ?? CATransform3DIdentity
        try check("the-menu-receives-a-small-rightward-impact", impact.m41 > 1 && impact.m41 < 4 && abs(impact.m42) < 0.01)
        try await wait("the-discovery-hint-cleans-up-at-rest") { browser.bottomBar.translationHint == nil && CATransform3DIsIdentity(landing.layer.transform) }
        browser.updateAddress(); translation.didFinish(page)
        try await Task.sleep(for: .milliseconds(150))
        try check("metadata-refreshes-do-not-repeat-the-hint", browser.bottomBar.translationHint == nil && !translation.takeAvailableHint(for: page))
        browser.openPanel(.menu)
        try await Task.sleep(for: .milliseconds(650))
        let address = browser.bottomBar.menu.address
        try check("provided-icon-is-present-and-visible", UIImage(named: "MenuTranslate") != nil && !address.translateButton.isHidden)
        try check("translate-has-a-little-more-space-from-reload", abs(address.reloadButton.center.x-address.translateButton.center.x-AddressBar.translationSpacing) < 0.1 && AddressBar.translationSpacing > AddressBar.pairSpacing)
        try check("translation-starts-off-with-the-normal-icon-colour", !address.translateButton.isSelected && address.translateButton.tintColor == .label)
        try capture("original-menu")
        let marker = try await page.evaluateJavaScript("window.marker") as! Double
        delay = true
        address.translateButton.sendActions(for: .primaryActionTriggered)
        try check("tapping-immediately-swaps-to-a-spinner", address.translateButton.symbolName == "page-translation-loading" && address.translateButton.tintColor == .label)
        try await Task.sleep(for: .milliseconds(330))
        func spinners(in view: UIView) -> [UIActivityIndicatorView] { view.subviews.flatMap { ($0 as? UIActivityIndicatorView).map { [$0] } ?? spinners(in: $0) } }
        try check("the-loading-glyph-is-a-small-running-native-spinner", spinners(in: address.translateButton).contains { $0.isAnimating && $0.transform.a < 0.8 })
        try capture("translating-menu")
        delay = false
        try await wait("the-article-is-translated-in-place") { try await page.evaluateJavaScript("document.querySelector('#article').textContent.trim()") as? String == english }
        try await wait("embedded-frame-is-translated") { try await page.evaluateJavaScript("document.querySelector('#child').contentDocument.body.textContent.trim()") as? String == "Hello world" }
        try check("open-shadow-content-is-translated", try await page.evaluateJavaScript("document.querySelector('#shadow').shadowRoot.textContent") as? String == "Hello world")
        try check("code-opt-outs-and-editable-content-stay-original", try await page.evaluateJavaScript("['code','keep','editable'].every(id=>document.getElementById(id).textContent==='Bonjour le monde')") as? Bool == true)
        try check("existing-english-content-is-left-alone", try await page.evaluateJavaScript("document.querySelector('#alreadyEnglish').textContent") as? String == "This part is already in English.")
        try check("form-values-are-never-rewritten", try await page.evaluateJavaScript("document.querySelector('#input').value") as? String == "texte personnel")
        try check("links-and-event-handlers-survive", try await page.evaluateJavaScript("document.querySelector('#counter').click(); document.querySelector('#link').getAttribute('href')==='/article' && window.count===1") as? Bool == true)
        try check("accessible-image-text-is-translated", try await page.evaluateJavaScript("document.querySelector('img').alt") as? String == "An image")
        try await wait("finishing-swaps-the-spinner-to-the-blue-icon") { !translation.state(for: page).busy && address.translateButton.symbolName == "page-translation" && address.translateButton.tintColor == .systemBlue }
        try await Task.sleep(for: .milliseconds(320))
        try capture("translated-menu")
        _ = try await page.evaluateJavaScript("const p=document.createElement('p');p.id='late';p.textContent='Bonjour le monde';document.body.append(p)")
        try await wait("late-arriving-content-also-translates") { try await page.evaluateJavaScript("document.querySelector('#late').textContent") as? String == "Hello world" }
        _ = try await page.evaluateJavaScript("document.querySelector('#link').textContent='Un nouveau lien'")
        try await wait("updated-content-is-translated-again") { try await page.evaluateJavaScript("document.querySelector('#link').textContent") as? String == "English: Un nouveau lien" }
        let beforeBulk = calls
        _ = try await page.evaluateJavaScript("for(let i=0;i<120;i++){const p=document.createElement('p');p.className='bulk';p.textContent='Bonjour le monde';document.body.append(p)}")
        try await wait("large-pages-drain-multiple-bounded-batches") { try await page.evaluateJavaScript("[...document.querySelectorAll('.bulk')].every(p=>p.textContent==='Hello world')") as? Bool == true }
        try check("large-page-translation-is-split-into-batches", calls >= beforeBulk+3)
        try await wait("bulk-translation-finishes-before-turning-off") { !translation.state(for: page).busy }
        address.translateButton.sendActions(for: .primaryActionTriggered)
        try check("blue-to-normal-is-immediate-without-an-icon-swap", address.translateButton.tintColor == .label && address.translateButton.symbolName == "page-translation")
        try await wait("turning-off-restores-original-whitespace") { try await page.evaluateJavaScript("document.querySelector('#article').textContent") as? String == "  "+french+"  " }
        try check("turning-off-restores-the-latest-site-provided-text", try await page.evaluateJavaScript("document.querySelector('#link').textContent") as? String == "Un nouveau lien")
        try check("turning-off-restores-rtl-and-language", try await page.evaluateJavaScript("document.documentElement.lang==='fr' && document.documentElement.dir==='rtl' && document.body.dir==='rtl'") as? Bool == true)
        try check("turning-off-restores-normal-icon-colour", !address.translateButton.isSelected && address.translateButton.tintColor == .label)
        try check("toggle-does-not-reload-the-page", try await page.evaluateJavaScript("window.marker") as? Double == marker)
        address.translateButton.sendActions(for: .primaryActionTriggered)
        try await wait("translation-can-be-enabled-again") { try await page.evaluateJavaScript("document.querySelector('#article').textContent.trim()") as? String == english }
        translation.toggle(page)
        try await Task.sleep(for: .milliseconds(250))
        delay = true; translation.toggle(page)
        try await Task.sleep(for: .milliseconds(100)); translation.toggle(page)
        try await Task.sleep(for: .milliseconds(600))
        try check("cancelled-model-results-cannot-rewrite-the-original", try await page.evaluateJavaScript("document.querySelector('#article').textContent.trim()") as? String == french)
        delay = false; fail = true; translation.toggle(page)
        try await wait("model-errors-reset-the-enabled-state") { !translation.state(for: page).enabled }
        browser.presentedViewController?.dismiss(animated: false)
        fail = false
        translation.toggle(page)
        try await wait("translation-recovers-after-a-model-error") { try await page.evaluateJavaScript("document.querySelector('#article').textContent.trim()") as? String == english }
        _ = try await page.evaluateJavaScript("dispatchEvent(new PageTransitionEvent('pagehide', {persisted:true}))")
        translation.didCommit(page)
        _ = try await page.evaluateJavaScript("dispatchEvent(new PageTransitionEvent('pageshow', {persisted:true}))")
        try await wait("back-forward-cache-returns-the-original-with-a-working-toggle") { translation.state(for: page).language == "fr" && !translation.state(for: page).enabled }
        try check("back-forward-cache-cannot-leave-unmarked-translated-text", try await page.evaluateJavaScript("document.querySelector('#article').textContent.trim()") as? String == french)
        page.loadHTMLString("<html lang='fr'><body><p>\(english)</p></body></html>", baseURL: URL(string: "https://translation.example/english")!)
        try await wait("english-navigation-hides-the-icon-and-resets-state") { !page.isLoading && translation.state(for: page).language == "en" && address.translateButton.isHidden && !translation.state(for: page).enabled }
        try check("english-navigation-never-shows-the-discovery-hint", browser.bottomBar.translationHint == nil)
        let before = calls
        _ = try await page.evaluateJavaScript("document.body.appendChild(document.createElement('p')).textContent='More English content.'")
        try await Task.sleep(for: .milliseconds(650))
        try check("english-pages-do-not-invoke-the-model", calls == before)
        let other = BrowserViewController.makeWebView(dataStore: .nonPersistent())
        translation.install(on: other)
        other.loadHTMLString("<html lang='fr'><body><p>\(french)</p></body></html>", baseURL: URL(string: "https://translation.example/another-tab")!)
        try await wait("a-second-page-has-its-own-detected-language") { translation.state(for: other).language == "fr" }
        try check("background-detection-does-not-announce-in-the-current-toolbar", browser.bottomBar.translationHint == nil)
        translation.toggle(other)
        try await wait("a-second-page-can-translate-independently") { try await other.evaluateJavaScript("document.body.textContent") as? String == english }
        try check("background-translation-does-not-change-the-current-pages-icon", translation.state(for: other).enabled && !translation.state(for: page).enabled && address.translateButton.isHidden)
        translation.cancel(other)
        page.loadHTMLString(html, baseURL: URL(string: "https://translation.example/deferred")!)
        try await wait("a-new-document-is-detected-while-the-menu-is-open") { translation.state(for: page).language == "fr" && !page.isLoading }
        try check("the-hint-waits-while-a-panel-is-open", browser.bottomBar.translationHint == nil)
        browser.closePanel()
        try await wait("closing-the-panel-reveals-the-deferred-hint") { browser.bottomBar.translationHint != nil }
        browser.openPanel(.menu)
        try check("opening-the-menu-cancels-the-flying-hint-and-its-impact", browser.bottomBar.translationHint == nil && landing.layer.animationKeys()?.contains(where: { $0.hasPrefix("translation-impact-") }) != true)
        browser.closePanel()
    }
}
#endif
