// Rise's features on Chromium pages, in a real Rise window: the tab's sound and its play button
// (also from a frame of another site, in a process of its own), picture in picture, find,
// downloads, camera and location prompts, history after a relaunch, what Rise does as pages
// load, fail, crash and close, its theme, full screen, ad blocking and Preload Links, windows that
// keep their opener, site search learning, notifications, merge checks and DevTools.
// Run with python3 scripts/test-chromium-live.py features.
import AppKit
@testable import Rise
import RiseChromium

typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

@main @MainActor struct ChromiumFeatureMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        // A check that hangs reports it rather than holding everything up.
        DispatchQueue.main.asyncAfter(deadline: .now()+240) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumFeatureRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumFeatureRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    let suite = "RiseChromiumCheck-\(UUID().uuidString)"
    let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",").map(String.init)
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }
    /// The two sites the pages come from.
    var site: String { "http://localhost:\(ports[0])" }
    var otherSite: String { "http://127.0.0.1:\(ports[1])" }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { print("FAIL timed out:", what); failures += 1; return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: nil, world: .page)
    }
    func page(_ name: String, _ html: String) throws -> URL {
        try "<!doctype html><meta charset=utf-8><title>\(name)</title>\(html)".write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
        return URL(string: "\(site)/\(name).html")!
    }
    func open(_ url: URL) async -> BrowserTab {
        let tab = browser.addTab(url: url)
        _ = await waitUntil("\(url.lastPathComponent) loads") { tab.page.url == url && !tab.page.isLoading }
        return tab
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await run()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func run() async {
        do { try await checks() } catch { check(false, "\(error)") }
    }

    /// How many times the first site's server was asked for `path`.
    func requests(_ path: String) -> Int {
        let log = (try? String(contentsOf: folder.appendingPathComponent("server-0.log"), encoding: .utf8)) ?? ""
        return log.components(separatedBy: "\"GET \(path) ").count - 1
    }

    /// Rise's theme, full screen, ad blocking and Preload Links on Chromium pages.
    func pageLook() async throws {
        // A Dark page prefers dark, and starts in Rise's dark page colour before it first draws.
        browser.theme = .dark; browser.update()
        let themed = browser.addTab(url: try page("theme", "<meta name=color-scheme content='light dark'><h1>Theme</h1>"))
        let start = (themed.page as! ChromiumPage).browserView.pageBackgroundColor.usingColorSpace(.sRGB)
        let dark = RiseTheme.dark.page.usingColorSpace(.sRGB)
        check(start != nil && dark != nil && abs(start!.redComponent - dark!.redComponent) < 0.01, "A new page starts in Rise's dark page colour")
        _ = await waitUntil("theme.html loads") { themed.page.url?.lastPathComponent == "theme.html" && !themed.page.isLoading }
        let prefersDark = "return matchMedia('(prefers-color-scheme: dark)').matches"
        check(await value(prefersDark, in: themed.page) as? Bool == true, "A Dark page prefers dark")
        browser.theme = .neutral; browser.update()
        _ = await waitUntil("And light again in Light") { await self.value(prefersDark, in: themed.page) as? Bool == false }

        // Native full screen: the page goes to a full-screen window of its own and comes back,
        // when it leaves itself and on Escape.
        let box = "<div id=box style='width:200px;height:100px;background:red'></div>"
        let screen = await open(try page("fullscreen", box))
        let enter = "document.getElementById('box').requestFullscreen().catch(() => {}); return 0"
        for (round, leave) in ["the page leaves", "Escape"].enumerated() {
            _ = await value(enter, in: screen.page)
            guard await waitUntil("The page goes full screen (\(round))", 10, { screen.page.isInNativeFullscreen && screen.page.view.window?.styleMask.contains(.fullScreen) == true }),
                  let window = screen.page.view.window else { break }
            check(await value("return document.fullscreenElement?.id", in: screen.page) as? String == "box", "The element is full screen")
            if round == 0 { _ = await value("document.exitFullscreen(); return 0", in: screen.page) }
            else if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                window.sendEvent(escape)
            }
            _ = await waitUntil("It comes back to its tab when \(leave)") {
                !screen.page.isInNativeFullscreen && screen.page.view.window === self.browser.window
            }
            _ = await waitUntil("And out of full screen") { await self.value("return document.fullscreenElement === null", in: screen.page) as? Bool == true }
        }

        // Simulated full screen lifts the element over the page in its tab, and later pages get it too.
        browser.pageFullscreen.setSimulated(true, in: browser.tabs.map(\.page))
        _ = await value(enter, in: screen.page)
        _ = await waitUntil("The element is lifted over the page") { self.browser.pageFullscreen.isActive(in: screen.page.view) }
        check(!screen.page.isInNativeFullscreen && screen.page.view.window === browser.window, "In its own tab")
        let rect = await value("const r = document.getElementById('box').getBoundingClientRect(); return [r.width, innerWidth]", in: screen.page) as? [Double]
        check(rect?.first == rect?.last, "Covering the page: \(rect ?? [])")
        _ = await value("document.exitFullscreen(); return 0", in: screen.page)
        _ = await waitUntil("And lets it go") { !self.browser.pageFullscreen.isActive(in: screen.page.view) }
        // Rise's scripts run in a tab's later documents too, not only its first.
        _ = await value("window.riseCheckOld = true; return 0", in: screen.page)
        screen.page.reload()
        _ = await waitUntil("A later page is simulated too") {
            await self.value("return !window.riseCheckOld && window.__riseFullscreen?.simulated", in: screen.page) as? Bool == true
        }
        browser.pageFullscreen.setSimulated(false, in: browser.tabs.map(\.page))

        // Ad blocking: requests the lists block don't go out, and ad slots are hidden, also ones
        // added later, by EasyList's rules and Rise's own; turning it off lets them through.
        try "ok".write(to: folder.appendingPathComponent("x_ads_banner_1.txt"), atomically: true, encoding: .utf8)
        _ = try page("ads", "<div class=ADBAR id=slot>Ad</div><div class=adsbox id=own>Ad</div><p id=text>Text</p>")
        let ads = await open(URL(string: "http://rise-check.test:\(ports[0])/ads.html")!)
        let fetches = "return fetch('x_ads_banner_1.txt').then(r => r.ok, () => 'blocked')"
        let hidden = "const add = document.createElement('div'); add.className = 'ADBox'; add.id = 'later'; document.body.append(add);" +
            "await new Promise(r => setTimeout(r, 400)); return ['slot', 'own', 'later', 'text'].map(id => getComputedStyle(document.getElementById(id)).display)"
        check(await value(fetches, in: ads.page) as? String == "blocked", "A blocked request doesn't go out")
        _ = await waitUntil("Ad slots are hidden, and only them") { await self.value(hidden, in: ads.page) as? [String] == ["none", "none", "none", "block"] }
        browser.toggleAdBlocking()
        _ = await waitUntil("Turned off, the request goes out") { await self.value(fetches, in: ads.page) as? Bool == true }
        _ = await waitUntil("And, reloaded, nothing is hidden") { await self.value(hidden, in: ads.page) as? [String] == ["block", "block", "block", "block"] }
        browser.toggleAdBlocking()
        _ = await waitUntil("Turned on again, they're hidden again") { await self.value(hidden, in: ads.page) as? [String] == ["none", "none", "none", "block"] }

        // Preload Links: resting on a link loads its page, without its scripts, and the click takes
        // it from the cache.
        _ = try page("warm", "<link rel=stylesheet href=warm.css><script>fetch('script-ran')</script><h1>Warm</h1>")
        try "h1 { color: green }".write(to: folder.appendingPathComponent("warm.css"), atomically: true, encoding: .utf8)
        // Long unchanged, so the cache keeps them fresh for a while, as a server's own caching would.
        for name in ["warm.html", "warm.css"] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -365 * 86400)],
                                                  ofItemAtPath: folder.appendingPathComponent(name).path)
        }
        browser.linkPreloader.setEnabled(true)
        let links = await open(try page("hover", "<a id=warm href=warm.html>Warm</a>"))
        _ = await value("document.getElementById('warm').dispatchEvent(new PointerEvent('pointerover', {bubbles: true, composed: true, pointerType: 'mouse'})); return 0",
                        in: links.page)
        let warm = URL(string: "\(site)/warm.html")!
        _ = await waitUntil("The page is preloaded") { self.browser.linkPreloader.isComplete(warm) }
        check(requests("/warm.html") == 1 && requests("/warm.css") == 1 && requests("/script-ran") == 0,
              "Its page and style are fetched, but its scripts don't run")
        check(browser.tabs.count == browser.tabs.filter { $0.page.url != warm }.count, "Nothing opens")
        _ = await value("document.getElementById('warm').click(); return 0", in: links.page)
        _ = await waitUntil("The click goes there") { links.page.url == warm && !links.page.isLoading }
        _ = await waitUntil("And runs its scripts") { self.requests("/script-ran") == 1 }
        check(requests("/warm.css") == 1, "Taking the style from the cache: \(requests("/warm.html")) page and \(requests("/warm.css")) style requests")
        browser.linkPreloader.setEnabled(false)
    }

    /// Runs a script in a page that isn't a tab's, such as DevTools' own.
    func value(_ script: String, in view: RCBrowserView) async -> Any? {
        await withCheckedContinuation { done in view.evaluateFunctionBody(script, arguments: [:], frame: nil, world: nil) { value, _ in done.resume(returning: value) } }
    }

    /// Windows that keep their opener, site search learning, notifications, merge checks,
    /// DevTools, the JavaScript Console and View Source.
    func riseFeatures() async throws {
        check(ChromiumEngine.isRequested, "Chromium is Rise's engine unless asked for WebKit")

        // A window a page opens is still its popup, as sign-ins and Gmail's popped-out emails need.
        _ = try page("child", "<h1>Child</h1>")
        let parent = await open(try page("parent", "<h1>Parent</h1>"))
        _ = await value("window.open('child.html'); return 0", in: parent.page)
        if await waitUntil("The window opens in a tab", 10, { self.browser.tabs.contains { $0.returnsTo == parent.id } }),
           let child = browser.tabs.first(where: { $0.returnsTo == parent.id }) {
            _ = await waitUntil("Its page loads") { child.page.url?.lastPathComponent == "child.html" && !child.page.isLoading }
            check(await value("return window.opener?.document.title", in: child.page) as? String == "parent", "Its opener is still there")
            browser.closeTab(child.id)
        }

        // A search made on a site teaches the address bar to search it.
        _ = try page("shop", """
        <meta property=og:site_name content='Lamp Shop'><form><input type=search name=find><button>Search</button></form>
        <script>document.querySelector('form').addEventListener('submit', event => {
          event.preventDefault(); history.pushState({}, '', '/results/?term=' + encodeURIComponent(event.target.find.value))
        })</script>
        """)
        let shop = await open(URL(string: "http://rise-check.test:\(ports[0])/shop.html")!)
        _ = await value("document.querySelector('[name=find]').value = 'desk lamp'; document.querySelector('form').requestSubmit(); return 0", in: shop.page)
        _ = await waitUntil("Rise learns the site's search") { self.browser.siteSearchLearner.searches.site(forAddress: "rise-check.test")?.name == "Lamp Shop" }

        // A site asking to notify gets Rise's prompt.
        browser.permissionCoordinator.requestNotificationAuthorization = { $0(true) }
        let notifying = await open(try page("notify", "<h1>Notify</h1>"))
        _ = await value("Notification.requestPermission().then(answer => window.answer = answer); return 0", in: notifying.page)
        if await waitUntil("Rise asks first", 10, { self.browser.permissionCoordinator.popover.isShown }) {
            browser.permissionCoordinator.resolve(true)
            _ = await waitUntil("And the site may notify") { await self.value("return window.answer", in: notifying.page) as? String == "granted" }
        }

        // A pull request's merge checks are scrolled to.
        let pr = await open(try page("pr", "<div style='height:3000px'></div><div data-testid=merge-checks style='height:80px'>Checks</div><div style='height:3000px'></div>"))
        _ = try? await pr.page.evaluate("return " + BrowserController.scrollToMergeChecks, arguments: [:], in: nil, world: .named("Rise.HoverCards"))
        _ = await waitUntil("The merge checks are in view") { (await self.value("return scrollY", in: pr.page) as? Double ?? 0) > 2000 }

        // DevTools slide in from the right as the page makes room, inspect it on Elements, and
        // slide away again.
        let inspected = await open(try page("inspected", "<h1>Inspected</h1>"))
        let wide = inspected.page.view.frame.width
        browser.toggleDevTools()
        _ = await waitUntil("DevTools slide in") { self.browser.devTools.isOpen && self.browser.devTools.progress == 1 }
        check(inspected.page.view.frame.width < wide-300, "The page makes room: \(wide) to \(inspected.page.view.frame.width)")
        if let frontend = browser.devTools.clip.subviews.first as? RCBrowserView {
            _ = await waitUntil("They inspect the page", 20) { frontend.title?.contains("inspected.html") == true }
            let elements = """
            const find = root => root.querySelector('#tab-elements') ||
              [...root.querySelectorAll('*')].map(node => node.shadowRoot && find(node.shadowRoot)).find(Boolean);
            return find(document)?.getAttribute('aria-selected')
            """
            _ = await waitUntil("On the Elements panel", 10) { await self.value(elements, in: frontend) as? String == "true" }
            let picking = "const UI = await import('./ui/legacy/legacy.js'); return UI.ActionRegistry.ActionRegistry.instance().getAction('elements.toggle-element-search').toggled()"
            _ = await waitUntil("Ready to select an element", 10) { await self.value(picking, in: frontend) as? Bool == true }
        } else { check(false, "DevTools are in the panel") }
        // A third of the window by default, with the split's handle in the gap beside the page.
        let panel = browser.devTools, standard = panel.shadow.frame.width
        check(abs(standard-(browser.root.bounds.width*0.32).rounded()) < 1, "DevTools are a third of the window wide: \(standard)")
        check(!panel.handle.isHidden && panel.handle.frame.maxX == panel.shadow.frame.minX, "The handle is in the gap beside them")
        // Dragged left, the handle widens DevTools and the page gives way; the width is kept.
        let pageBefore = inspected.page.view.frame.width
        panel.handle.onDrag?(-100); panel.handle.onDragEnd?()
        check(panel.shadow.frame.width == standard+100 && inspected.page.view.frame.width == pageBefore-100, "Dragging the handle resizes DevTools and the page")
        check(browser.preferences.double(forKey: DevToolsPanel.widthKey) == Double(standard+100), "The width is kept")
        // A double click goes back to the standard width.
        panel.handle.onReset?()
        check(panel.shadow.frame.width == standard && browser.preferences.object(forKey: DevToolsPanel.widthKey) == nil, "A double click resets it")
        // With their animation off, DevTools come and go at once.
        browser.setAnimatesDevTools(false)
        browser.toggleDevTools()
        check(panel.shadow.isHidden && panel.tabID == nil && inspected.page.view.frame.width == wide, "Without the animation they go at once")
        browser.toggleDevTools()
        check(panel.progress == 1 && !panel.shadow.isHidden, "And come at once")
        browser.setAnimatesDevTools(true)
        browser.toggleDevTools()
        _ = await waitUntil("And slide away") { self.browser.devTools.shadow.isHidden && self.browser.devTools.tabID == nil }
        check(inspected.page.view.frame.width == wide, "The page takes its room back")
        // Closing DevTools' page must never close the window it was in.
        try await Task.sleep(for: .milliseconds(500))
        check(browser.window?.isVisible == true, "Rise's window stays open")

        // The JavaScript Console runs what's typed as a console does, and View Source opens the source.
        let console = await withCheckedContinuation { done in
            (inspected.page as! ChromiumPage).browserView.evaluateConsoleExpression("let a = 2; await Promise.resolve(a * 21)") { value, _ in done.resume(returning: value) }
        }
        check((console as? NSNumber)?.intValue == 42, "The console's answer: \(console ?? "nil")")
        browser.viewSource()
        _ = await waitUntil("The source opens in a tab") { self.browser.selectedTab?.page.url?.scheme == "view-source" }

        // Chrome's settings are Rise's, at rise://settings and every page under it.
        browser.showSettings()
        if let settings = browser.selectedTab {
            _ = await waitUntil("rise://settings opens", 15) { settings.page.url == RisePages.settings && !settings.page.isLoading }
            _ = await waitUntil("With Chrome's settings in it", 15) {
                await self.value("return !!document.querySelector('settings-ui')", in: settings.page) as? Bool == true
            }
            settings.load(URL(string: "rise://settings/privacy")!)
            _ = await waitUntil("And its pages") { settings.page.url?.absoluteString == "rise://settings/privacy" && !settings.page.isLoading }
            browser.showSettings()
            check(browser.selectedID == settings.id && browser.tabs.filter({ $0.page.url?.scheme == "rise" }).count == 1, "⌘, goes back to the settings already open")
        }
        // A site can't open them.
        let sneaky = await open(try page("sneaky", "<a id=s href='chrome://settings'>Settings</a>"))
        _ = await value("location.href = 'chrome://settings'; return 0", in: sneaky.page)
        try await Task.sleep(for: .milliseconds(800))
        check(sneaky.page.url?.lastPathComponent == "sneaky.html", "A site can't open settings: \(sneaky.page.url?.absoluteString ?? "-")")
    }

    func checks() async throws {
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let video = "<video src=clip.mp4 autoplay loop playsinline style='width:480px'></video>"

        // The tab's sound, and its play button pausing and resuming the page's media.
        let media = await open(try page("media", "<h1>Media</h1>\(video)"))
        check(media.page.engine == .chromium, "Tabs open in Chromium")
        _ = await waitUntil("Chromium reports the tab making sound") { media.page.isPlayingAudio }
        _ = await waitUntil("The tab's media reports itself playing") { browser.playbackPaused(media.id) == false }
        browser.togglePlayback(media.id)
        _ = await waitUntil("The play button pauses it") { browser.playbackPaused(media.id) == true }
        check(await value("return document.querySelector('video').paused", in: media.page) as? Bool == true, "The page's video is paused")
        _ = await waitUntil("The tab goes quiet") { !media.page.isPlayingAudio }
        browser.togglePlayback(media.id)
        _ = await waitUntil("The play button resumes it") { browser.playbackPaused(media.id) == false }

        // Picture in picture: leaving the tab floats its video, live, and showing it takes it back.
        _ = browser.addTab()
        _ = await waitUntil("Leaving the tab floats its video") {
            browser.pictureInPicture.sourceTabID == media.id && browser.pictureInPicture.panel?.alphaValue == 1
        }
        if let panel = browser.pictureInPicture.panel {
            check(media.page.view.window === panel, "The page itself is in the floating window")
            let capture = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")!, to: Capture.self)
            func picture() -> Data? {
                capture(.null, 8, UInt32(panel.windowNumber), 1|16).flatMap { NSBitmapImageRep(cgImage: $0.takeRetainedValue()).representation(using: .png, properties: [:]) }
            }
            let first = picture(); try await Task.sleep(for: .milliseconds(600))
            check(first != nil && first != picture(), "The floating video moves")
        }
        browser.select(media.id)
        _ = await waitUntil("Showing the tab takes the page back") { media.page.view.window === browser.window }
        check(await value("return !document.querySelector('video').paused", in: media.page) as? Bool == true, "The video plays on in its tab")

        // A frame of another site, in a process of its own, reports its media and pauses with the tab.
        try "<!doctype html><title>Frame</title>\(video)".write(to: folder.appendingPathComponent("frame.html"), atomically: true, encoding: .utf8)
        let framed = await open(try page("framed", "<h1>Framed</h1><iframe src='\(otherSite)/frame.html' allow=autoplay width=520 height=320></iframe>"))
        _ = await waitUntil("The other site's frame reports its media") { browser.playbackPaused(framed.id) == false }
        browser.togglePlayback(framed.id)
        _ = await waitUntil("The play button pauses the frame's video") { browser.playbackPaused(framed.id) == true }
        browser.togglePlayback(framed.id)
        _ = await waitUntil("And resumes it") { browser.playbackPaused(framed.id) == false }
        _ = browser.addTab()
        _ = await waitUntil("Leaving the tab floats the frame's video") {
            browser.pictureInPicture.sourceTabID == framed.id && browser.pictureInPicture.panel?.alphaValue == 1
        }
        browser.select(framed.id)
        _ = await waitUntil("Showing the tab takes it back") { framed.page.view.window === browser.window }
        for tab in [media, framed] { browser.closeTab(tab.id) }

        // Find.
        let text = await open(try page("find", "<p>An apple a day.</p><p>Apples, and more apple pie.</p>"))
        let found = await PageFind.find("apple", direction: .restart, in: text.page)
        check(found == PageFind.Matches(count: 3, index: 0), "Find counts every match: \(found)")
        let next = await PageFind.find("apple", direction: .next, in: text.page)
        check(next.index == 1, "Find steps to the next match: \(next)")

        // Downloads.
        let downloads = await open(try page("downloads", "<a id=d href=clip.mp4 download=clip-copy.mp4>Save</a>"))
        _ = await value("document.getElementById('d').click()", in: downloads.page)
        _ = await waitUntil("The download finishes in Rise's list") {
            browser.downloads.items.first.map { $0.record.url.lastPathComponent == "clip-copy.mp4" && $0.isFinished } == true
        }
        let saved = browser.downloadsFolder.appendingPathComponent("clip-copy.mp4")
        let size = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? Int) ?? 0
        let original = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("clip.mp4").path)[.size] as? Int) ?? -1
        check(size == original, "The whole file is saved where Rise put it (\(size) of \(original) bytes)")

        // Camera and location go through Rise's own prompt.
        let ask = await open(try page("permissions", "<h1>Permissions</h1>"))
        _ = await value("""
            navigator.mediaDevices.getUserMedia({video: true}).then(s => window.camera = 'granted ' + s.getVideoTracks().length, e => window.camera = e.name)
            """, in: ask.page)
        _ = await waitUntil("Rise asks before the site gets the camera") { browser.permissionCoordinator.popover.isShown }
        browser.permissionCoordinator.resolve(true)
        _ = await waitUntil("Allowing gives the site the camera") { await value("return window.camera", in: ask.page) as? String == "granted 1" }
        _ = await value("""
            navigator.geolocation.getCurrentPosition(() => window.place = 'granted', e => window.place = 'denied ' + e.code)
            """, in: ask.page)
        _ = await waitUntil("Rise asks before the site gets the location") { browser.permissionCoordinator.popover.isShown }
        browser.permissionCoordinator.resolve(false)
        _ = await waitUntil("Denying refuses it") { await value("return window.place", in: ask.page) as? String == "denied 1" }

        // Loaded pages go in the browsing history, and their tabs get a picture for the tab switcher.
        check(browser.browsingHistory.entries.contains { $0.url == text.page.url?.absoluteString && $0.title == "find" },
              "Visited pages are in the browsing history")
        _ = await waitUntil("The tab gets its picture") { text.thumbnail != nil }

        // A page that can't load shows Rise's error, worded plainly.
        let closed = { let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); defer { Darwin.close(socket) }
            var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, length) } }
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(socket, $0, &length) } }
            return Int(UInt16(bigEndian: address.sin_port))
        }()
        // A port nothing listens on.
        let broken = browser.addTab(url: URL(string: "http://127.0.0.1:\(closed)/")!)
        _ = await waitUntil("Rise shows the page's error") {
            browser.errorWebView === broken.page.view && browser.errorMessage.stringValue == "Could not connect to the server."
        }
        check(!browser.errorSurface.isHidden, "The error is on screen")

        // A link for another app asks first.
        let links = await open(try page("links", "<a id=m href='mailto:rise@example.com'>Mail</a>"))
        _ = await value("document.getElementById('m').click()", in: links.page)
        _ = await waitUntil("Rise asks before opening another app") {
            (browser.window?.attachedSheet?.contentViewController as Any?) != nil || browser.window?.attachedSheet != nil
        }
        if let sheet = browser.window?.attachedSheet { browser.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }

        // A page whose process crashes loads again.
        let crashing = await open(try page("crash", "<h1>Crash</h1>"))
        let devTools = NSSelectorFromString("devTools:params:completion:")
        typealias Send = @convention(c) (AnyObject, Selector, NSString, NSDictionary, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
        let view = (crashing.page as! ChromiumPage).browserView
        unsafeBitCast(class_getMethodImplementation(RCBrowserView.self, devTools), to: Send.self)(view, devTools, "Page.crash", [:]) { _ in }
        try await Task.sleep(for: .milliseconds(500))
        _ = await waitUntil("The crashed page loads again") {
            await value("return document.title", in: crashing.page) as? String == "crash" && !crashing.page.isLoading
        }

        // A tab a site opened closes when the site asks, back to the tab that opened it.
        _ = try page("closer", "<script>setTimeout(() => window.close(), 400)</script><h1>Closer</h1>")
        let opener = await open(try page("opener", "<h1>Opener</h1>"))
        _ = await value("window.open('closer.html')", in: opener.page)
        _ = await waitUntil("The site's tab opens") { browser.tabs.contains { $0.returnsTo == opener.id } }
        _ = await waitUntil("And closes itself") { !browser.tabs.contains { $0.returnsTo == opener.id } && browser.selectedID == opener.id }

        try await pageLook()
        try await riseFeatures()

        // History after a relaunch: a page made later goes straight to where the tab was, with its history.
        let first = try page("first", "<h1>First</h1>"), second = try page("second", "<h1>Second</h1>")
        let history = await open(first)
        history.page.load(second)
        _ = await waitUntil("The tab goes on to a second page") { history.page.url == second && !history.page.isLoading && history.page.canGoBack }
        guard let state = history.sessionState else { check(false, "The tab has history to save"); return }
        let restored = ChromiumPage()
        restored.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300); browser.root.addSubview(restored.view, positioned: .below, relativeTo: nil)
        check(restored.restoreSession(state, fallback: first), "A new page takes the saved history")
        _ = await waitUntil("It opens where the tab was") { restored.url == second && !restored.isLoading }
        check(restored.canGoBack, "With the page before it to go back to")
        restored.goBack()
        _ = await waitUntil("Back goes to the first page") { restored.url == first && !restored.isLoading }
    }
}
