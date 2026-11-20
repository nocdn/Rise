// Rise's features on Chromium pages, in a real Rise window: the tab's sound and its play button
// (also from a frame of another site, in a process of its own), picture in picture, find,
// downloads, camera and location prompts, history after a relaunch, what Rise does as pages
// load, fail, crash and close, its theme, full screen, ad blocking and Preload Links, windows that
// keep their opener, site search learning, notifications, merge checks and DevTools.
// Run with python3 scripts/test-chromium-live.py features.
import AppKit
@testable import Rise
import RiseCore
import RiseChromium

typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

@main @MainActor struct ChromiumFeatureMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        // A check that hangs reports it rather than holding everything up (RISE_CHECK_TIMEOUT: seconds).
        let limit = Double(ProcessInfo.processInfo.environment["RISE_CHECK_TIMEOUT"] ?? "") ?? 240
        DispatchQueue.main.asyncAfter(deadline: .now()+limit) { print("FAIL the check stopped answering"); exit(1) }
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
        do {
            try await checks()
        } catch { check(false, "\(error)") }
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

        // Ad blocking (uBlock Origin, with its own lists): an ad network's script doesn't load, and ad
        // slots are hidden, also ones added later; turning it off lets them through. The ad network's
        // host is this server (scripts/test-chromium-live.py maps it).
        try "window.riseAdRan = true".write(to: folder.appendingPathComponent("adsbygoogle.js"), atomically: true, encoding: .utf8)
        _ = try page("ads", "<div class=ADBAR id=slot>Ad</div><div id=ad_banner>Ad</div><p id=text>Text</p>")
        let ads = await open(URL(string: "http://rise-check.test:\(ports[0])/ads.html")!)
        let fetches = "return new Promise(r => { const s = document.createElement('script'); s.src = 'http://pagead2.googlesyndication.com:\(ports[0])/adsbygoogle.js?' + Math.random();" +
            "s.onload = () => r(true); s.onerror = () => r('blocked'); document.head.append(s); })"
        let hidden = "const add = document.createElement('div'); add.className = 'ADBAR'; add.id = 'later'; document.body.append(add);" +
            "await new Promise(r => setTimeout(r, 400)); return ['slot', 'ad_banner', 'later', 'text'].map(id => getComputedStyle(document.getElementById(id)).display)"
        _ = await waitUntil("A blocked request doesn't go out") { await self.value(fetches, in: ads.page) as? String == "blocked" }
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

    /// Right-clicks the point `locate` returns, as [x, y] in the page, and gives back the menu Rise shows.
    func rightClick(_ locate: String, in page: WebPage, _ what: String) async -> NSMenu? {
        guard let window = browser.window, let at = await value(locate, in: page) as? [Double] else { check(false, "\(what) is there"); return nil }
        let view = page.view
        let point = view.convert(NSPoint(x: at[0], y: view.isFlipped ? at[1] : view.bounds.height-at[1]), to: nil)
        var shown: NSMenu?
        browser.presentContextMenu = { menu, _, _ in shown = menu }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .rightMouseDown ? 1 : 0) { window.sendEvent(event) }
        }
        _ = await waitUntil("A right-click on \(what) opens Rise's menu") { shown != nil }
        return shown
    }
    /// Clicks the point `locate` returns, as [x, y] in the page, as the pointer would.
    func leftClick(_ locate: String, in page: WebPage, modifiers: NSEvent.ModifierFlags = []) async {
        guard let window = browser.window, let at = await value(locate, in: page) as? [Double] else { check(false, "There's something to click"); return }
        let view = page.view
        let point = view.convert(NSPoint(x: at[0], y: view.isFlipped ? at[1] : view.bounds.height-at[1]), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) { window.sendEvent(event) }
        }
    }
    func titles(_ menu: NSMenu?) -> [String] { menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? [] }
    func choose(_ title: String, in menu: NSMenu?) {
        guard let item = menu?.items.first(where: { $0.title == title }), let action = item.action else { check(false, "The menu has “\(title)”"); return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
    func center(_ selector: String) -> String {
        "const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]"
    }
    /// The Chromium view taking the page's events and text input.
    func inputView(of page: WebPage) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("RenderWidgetHostViewCocoa") { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(page.view)
    }

    /// Rise's page menu, the page's dialogs and file chooser, spelling, Look Up, Writing Tools,
    /// pinch zoom and Chromium's own picture in picture.
    func menusAndDialogs() async throws {
        let pasteboard = NSPasteboard.general
        let kept = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        defer { pasteboard.clearContents(); pasteboard.writeObjects(kept) }

        let menus = await open(try page("menus", """
        <p id=text style='font-size:20px'>The quick brown fox jumps over the lazy dog.</p>
        <p id=price style='font-size:20px'>Tickets £66.06, or a box for 1,250.00 GBP.</p>
        <p><a id=link href='https://example.com/linked'>A link somewhere</a></p>
        <p style='font-size:20px'>Lives at <span id=address>100 Newland Park Drive, York</span>.</p>
        <p style='font-size:20px'><a id=linked-address href='https://example.com/letting'>100 Newland Park Drive, York</a></p>
        <p><a id=pic href='https://example.com/pictured'><img id=img src=picture.png width=120></a></p>
        <p><img id=gone src=missing.png width=120 height=40></p>
        <p><video id=clip src=clip.mp4 width=120 height=68 muted preload=auto></video></p>
        <div id=field contenteditable spellcheck=true style='font-size:20px;padding:4px;border:1px solid'>Ths is wrng</div>
        <div id=blank style='height:120px'></div>
        <input id=file type=file>
        """))
        _ = await waitUntil("The menu page's picture loads") { await self.value("return document.querySelector('#img').complete", in: menus.page) as? Bool == true }

        // A link: Rise's items, as on WebKit, with Peek and DevTools.
        let link = await rightClick(center("#link"), in: menus.page, "a link")
        check(["Open Link", "Open Link in New Tab", "Open Link in Peek", "Download Linked File", "Copy Link", "Share…", "Inspect Element"]
              .allSatisfy(titles(link).contains), "A link's menu: \(titles(link))")
        check(link?.mixesIconsInASection == false, "Items without icons aren't indented beside ones with: \(titles(link))")
        choose("Copy Link", in: link)
        check(pasteboard.string(forType: .string) == "https://example.com/linked", "Copy Link copies its address")
        // AirDrop, right under Share in its section, with an icon like Share's, sends the link straight there.
        let shared = link?.items ?? []
        let airDrop = shared.firstIndex { $0.title == "Share…" }.flatMap { shared.indices.contains($0+1) ? shared[$0+1] : nil }
        #if compiler(>=6.4)
        let iconShows = { if #available(macOS 27, *) { airDrop?.preferredImageVisibility == .visible } else { true } }()
        #else
        let iconShows = true
        #endif
        check(airDrop?.title == "AirDrop" && airDrop?.image?.isTemplate == true && airDrop?.image?.size == NSSize(width: 15, height: 15) && iconShows,
              "AirDrop follows Share: \(titles(link))")

        // An image in a link: the link's items and the image's.
        let image = await rightClick(center("#img"), in: menus.page, "an image")
        check(["Open Link", "Open Image in New Tab", "Download Image", "Copy Image Address", "Copy Image"].allSatisfy(titles(image).contains),
              "An image's menu: \(titles(image))")
        pasteboard.clearContents()
        choose("Copy Image", in: image)
        _ = await waitUntil("Copy Image copies its picture") { pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) }

        // AirDrop Image and Video send the file itself, from a temporary folder, not through Downloads.
        var airDropped: URL?
        browser.airDropFile = { airDropped = $0 }
        let downloadsBefore = browser.downloads.items.count
        check(titles(image).contains("AirDrop") && titles(image).last(where: { $0.hasPrefix("AirDrop") }) == "AirDrop Image"
              && image?.items.first { $0.title == "AirDrop Image" }?.image === AirDropMenuItem.icon, "A linked image has its own AirDrop: \(titles(image))")
        choose("AirDrop Image", in: image)
        _ = await waitUntil("AirDrop Image gets the picture") { airDropped != nil }
        check(airDropped.flatMap { try? Data(contentsOf: $0) } == (try? Data(contentsOf: folder.appendingPathComponent("picture.png"))) && airDropped?.lastPathComponent == "picture.png"
              && airDropped?.path.contains(MediaAirDrop.folder.lastPathComponent) == true && browser.downloads.items.count == downloadsBefore,
              "AirDrop Image sends the picture's own file, kept out of Downloads: \(airDropped?.path ?? "none")")
        airDropped = nil
        let clipMenu = await rightClick(center("#clip"), in: menus.page, "a video")
        check(titles(clipMenu).contains("AirDrop Video"), "A video's menu: \(titles(clipMenu))")
        choose("AirDrop Video", in: clipMenu)
        _ = await waitUntil("AirDrop Video gets the video") { airDropped != nil }
        check(airDropped.flatMap { try? Data(contentsOf: $0) } == (try? Data(contentsOf: folder.appendingPathComponent("clip.mp4"))) && browser.downloads.items.count == downloadsBefore,
              "AirDrop Video sends the video's own file: \(airDropped?.path ?? "none")")
        airDropped = nil
        let gone = await rightClick(center("#gone"), in: menus.page, "a missing image")
        choose("AirDrop Image", in: gone)
        let said = await waitUntil("A missing image says it couldn't be got") { self.browser.selectedBar.notice?.text.hasPrefix("Couldn’t Get Image") == true }
        check(said && airDropped == nil && browser.downloads.items.count == downloadsBefore, "It doesn't open AirDrop on nothing")
        browser.airDropFile = nil

        // Selected text: Look Up, a search and Copy.
        _ = await value("const range = document.createRange(); range.selectNodeContents(document.querySelector('#text').firstChild);" +
                        "getSelection().removeAllRanges(); getSelection().addRange(range); return 0", in: menus.page)
        let text = await rightClick(center("#text"), in: menus.page, "selected text")
        check(titles(text).contains { $0.hasPrefix("Look Up “The quick brown fox") } && titles(text).contains("Search with \(browser.searchProvider.title)")
              && titles(text).contains("Copy"), "Selected text's menu: \(titles(text))")
        pasteboard.clearContents()
        choose("Copy", in: text)
        _ = await waitUntil("Copy copies the selection") { pasteboard.string(forType: .string)?.hasPrefix("The quick brown fox") == true }
        let windows = Set(NSApp.windows.map(ObjectIdentifier.init))
        if let item = text?.items.first(where: { $0.title.hasPrefix("Look Up") }) { choose(item.title, in: text) }
        _ = await waitUntil("Look Up shows the dictionary") { NSApp.windows.contains { !windows.contains(ObjectIdentifier($0)) && $0.isVisible && String(describing: type(of: $0)).contains("Popover") } }
        browser.window?.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))

        // A selected address: its map in a Peek, beside a link's own Peek when it's a link, or else heading the menu,
        // growing out of the selected text and closing back into it.
        for (selector, linked) in [("#address", false), ("#linked-address", true)] {
            _ = await value("const range = document.createRange(); range.selectNodeContents(document.querySelector('\(selector)'));" +
                            "getSelection().removeAllRanges(); getSelection().addRange(range); return 0", in: menus.page)
            let menu = await rightClick(center(selector), in: menus.page, "a selected address")
            let shown = titles(menu)
            if linked {
                check(shown.contains("Open Map in Peek") && shown.firstIndex(of: "Open Map in Peek") == shown.firstIndex(of: "Open Link in Peek").map { $0+1 }, "A linked address's map follows the link's Peek: \(shown)")
            } else {
                check(shown.first == "Open Map in Peek" && menu?.items.dropFirst().first?.isSeparatorItem == true, "An address heads the menu with its map: \(shown)")
            }
            choose("Open Map in Peek", in: menu)
            let peeked = await waitUntil("Open Map in Peek opens Google Maps in a Peek") {
                self.browser.peekTab?.url?.absoluteString == "https://www.google.com/maps/search/?api=1&query=100%20Newland%20Park%20Drive%2C%20York"
            }
            check(peeked, "The Peek searches Maps for the address: \(browser.peekTab?.url?.absoluteString ?? "none")")
            let selected = await value("const r = getSelection().getRangeAt(0).getBoundingClientRect(); return [r.x, r.y, r.width, r.height]", in: menus.page) as? [Double]
            let origin = await browser.peekLink(in: menus.page, locate: false)
            let zoom = max(0.01, menus.page.zoom)
            check(selected.map { abs((origin?.rect.width ?? 0) - ($0[2]*zoom+6)) < 2 && abs((origin?.rect.minX ?? 0) - ($0[0]*zoom-3)) < 2 } == true,
                  "It grows out of, and closes into, the selected address: \(origin.map { "\($0.rect)" } ?? "none") for \(selected ?? [])")
            // Escape closes it, though the page in it has the key focus and would keep the key.
            if let window = browser.window {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                     context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53).map(window.sendEvent)
                }
            }
            check(await waitUntil("Escape closes the map's Peek") { self.browser.peekTab == nil }, "Escape closes the map's Peek")
            _ = await waitUntil("The Peek finishes closing") { self.browser.peekGhosts.isEmpty && self.browser.peekCard == nil }
            browser.closePeek()
            browser.window?.makeKeyAndOrderFront(nil)
            _ = await waitUntil("Closing the Peek gives the page its focus back") { await self.value("return document.hasFocus()", in: menus.page) as? Bool == true }
        }

        // An amount in another currency: in the person's, to copy, to put the whole page in, or in any other.
        ExchangeRateStore.shared.use(ExchangeRates(base: "USD", rates: ["USD": 1, "EUR": 0.8, "GBP": 0.5, "PLN": 4], updated: Date()))
        let primary = browser.preferences.string(forKey: PrimaryCurrency.key)
        PrimaryCurrency.set("EUR", in: browser.preferences)
        defer { browser.preferences.set(primary, forKey: PrimaryCurrency.key) }
        let selectPrice = "const node = document.querySelector('#price').firstChild, range = document.createRange(); range.setStart(node, 8); range.setEnd(node, 14);" +
            "getSelection().removeAllRanges(); getSelection().addRange(range); return 0"
        _ = await value(selectPrice, in: menus.page)
        let price = await rightClick(center("#price"), in: menus.page, "a selected price")
        let amount = price?.items.first
        check(amount?.title == "€105.70", "A price leads the menu in the person's currency: \(titles(price))")
        check(titles(amount?.submenu) == ["Copy “€105.70”", "Replace on Page", "Other Currencies"], "Its menu: \(titles(amount?.submenu))")
        pasteboard.clearContents()
        choose("Copy “€105.70”", in: amount?.submenu)
        check(pasteboard.string(forType: .string) == "€105.70", "Copy copies the converted amount")
        let zloty = amount?.submenu?.items.last?.submenu?.items.first { $0.title.hasSuffix("(PLN)") }?.submenu
        if let zloty { zloty.delegate?.menuNeedsUpdate?(zloty) }
        check(zloty?.items.first?.title.contains("528.48") == true, "Another currency's submenu has the amount in it: \(titles(zloty))")
        choose("Replace on Page", in: amount?.submenu)
        let pagePrice = "return document.querySelector('#price').textContent"
        _ = await waitUntil("Replace on Page rewrites the page's amounts") {
            await self.value(pagePrice, in: menus.page) as? String == "Tickets €105.70, or a box for 2,000.00 EUR."
        }
        _ = await value(selectPrice.replacingOccurrences(of: "range.setEnd(node, 14)", with: "range.setEnd(node, 15)"), in: menus.page)
        let replaced = await rightClick(center("#price"), in: menus.page, "a replaced price")
        let checked = replaced?.items.first?.submenu?.items.first { $0.title == "Replace on Page" }
        check(checked?.state == .on, "A rewritten amount offers to put the page back: \(titles(replaced))")
        choose("Replace on Page", in: replaced?.items.first?.submenu)
        _ = await waitUntil("Unchecking it puts the page back") {
            await self.value(pagePrice, in: menus.page) as? String == "Tickets £66.06, or a box for 1,250.00 GBP."
        }

        // A misspelling: Chromium's spellchecker, its suggestions, and Writing Tools in a field.
        _ = await value("const field = document.querySelector('#field'); field.textContent = ''; field.focus();" +
                        "document.execCommand('insertText', false, 'Ths is wrng '); return 0", in: menus.page)
        try await Task.sleep(for: .seconds(1.5))
        let wordAt = "const node = document.querySelector('#field').firstChild, range = document.createRange(); range.setStart(node, 7); range.setEnd(node, 11);" +
            "const r = range.getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]"
        let spelling = await rightClick(wordAt, in: menus.page, "a misspelled word")
        check(titles(spelling).contains("wrong") && titles(spelling).contains("Learn Spelling") && titles(spelling).contains("Paste"),
              "A misspelled word's menu: \(titles(spelling))")
        if #available(macOS 15.2, *), let tools = NSMenuItem.writingToolsItems.first {
            check(titles(spelling).contains(tools.title), "With Writing Tools")
        }
        if let input = inputView(of: menus.page) {
            check(input.validRequestor(forSendType: .string, returnType: .string) != nil, "The field takes text back from Writing Tools and Services")
        } else { check(false, "Chromium's input view is there") }
        choose("wrong", in: spelling)
        _ = await waitUntil("Choosing a suggestion corrects the word") {
            (await self.value("return document.querySelector('#field').textContent", in: menus.page) as? String)?.hasPrefix("Ths is wrong") == true
        }

        // The page itself: Back, Forward and Reload.
        _ = await value("getSelection().removeAllRanges(); document.activeElement.blur(); return 0", in: menus.page)
        let blank = await rightClick(center("#blank"), in: menus.page, "the page")
        check(Array(titles(blank).prefix(3)) == ["Back", "Forward", "Reload"], "The page's menu: \(titles(blank))")

        // Inspect Element opens DevTools on the element.
        let inspect = await rightClick(center("#link"), in: menus.page, "a link to inspect")
        choose("Inspect Element", in: inspect)
        let selected = "const find = (root, selector) => [...root.querySelectorAll(selector)].concat(...[...root.querySelectorAll('*')].filter(n => n.shadowRoot).map(n => find(n.shadowRoot, selector)));" +
            "return find(document, 'li.selected, [role=treeitem][aria-selected=true]').map(n => n.textContent).join(' ')"
        _ = await waitUntil("Inspect Element selects the link in DevTools", 20) {
            guard let frontend = self.browser.devTools.clip.subviews.first as? RCBrowserView else { return false }
            return (await self.value(selected, in: frontend) as? String)?.replacingOccurrences(of: "\u{200B}", with: "").contains("example.com/linked") == true
        }
        browser.closeDevTools()
        _ = await waitUntil("DevTools close") { self.browser.devTools.shadow.isHidden && self.browser.devTools.tabID == nil }
        browser.presentContextMenu = { menu, point, view in menu.popUp(positioning: nil, at: point, in: view) }

        // Dialogs ask in Rise's sheets.
        guard let window = browser.window else { return }
        func sheet() async -> NSWindow? {
            _ = await waitUntil("The page's dialog shows as a sheet") { window.attachedSheet != nil }
            return window.attachedSheet
        }
        _ = await value("setTimeout(() => window.answer = confirm('Sure?')); return 0", in: menus.page)
        if let confirm = await sheet() {
            check(confirm.contentView?.subviews.contains { ($0 as? NSTextField)?.stringValue == "Sure?" } == true, "confirm() shows its message")
            window.endSheet(confirm, returnCode: .alertFirstButtonReturn)
            _ = await waitUntil("OK answers true") { await self.value("return window.answer", in: menus.page) as? Bool == true }
        }
        _ = await value("setTimeout(() => window.answer = prompt('Name?', 'Rise')); return 0", in: menus.page)
        if let prompt = await sheet() {
            window.endSheet(prompt, returnCode: .alertFirstButtonReturn)
            _ = await waitUntil("prompt() answers its text") { await self.value("return window.answer", in: menus.page) as? String == "Rise" }
        }
        // A page leaving while it asks takes its dialog with it.
        _ = await value("setTimeout(() => alert('Going')); return 0", in: menus.page)
        if await sheet() != nil {
            menus.page.load(try page("after", "<h1>After</h1>"))
            _ = await waitUntil("Navigating away closes the dialog") { window.attachedSheet == nil }
        }
        _ = await waitUntil("The next page loads") { menus.page.url?.lastPathComponent == "after.html" && !menus.page.isLoading }
        // Unsaved changes ask before a reload.
        menus.page.load(try page("unsaved", "<h1>Unsaved</h1><script>onbeforeunload = event => { event.preventDefault(); event.returnValue = '' }</script>"))
        _ = await waitUntil("The unsaved page loads") { menus.page.url?.lastPathComponent == "unsaved.html" && !menus.page.isLoading }
        _ = await value("document.body.click(); return 0", in: menus.page)
        menus.page.reload()
        if let leave = await sheet() {
            check(leave.contentView?.subviews.contains { ($0 as? NSTextField)?.stringValue == "Reload this page?" } == true, "Reloading asks first")
            window.endSheet(leave, returnCode: .alertSecondButtonReturn)
            try await Task.sleep(for: .milliseconds(500))
            check(window.attachedSheet == nil, "Cancel keeps the page")
        }
        _ = await value("onbeforeunload = null; return 0", in: menus.page)
        // A file input opens Rise's panel.
        let files = await open(URL(string: "\(site)/menus.html")!)
        _ = await value("const input = document.querySelector('#file'); input.addEventListener('cancel', () => window.cancelled = true); input.click(); return 0", in: files.page)
        if let panel = await sheet() {
            check(panel is NSOpenPanel, "A file input opens an open panel")
            window.endSheet(panel, returnCode: .cancel)
            _ = await waitUntil("Cancelling it tells the page") { await self.value("return window.cancelled === true", in: files.page) as? Bool == true }
        }

        // A pinch zooms the page in, and Rise knows it has.
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        if let input = inputView(of: files.page), let screen = NSScreen.screens.first {
            let center = input.convert(NSPoint(x: input.bounds.midX, y: input.bounds.midY), to: nil)
            func pinch(_ phase: Int64, _ amount: Double) -> NSEvent? {
                guard let event = CGEvent(source: nil), let gesture = CGEventType(rawValue: 29) else { return nil }
                event.type = gesture
                event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
                event.setDoubleValueField(CGEventField(rawValue: 113)!, value: amount)
                event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
                // Made without a window, its location reads as the window's own coordinates when
                // the window is given it, as the window server gives a real pinch.
                event.location = CGPoint(x: center.x, y: screen.frame.maxY-center.y)
                return NSEvent(cgEvent: event)
            }
            for (phase, amount) in [(Int64(1), 0.0), (2, 0.3), (2, 0.3), (4, 0)] {
                if let event = pinch(phase, amount) { window.sendEvent(event) }
                try await Task.sleep(for: .milliseconds(40))
            }
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            _ = await waitUntil("A pinch zooms the page in") { (await self.value("return visualViewport.scale", in: files.page) as? Double ?? 1) > 1.1 }
            _ = await waitUntil("And Rise knows the page is pinched in") { files.page.isMagnified }
            // A new page starts unpinched (a reload keeps the pinch, as in Chrome).
            files.page.load(URL(string: "\(site)/menus.html?again")!)
            _ = await waitUntil("A new page starts unpinched") { files.page.url?.query == "again" && !files.page.isLoading && !files.page.isMagnified }
        }
        if let input = inputView(of: files.page), let at = await value(center("#text"), in: files.page) as? [Double] {
            let point = files.page.view.convert(NSPoint(x: at[0] - 120, y: files.page.view.isFlipped ? at[1] : files.page.view.bounds.height-at[1]), to: nil)
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                input.quickLook(with: event)
            }
            _ = await waitUntil("A force click looks the word up") {
                NSApp.windows.contains { !before.contains(ObjectIdentifier($0)) && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            }
            window.makeKeyAndOrderFront(nil)
        }

        // Protected video, which Rise's floating window would show as black, floats in Chromium's
        // own picture in picture when its tab is left, and comes back with the tab.
        let video = await open(try page("protected", "<video src=clip.mp4 autoplay loop playsinline style='width:480px'></video>"))
        _ = await waitUntil("The protected page's video plays with sound") { video.page.isPlayingAudio }
        _ = await value("document.querySelector('video').dispatchEvent(new Event('encrypted')); return 0", in: video.page)
        try await Task.sleep(for: .milliseconds(500))
        _ = await open(try page("elsewhere", "<h1>Elsewhere</h1>"))
        _ = await waitUntil("Leaving its tab floats it in Chromium's picture in picture") {
            await self.value("return document.pictureInPictureElement?.tagName ?? null", in: video.page) as? String == "VIDEO"
        }
        browser.select(video.id)
        _ = await waitUntil("And it's back in the page with its tab") {
            await self.value("return document.pictureInPictureElement === null && !document.querySelector('video').paused", in: video.page) as? Bool == true
        }
    }

    /// Runs a script in a page that isn't a tab's, such as DevTools' own.
    func value(_ script: String, in view: RCBrowserView) async -> Any? {
        await withCheckedContinuation { done in view.evaluateFunctionBody(script, arguments: [:], frame: nil, world: nil) { value, _ in done.resume(returning: value) } }
    }

    /// Windows that keep their opener, site search learning, notifications, merge checks,
    /// DevTools, the JavaScript Console and View Source.
    func riseFeatures() async throws {
        check(ChromiumEngine.isRunning, "Chromium is running")

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
        if await waitUntil("Rise asks first", 10, { self.browser.permissionCoordinator.isShowingPrompt }) {
            browser.permissionCoordinator.resolve(true)
            _ = await waitUntil("And the site may notify") { await self.value("return window.answer", in: notifying.page) as? String == "granted" }
            if ChromiumEngine.showsSiteNotifications {
                notifying.page.reload()
                _ = await waitUntil("Chrome keeps it, to show the site's notifications later") {
                    await self.value("return Notification.permission", in: notifying.page) as? String == "granted"
                }
            }
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
            let selectedTab = "const UI = await import('./ui/legacy/legacy.js'); return UI.InspectorView.InspectorView.instance().tabbedPane.selectedTabId"
            _ = await waitUntil("On the Elements panel", 10) { await self.value(selectedTab, in: frontend) as? String == "elements" }
            let picking = "const UI = await import('./ui/legacy/legacy.js'); return UI.ActionRegistry.ActionRegistry.instance().getAction('elements.toggle-element-search').toggled()"
            _ = await waitUntil("Ready to select an element", 10) { await self.value(picking, in: frontend) as? Bool == true }
            // Their menus, close button, device mode and files: python3 scripts/test-chromium-live.py devtools.
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
            _ = await waitUntil("rise://settings opens, on its first section", 15) {
                settings.page.url?.absoluteString == "rise://settings/privacy" && !settings.page.isLoading
            }
            _ = await waitUntil("With Chrome's settings in it", 15) {
                await self.value("return !!document.querySelector('settings-ui')", in: settings.page) as? Bool == true
            }
            settings.load(URL(string: "rise://settings/privacy")!)
            _ = await waitUntil("And its pages") { settings.page.url?.absoluteString == "rise://settings/privacy" && !settings.page.isLoading }
            browser.showSettings()
            check(browser.selectedID == settings.id && browser.tabs.filter({ $0.page.url?.scheme == "rise" }).count == 1, "⌘, goes back to the settings already open")
        }
        // In Rise's words, without the parts of Chrome Rise's pages don't use.
        let shown = """
        let text = '';
        const walk = node => {
          if (node.nodeType === Node.TEXT_NODE) { text += node.textContent + ' '; return; }
          if (node.nodeType === Node.ELEMENT_NODE && node.checkVisibility && !node.checkVisibility()) return;
          if (node.shadowRoot) walk(node.shadowRoot);
          node.childNodes.forEach(walk);
        };
        walk(document.body);
        return text.replace(/\\s+/g, ' ');
        """
        if let settings = browser.tabs.first(where: { $0.page.url?.scheme == "rise" }) {
            for path in ["", "/privacy", "/languages", "/system", "/help"] {
                settings.load(URL(string: "rise://settings" + path)!)
                let expected = "rise://settings" + (path.isEmpty ? "/privacy" : path)
                _ = await waitUntil("rise://settings\(path) loads") { settings.page.url?.absoluteString == expected && !settings.page.isLoading }
                try await Task.sleep(for: .milliseconds(1200))
                // Where Chromium is the open-source project Rise is made from, it keeps its name.
                let text = (await value(shown, in: settings.page) as? String ?? "")
                    .replacingOccurrences(of: "The Chromium Authors", with: "").replacingOccurrences(of: "the Chromium open source project", with: "")
                var excerpt = ""
                if let found = text.range(of: "Chromium") {
                    let from = text.index(found.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                    let to = text.index(found.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                    excerpt = ": …" + String(text[from..<to])
                }
                check(excerpt.isEmpty && !text.isEmpty, "rise://settings\(path) says Rise, not Chromium\(excerpt)")
                if path == "/help" {
                    check(!text.contains("checking for updates"), "No update status from Chrome's updater")
                }
                if path.isEmpty {
                    check(!text.contains("You and Google") && !text.contains("Autofill") && !text.contains("Extensions"), "Without Google sign-in, autofill or extensions")
                }
            }
            // Links to Chrome pages Rise's pages can't show open nothing.
            let count = browser.tabs.count
            _ = await value("window.open('chrome://history'); return 0", in: settings.page)
            try await Task.sleep(for: .milliseconds(800))
            check(browser.tabs.count == count, "A link to a page Rise can't show opens no blank tab")
            // Chrome's extensions page opens as Rise's.
            _ = await value("window.open('chrome://extensions'); return 0", in: settings.page)
            _ = await waitUntil("Settings' link to extensions opens rise://extensions") {
                self.browser.selectedTab?.page.url?.absoluteString.hasPrefix("rise://extensions") == true
            }
            if let extensionsTab = browser.selectedTab, extensionsTab.id != settings.id { browser.closeTab(extensionsTab.id); browser.select(settings.id) }

            // Rise searches with the engine chosen in Chrome's Search engine section.
            let engines = "const {sendWithPromise} = await import('chrome://resources/js/cr.js');" +
                "const list = await sendWithPromise('getSearchEnginesList');"
            func chooseEngine(_ pattern: String) async -> String? {
                await value(engines + "const engine = list.defaults.find(e => /\(pattern)/.test(e.name)); if (!engine) return null;" +
                            "chrome.send('setDefaultSearchEngine', [engine.id, 1, null]); return engine.name", in: settings.page) as? String
            }
            let original = browser.searchProvider.title
            if let chosen = await chooseEngine("DuckDuckGo") {
                _ = await waitUntil("Rise searches with \(chosen) once it's chosen in settings") {
                    self.browser.searchProvider.title == chosen && self.browser.searchProvider.searchURL("rise")?.host?.contains("duckduckgo") == true
                }
                check(!browser.searchProvider.isGoogle, "Without Google's suggestions")
                _ = await chooseEngine(original)
                _ = await waitUntil("And with \(original) again") { self.browser.searchProvider.title == original }
            } else { check(false, "Chrome offers DuckDuckGo to choose") }

            // Rise's own settings are among Chrome's: in sections of their own, and in Chrome's.
            for (path, label) in [("/tabs", "Gmail preview category"), ("/assistant", "Reasoning effort"), ("/appearance", "The colours of Rise"),
                                  ("/system", "Simulated full screen"), ("/system", "Page captures folder"), ("/privacy", "Clear address bar history")] {
                settings.load(URL(string: "rise://settings" + path)!)
                _ = await waitUntil("rise://settings\(path) shows Rise's “\(label)”", 15) {
                    guard !settings.page.isLoading else { return false }
                    return (await self.value(shown, in: settings.page) as? String)?.contains(label) == true
                }
            }
            // Appearance leaves out the rows for Chrome's own window, and keeps the ones for pages.
            settings.load(URL(string: "rise://settings/appearance")!)
            _ = await waitUntil("Appearance shows fonts and zoom, not Chrome's toolbar, tab strip, mode or quitting", 15) {
                guard !settings.page.isLoading, let text = await self.value(shown, in: settings.page) as? String else { return false }
                return text.contains("Font size") && text.contains("Page zoom") && text.contains("The colours of Rise")
                    && !["Customize your toolbar", "Mode", "Tab position", "Show tab search button", "Side panel position",
                         "Show warning before quitting"].contains { text.contains($0) }
            }
            // Changing one there changes Rise.
            let deep = "const find = (root, selector) => root.querySelector(selector) ||" +
                " [...root.querySelectorAll('*')].map(node => node.shadowRoot && find(node.shadowRoot, selector)).find(Boolean);"
            settings.load(URL(string: "rise://settings/tabs")!)
            let hidden = browser.hidesNotificationCounts
            _ = await waitUntil("The Tabs section's toggle is there") {
                await self.value(deep + "const toggle = find(document, 'cr-toggle[data-key=hideNotificationCounts]'); toggle?.click(); return !!toggle", in: settings.page) as? Bool == true
            }
            _ = await waitUntil("Turning it off in settings turns it off in Rise") { self.browser.hidesNotificationCounts != hidden }
            browser.setHidesNotificationCounts(hidden)
            settings.load(URL(string: "rise://settings/assistant")!)
            let provider = browser.aiProvider
            _ = await waitUntil("Choosing another AI provider in settings chooses it in Rise") {
                _ = await self.value(deep + "const select = find(document, 'select[data-key=aiProvider]'); if (!select) return false;" +
                                     "select.selectedIndex = (select.selectedIndex + 1) % select.options.length; select.dispatchEvent(new Event('change')); return true",
                                     in: settings.page)
                return self.browser.aiProvider != provider
            }
            // OpenAI shows its key, model and effort, and a model typed there is the one Rise asks.
            browser.selectAIProvider(.openAI)
            settings.load(URL(string: "rise://settings/assistant")!)
            _ = await waitUntil("OpenAI shows its API key, model and reasoning effort") {
                await self.value(deep + "const model = find(document, 'cr-input[data-key=aiModel]'), effort = find(document, 'select[data-key=aiEffort]');" +
                                 "return !!find(document, 'cr-input[data-key=aiKey][type=password]') && model?.value === 'gpt-6-luna' && effort?.value === 'low'",
                                 in: settings.page) as? Bool == true
            }
            _ = await value(deep + "const model = find(document, 'cr-input[data-key=aiModel]'); model.value = 'gpt-6-sol';" +
                            "model.dispatchEvent(new CustomEvent('change')); return true", in: settings.page)
            _ = await waitUntil("A model typed in settings is the one Rise asks for") { self.browser.modelChoice.model == "gpt-6-sol" }
            browser.setAIModel("", for: .openAI)
            browser.selectAIProvider(provider)
            // The site controls' ⋯ opens them, from any page.
            _ = await open(try page("plain", "<h1>Plain</h1>"))
            browser.moreSiteControls()
            check(browser.selectedID == settings.id, "The site controls' ⋯ opens Rise's settings")
        }

        // Links and images drag out of pages, carrying their address or picture.
        let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 160, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: picture)
        NSColor.systemTeal.setFill(); NSRect(x: 0, y: 0, width: 240, height: 160).fill()
        NSGraphicsContext.restoreGraphicsState()
        try picture.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("picture.png"))
        try await menusAndDialogs()

        // macOS runs one drag at a time, and Chromium starts the next only once it hears the last
        // one ended, at the mouse's real release, which window events can't give; so one drag here.
        let dragPage = try page("drag", "<a id=l href='https://example.com/dragged'><img src=picture.png width=240></a>")
        let dragging = browser.addTab(url: dragPage)
        _ = await waitUntil("The drag page loads") {
            guard dragging.page.url == dragPage, !dragging.page.isLoading else { return false }
            return await self.value("return document.querySelector('img').complete", in: dragging.page) as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(500))
        let inFront = browser.window?.isKeyWindow == true && NSApp.isActive
        let dragged = try await drag("#l img", in: dragging.page)
        check(dragged.contains(.URL) || dragged.contains(NSPasteboard.PasteboardType("public.url")),
              "Dragging a link out carries its address\(inFront ? "" : " (Rise's window wasn't in front)")")
        check(dragged.contains(.tiff) || dragged.contains(.png) || dragged.contains(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
              || dragged.contains(NSPasteboard.PasteboardType("NSPromiseContentsPboardType")), "And an image, its picture: \(dragged.map(\.rawValue).filter { !$0.hasPrefix("org.chromium") }.prefix(8))")

        // A site can't open them.
        let sneaky = await open(try page("sneaky", "<a id=s href='chrome://settings'>Settings</a>"))
        _ = await value("location.href = 'chrome://settings'; return 0", in: sneaky.page)
        try await Task.sleep(for: .milliseconds(800))
        check(sneaky.page.url?.lastPathComponent == "sneaky.html", "A site can't open settings: \(sneaky.page.url?.absoluteString ?? "-")")
    }

    /// Pressing on `selector` in `page` and dragging it a little away, with the window's own mouse
    /// events: the drag macOS starts carries what was dragged, for whatever it's dropped on.
    func drag(_ selector: String, in page: WebPage) async throws -> [NSPasteboard.PasteboardType] {
        let script = "const r = document.querySelector('\(selector)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]"
        let found: Any? = await value(script, in: page)
        guard let window = browser.window, let rect = found as? [Double] else { return [] }
        let view = page.view
        let inView = NSPoint(x: rect[0], y: view.isFlipped ? rect[1] : view.bounds.height-rect[1])
        let start = view.convert(inView, to: nil)
        NSPasteboard(name: .drag).clearContents()
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                window.sendEvent(event)
            }
        }
        send(.leftMouseDown, start)
        try await Task.sleep(for: .milliseconds(80))
        for step in 1...12 {
            send(.leftMouseDragged, NSPoint(x: start.x+CGFloat(step)*8, y: start.y-CGFloat(step)*3))
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(300))
        let types = NSPasteboard(name: .drag).types ?? []
        send(.leftMouseUp, NSPoint(x: start.x+96, y: start.y-36))
        try await Task.sleep(for: .milliseconds(200))
        return types
    }

    func checks() async throws {
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let video = "<video src=clip.mp4 autoplay loop playsinline style='width:480px'></video>"

        // The tab's sound, and its play button pausing and resuming the page's media.
        let media = await open(try page("media", "<h1>Media</h1>\(video)"))
        check(media.page is ChromiumPage, "Tabs open in Chromium")
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
        // Skipping passes every match on screen; stepping after scrolling away starts from what's on screen.
        func rows(_ count: Int) -> String { String(repeating: "<div style='line-height:16px'>apple</div>", count: count) }
        let gap = "<div style='height:3000px'></div>"
        let long = await open(try page("skips", rows(20) + gap + rows(20) + gap + rows(5) + gap))
        browser.showFind(); browser.findBar.input.stringValue = "apple"; browser.findBar.run(.restart)
        _ = await waitUntil("Find counts the long page's matches") { browser.findBar.count.stringValue == "1/45" }
        browser.skipToNextMatch()
        _ = await waitUntil("⌥⌘G skips the matches on screen, to the first below it") { browser.findBar.count.stringValue == "21/45" }
        browser.skipToNextMatch()
        _ = await waitUntil("And again, to the next cluster (\(browser.findBar.count.stringValue))") { browser.findBar.count.stringValue == "41/45" }
        browser.skipToPreviousMatch()
        _ = await waitUntil("⌥⇧⌘G goes back to the last match above the screen (\(browser.findBar.count.stringValue))") { browser.findBar.count.stringValue == "40/45" }
        _ = await value("scrollTo(0, 0)", in: long.page)
        browser.findNext()
        _ = await waitUntil("After scrolling away, Find Next starts from what's on screen") { browser.findBar.count.stringValue == "1/45" }
        browser.hideFind(); browser.closeTab(long.id)

        // A link already open in another tab goes to that tab; ⌘-click still opens a new one.
        let already = await open(try page("already-open", "<h1>Already open</h1>"))
        let alreadyURL = already.page.url ?? URL(string: "about:blank")!
        let linking = await open(try page("linking", "<a id=go href='\(alreadyURL.absoluteString)' style='font-size:48px'>Go there</a>"))
        NSApp.activate(ignoringOtherApps: true); browser.window?.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(400))
        // A click on a window that isn't in front only brings it forward.
        let linkInFront = browser.window?.isKeyWindow == true && NSApp.isActive
        let notInFront = linkInFront ? "" : " (Rise's window wasn't in front)"
        await leftClick(center("#go"), in: linking.page)
        _ = await waitUntil("Clicking a link open in another tab goes to that tab\(notInFront)") { browser.selectedID == already.id }
        check(linking.page.url?.lastPathComponent == "linking.html", "And leaves the page it was clicked on as it was: \(linking.page.url?.lastPathComponent ?? "")")
        browser.select(linking.id); try await Task.sleep(for: .milliseconds(300))
        let count = browser.tabs.count
        await leftClick(center("#go"), in: linking.page, modifiers: .command)
        _ = await waitUntil("⌘-click still opens it in a new tab\(notInFront)") { browser.tabs.count == count+1 }
        check(browser.selectedID == linking.id, "Behind the current one")
        browser.openTabLinks.setEnabled(false); browser.update(); try await Task.sleep(for: .milliseconds(300))
        await leftClick(center("#go"), in: linking.page)
        _ = await waitUntil("Turned off in rise://settings, the link opens in its page as usual\(notInFront)") { linking.page.url == alreadyURL }
        browser.openTabLinks.setEnabled(true)
        for tab in browser.tabs where tab.id != linking.id && [alreadyURL, linking.page.url].contains(tab.page.url ?? tab.url) { browser.closeTab(tab.id) }
        browser.closeTab(linking.id)

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
        _ = await waitUntil("Rise asks before the site gets the camera") { browser.permissionCoordinator.isShowingPrompt }
        browser.permissionCoordinator.resolve(true)
        _ = await waitUntil("Allowing gives the site the camera") { await value("return window.camera", in: ask.page) as? String == "granted 1" }
        if ChromiumEngine.keepsSitePermissions {
            // As Chrome keeps it: a page checking first, as Meet does, sees it allowed after a reload.
            let state = "return (await navigator.permissions.query({name: 'camera'})).state"
            ask.page.reload()
            _ = await waitUntil("The camera stays allowed for the site") { await value(state, in: ask.page) as? String == "granted" }
            if let origin = SitePermissions.origin(ask.page.url) {
                browser.setSitePermission(.ask, for: .camera, origin: origin)
                _ = await waitUntil("Set back to ask in Rise, the site has to ask again") { await value(state, in: ask.page) as? String == "prompt" }
            }
        }
        _ = await value("""
            navigator.geolocation.getCurrentPosition(() => window.place = 'granted', e => window.place = 'denied ' + e.code)
            """, in: ask.page)
        _ = await waitUntil("Rise asks before the site gets the location") { browser.permissionCoordinator.isShowingPrompt }
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

        // Last, as nothing after it can count on Rise's window: AirDrop's panel is ShareKit's, drawn by
        // another process, so only a real click on its Cancel dismisses it cleanly; closing its window
        // here leaves ShareKit's dimming, and later sheets, over Rise.
        try await airDropPanel()
    }

    /// The link menu's AirDrop sends the link straight to AirDrop's panel, over Rise's window.
    func airDropPanel() async throws {
        let shared = await open(try page("shared", "<p style='font-size:20px'><a id=link href='https://example.com/linked'>A link to send</a></p>"))
        let menu = await rightClick(center("#link"), in: shared.page, "a link to send")
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        func added() -> [NSWindow] { NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible } }
        choose("AirDrop", in: menu)
        let opened = await waitUntil("AirDrop opens its panel") { added().contains { $0.title == "AirDrop" } }
        check(opened && added().allSatisfy { $0.frame == self.browser.window?.frame }, "AirDrop opens its panel, over Rise's window: \(added().map { "\(type(of: $0)) “\($0.title)” \($0.frame)" })")
        added().forEach { $0.close() }
    }
}
