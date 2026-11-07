// ⌘F, ⌘S and ⌘Z on real sites with real key presses: who handles each one, what the page bar says,
// what a second press does, and whether Rise's find can read the page.
// Needs the network, and takes the keyboard while it runs. Run:
// RISE_REALKEY=<path to a key press tool> python3 scripts/test-chromium-live.py Tests/Live/ChromiumFindSitesChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumFindSitesMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+420) { print("FAIL Find sites checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumFindSitesRun()
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
        _ = folder
    }
}

/// A site, how to tell it's ready, where its keyboard goes, and what its own find looks like.
struct FindSite {
    let name: String
    let url: String
    let ready: String
    /// Where a click puts the site's keyboard, if not where it starts.
    let focus: String
    let ownFind: String?
    let word: String
}

@MainActor final class ChromiumFindSitesRun: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    var failures = 0
    let realKey = ProcessInfo.processInfo.environment["RISE_REALKEY"]!
    let sites: [FindSite] = [
        FindSite(name: "Wikipedia", url: "https://en.wikipedia.org/wiki/Web_browser", ready: "return !!document.querySelector('#bodyContent')",
                 focus: "", ownFind: nil, word: "browser"),
        FindSite(name: "Example", url: "https://example.com/", ready: "return document.readyState == 'complete'", focus: "", ownFind: nil, word: "example"),
        FindSite(name: "tldraw", url: "https://www.tldraw.com/", ready: "return !!document.querySelector('.tl-container, .tl-canvas')", focus: "", ownFind: nil, word: "tldraw"),
        FindSite(name: "Photopea", url: "https://www.photopea.com/", ready: "return document.readyState == 'complete'", focus: "", ownFind: nil, word: "photopea"),
        FindSite(name: "Google Docs", url: "https://docs.google.com/document/d/195j9eDD3ccgjQRttHhJPymLJUCOUjs-jmwTrekvdjFE/edit",
                 ready: "return !!document.querySelector('.kix-appview-editor')", focus: "",
                 ownFind: ".docs-findinput-input, .docs-findinput-container input, input[aria-label*='Find' i]", word: "the"),
        FindSite(name: "Google Sheets", url: "https://docs.google.com/spreadsheets/d/1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms/edit",
                 ready: "return !!document.querySelector('#waffle-grid-container, .grid-container')", focus: "",
                 ownFind: ".docs-findinput-input, .waffle-find-input, input[aria-label*='Find' i]", word: "Alexandra"),
        FindSite(name: "Google Slides", url: "https://docs.google.com/presentation/d/1EAYk18WDjIG-zp_0vLm3CsfQh_i8eXc67Jo2O9C6Vuc/edit",
                 ready: "return !!document.querySelector('.punch-viewer-container, #workspace, .punch-filmstrip-scroll')", focus: "",
                 ownFind: ".docs-findinput-input, input[aria-label*='Find' i]", word: "the"),
        FindSite(name: "Monaco", url: "https://microsoft.github.io/monaco-editor/playground.html",
                 ready: "return !!document.querySelector('.monaco-editor textarea, .monaco-editor .native-edit-context')",
                 focus: ".monaco-editor .view-lines",
                 ownFind: ".find-widget.visible", word: "monaco"),
        FindSite(name: "CodeMirror", url: "https://codemirror.net/5/demo/search.html",
                 ready: "return !!document.querySelector('.CodeMirror-lines')", focus: ".CodeMirror-lines",
                 ownFind: ".CodeMirror-dialog", word: "codemirror"),
        FindSite(name: "Excalidraw", url: "https://excalidraw.com/",
                 ready: "return !!document.querySelector('canvas.interactive, .excalidraw canvas')", focus: "",
                 ownFind: ".layer-ui__search, .layer-ui__search-header input, input[placeholder*='Find' i]", word: "excalidraw"),
        FindSite(name: "GitHub file", url: "https://github.com/torvalds/linux/blob/master/README",
                 ready: "return !!document.querySelector('#read-only-cursor-text-area, .react-code-lines, article')", focus: "",
                 ownFind: "#code-find-bar, [data-testid=code-find-bar], #find-in-code-input", word: "linux"),
        FindSite(name: "Discourse", url: "https://meta.discourse.org/latest",
                 ready: "return !!document.querySelector('.topic-post, #topic-title, .topic-list, main')", focus: "",
                 ownFind: ".search-menu input, #search-term", word: "discourse"),
    ]

    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description); if !condition { failures += 1 }
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        await page.evaluate(script, arguments: [:], world: nil)
    }
    /// A real key press, only once this window has the keyboard, so it can't land in another app.
    @discardableResult func press(_ code: Int, _ modifiers: String = "cmd") async -> Bool {
        let end = Date().addingTimeInterval(4)
        while !(NSApp.isActive && browser.window?.isKeyWindow == true) {
            if Date() > end { check(false, "This window lost the keyboard, so a key wasn't sent"); return false }
            NSApp.activate(ignoringOtherApps: true); browser.window?.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(100))
        }
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: realKey)
        tool.arguments = [String(code), modifiers]
        try? tool.run()
        while tool.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
        return true
    }
    func settled(_ wait: Int = 900) async { try? await Task.sleep(for: .milliseconds(wait)) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await run()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    /// A real click where the site's keyboard goes, as you'd click into an editor.
    func clickFocus(_ site: FindSite, _ page: WebPage) async {
        guard !site.focus.isEmpty else { return }
        let point = await value("const e = document.querySelector('\(site.focus)'); if (!e) return null; const r = e.getBoundingClientRect(); return [r.x+Math.min(r.width/2, 60), r.y+Math.min(r.height/2, 30)]", in: page) as? [NSNumber]
        guard let point, point.count == 2, let window = browser.window else { print("  nowhere to click"); return }
        let view = page.view
        let inView = NSPoint(x: point[0].doubleValue, y: view.isFlipped ? point[1].doubleValue : view.bounds.height-point[1].doubleValue)
        let location = view.convert(inView, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.sendEvent(event) }
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(200))
        print("  clicked: focus is in \(await value("const a = document.activeElement; return a && (a.className || a.tagName)", in: page) ?? "nothing")")
    }
    func ownFindOpen(_ site: FindSite, _ page: WebPage) async -> Bool {
        guard let selector = site.ownFind else { return false }
        let escaped = selector.replacingOccurrences(of: "\"", with: "\\\"")
        return await value("const b = document.querySelector(\"\(escaped)\"); return !!b && (b.offsetParent !== null || getComputedStyle(b).display != 'none') && b.getBoundingClientRect().width > 0", in: page) as? Bool == true
    }
    func run() async {
        browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!).appendingPathComponent("session.json"),
                                    restore: false, preferences: UserDefaults(suiteName: "rise-find-sites-\(UUID())")!)
        browser.window?.setContentSize(NSSize(width: 1300, height: 860)); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        _ = browser.addTab(url: URL(string: "about:blank")!)
        let only = ProcessInfo.processInfo.environment["RISE_SITES"]?.split(separator: ",").map(String.init)
        for site in sites where only?.contains(site.name) ?? true { await visit(site) }
    }
    func visit(_ site: FindSite) async {
        print("== \(site.name)")
        let tab = browser.addTab(url: URL(string: site.url)!)
        let page = tab.page
        browser.select(tab.id)
        var end = Date().addingTimeInterval(45), ready = false
        while Date() < end, !ready {
            ready = await value(site.ready, in: page) as? Bool == true
            if !ready { try? await Task.sleep(for: .milliseconds(200)) }
        }
        check(ready, "\(site.name) loads")
        guard ready else {
            let state = await value("return document.readyState+' '+document.querySelectorAll('*').length+' '+(document.body ? document.body.innerHTML.slice(0, 160) : 'no body')", in: page)
            print("  at \(page.url?.absoluteString ?? "nowhere"): \(page.title ?? "untitled"); script says: \(state ?? "nothing")")
            return
        }
        try? await Task.sleep(for: .seconds(3))
        browser.window?.makeFirstResponder(page.view)
        end = Date().addingTimeInterval(8)
        while Date() < end, await value("return document.hasFocus()", in: page) as? Bool != true { try? await Task.sleep(for: .milliseconds(100)) }

        let text = await value("return (document.body && document.body.innerText || '').length", in: page) as? Int ?? -1
        let canvases = await value("return document.querySelectorAll('canvas').length", in: page) as? Int ?? -1
        let readable = await PageFind.find(site.word, direction: .restart, in: page)
        await PageFind.clear(page, selectingCurrent: false)
        let svgText = await value("return document.querySelectorAll('svg text').length", in: page) as? Int ?? -1
        print("  page: text \(text) chars, \(canvases) canvases, \(svgText) svg texts; Rise's find for '\(site.word)': \(readable.count.map(String.init) ?? "unknown") matches; drawn: \(BrowserController.drawsItsOwnText(page.url))")
        await clickFocus(site, page)
        try? await Task.sleep(for: .milliseconds(500))

        _ = await value("window.__keys = []; for (const t of [window]) t.addEventListener('keydown', e => { if (e.metaKey && e.key != 'Meta') __keys.push(e.key+(e.defaultPrevented ? ' kept' : ' free')+' in '+(document.activeElement && (document.activeElement.className || document.activeElement.tagName))) }); return true", in: page)
        // ⌘F, then again while the bar says so.
        await press(3)
        await settled()
        var own = await ownFindOpen(site, page)
        print("  ⌘F once:  own find \(own), Rise's bar \(browser.findBar.isPresented), notice \(browser.selectedBar.notice?.text ?? "none")")
        print("  the page saw: \(await value("return __keys", in: page) as? [String] ?? [])")
        let handledOnce = own || browser.findBar.isPresented || browser.selectedBar.notice != nil
        check(handledOnce, "\(site.name): ⌘F does something you can see")
        await press(3)
        await settled()
        own = await ownFindOpen(site, page)
        print("  ⌘F twice: own find \(own), Rise's bar \(browser.findBar.isPresented) saying '\(browser.findBar.findPlaceholder.stringValue)', notice \(browser.selectedBar.notice?.text ?? "none")")
        // Whoever has it first, a second press gets you Rise's find, and it's honest about what it can read.
        check(browser.findBar.isPresented, "\(site.name): ⌘F twice opens Rise's find")
        check((browser.findBar.findPlaceholder.stringValue == "Can't search this document") == BrowserController.drawsItsOwnText(page.url), "\(site.name): the find bar's words suit the page")
        if browser.findBar.isPresented { browser.hideFind() }
        browser.selectedBar.hideNotice(); browser.shortcutAgain = nil
        await press(53, "none")
        await settled(300)
        browser.window?.makeFirstResponder(page.view)
        await clickFocus(site, page)
        await settled(300)

        // ⌘S and ⌘Z: the page's, and neither should do anything of Rise's by surprise.
        let sidebar = browser.sidebarVisible, order = browser.tabs.map(\.id)
        await press(1)
        await settled(600)
        print("  ⌘S: notice \(browser.selectedBar.notice?.text ?? "none"), sheet \(browser.window?.attachedSheet != nil)")
        check(browser.sidebarVisible == sidebar, "\(site.name): ⌘S leaves the sidebar alone")
        if let sheet = browser.window?.attachedSheet { browser.window?.endSheet(sheet) }
        await press(53, "none")
        browser.selectedBar.hideNotice(); browser.shortcutAgain = nil
        browser.window?.makeFirstResponder(page.view)
        await press(6)
        await settled(500)
        print("  ⌘Z: notice \(browser.selectedBar.notice?.text ?? "none")")
        check(browser.selectedBar.notice == nil && browser.tabs.map(\.id) == order, "\(site.name): ⌘Z with nothing of Rise's to undo says nothing")
        browser.selectedBar.hideNotice(); browser.shortcutAgain = nil
        await switchingBack(to: tab, site)
    }
    /// ⌘F just after coming back to the tab, when a page just shown can miss a key press.
    func switchingBack(to tab: BrowserTab, _ site: FindSite) async {
        let other = browser.tabs.first { $0.id != tab.id }!
        for delay in [0, 50, 150, 400] {
            browser.select(other.id)
            try? await Task.sleep(for: .milliseconds(800))
            browser.select(tab.id)
            browser.window?.makeFirstResponder(tab.page.view)
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            let before = await value("return __keys.length", in: tab.page) as? Int ?? 0
            await press(3)
            await settled(700)
            let bar = browser.findBar.isPresented, notice = browser.selectedBar.notice?.text
            let got = (await value("return __keys.length", in: tab.page) as? Int ?? 0) > before
            print("  back, ⌘F after \(delay)ms: page got it \(got), Rise's bar \(bar), notice \(notice ?? "none"), pending \(browser.pendingPageKey != nil)")
            check(bar || notice != nil, "\(site.name): ⌘F \(delay)ms after coming back does something you can see")
            check(browser.pendingPageKey == nil, "\(site.name): and nothing's left waiting")
            if bar { browser.hideFind() }
            browser.selectedBar.hideNotice(); browser.shortcutAgain = nil
            await press(53, "none")
            await settled(300)
        }
    }
}
