import AppKit
import WebKit
@testable import Rise

/// Drives page fullscreen in a real Rise window: local fixtures for each path through the
/// simulated fullscreen script (top layer, legacy API, shadow DOM, video, frames, removal,
/// a site acting up, switching modes), then real sites' own fullscreen buttons.
/// RISE_FULLSCREEN_FRAMES saves screenshots; RISE_FULLSCREEN_ONLY runs the named cases.
@main @MainActor struct FullscreenBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = FullscreenVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}

/// Collects each frame as it loads, so a script can run inside a cross-origin frame.
final class FrameCollector: NSObject, WKScriptMessageHandler {
    var frames: [String: WKFrameInfo] = [:]
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let href = message.body as? String { frames[href] = message.frameInfo }
    }
}

@MainActor final class FullscreenVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    var failures = 0, passes = 0
    var servers: [Process] = []
    let frames = ProcessInfo.processInfo.environment["RISE_FULLSCREEN_FRAMES"].map { URL(fileURLWithPath: $0) }
    let only = ProcessInfo.processInfo.environment["RISE_FULLSCREEN_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    let collector = FrameCollector()
    let fixturePort = 8871, framePort = 8872

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "  ✓ \(message)" : "  ✗ \(message)"); if condition { passes += 1 } else { failures += 1 }
    }
    func capture(_ name: String) {
        guard let frames, let window = browser.window else { return }
        let path = frames.appendingPathComponent("\(name).png").path
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? process.run(); process.waitUntilExit()
    }
    func key(_ characters: String, code: UInt16) {
        let window = browser.window!
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
            NSApp.postEvent(event, atStart: false)
        }
    }
    func escape() { key("\u{1b}", code: 53) }
    func wait(_ milliseconds: Int) async { try? await Task.sleep(for: .milliseconds(milliseconds)) }

    @discardableResult func js(_ web: WKWebView, _ source: String, frame: WKFrameInfo? = nil) async -> Any? {
        do {
            if let frame { return try await web.evaluateJavaScript(source, in: frame, contentWorld: .page) }
            return try await web.evaluateJavaScript(source)
        } catch { print("    (script error: \(error.localizedDescription))"); return nil }
    }
    func string(_ web: WKWebView, _ source: String, frame: WKFrameInfo? = nil) async -> String {
        let value = await js(web, source, frame: frame)
        if let value = value as? String { return value }
        return value.map { "\($0)" } ?? "nil"
    }
    func json(_ web: WKWebView, _ source: String, frame: WKFrameInfo? = nil) async -> [String: Any] {
        let text = await string(web, "JSON.stringify((() => { \(source) })())", frame: frame)
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    func waitFor(_ web: WKWebView, _ condition: String, frame: WKFrameInfo? = nil, timeout: Double = 20) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if await js(web, "!!(\(condition))", frame: frame) as? Bool == true { return true }
            await wait(200)
        }
        return false
    }
    func waitForNative(_ web: WKWebView, _ state: WKWebView.FullscreenState, timeout: Double = 5) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if web.fullscreenState == state { return true }
            await wait(100)
        }
        return false
    }
    func load(_ url: String) async -> WKWebView {
        let tab = browser.addTab(url: URL(string: url)!)
        let web = tab.webView
        await wait(400)
        let start = Date()
        while (web.isLoading || web.url == nil) && Date().timeIntervalSince(start) < 25 { await wait(100) }
        _ = await waitFor(web, "document.readyState === 'complete' && window.events", timeout: 10)
        await wait(300)
        return web
    }
    /// The page's simulated fullscreen, measured from the top document.
    func pageState(_ web: WKWebView, frame: WKFrameInfo? = nil) async -> [String: Any] {
        await json(web, """
        const deep = (sel, root = document) => { const hit = root.querySelector(sel); if (hit) return hit; for (const el of root.querySelectorAll('*')) if (el.shadowRoot) { const found = deep(sel, el.shadowRoot); if (found) return found; } return null; };
        const fe = document.fullscreenElement, pinned = deep('[data-rise-fullscreen]');
        const describe = el => el ? el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') : null;
        const rect = pinned ? pinned.getBoundingClientRect() : null;
        const covers = !!rect && Math.abs(rect.left) <= 2 && Math.abs(rect.top) <= 2 && Math.abs(rect.width - innerWidth) <= 2 && Math.abs(rect.height - innerHeight) <= 2;
        const hit = pinned ? document.elementFromPoint(innerWidth / 2, innerHeight - 30) : null;
        return { fe: describe(fe), pinned: describe(pinned), covers, rect: rect ? [rect.left, rect.top, rect.width, rect.height].map(Math.round).join(',') : null,
                 onTop: !!hit && (hit === pinned || pinned.contains(hit)), hit: describe(hit), rise: window.__riseFullscreen?.state ?? null,
                 attributes: document.querySelectorAll('[data-rise-fullscreen], [data-rise-fullscreen-ancestor], [data-rise-fullscreen-document]').length,
                 viewport: innerWidth + 'x' + innerHeight };
        """, frame: frame)
    }
    func shouldRun(_ name: String) -> Bool { only.map { $0.contains(name) } ?? true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rise-fullscreen-fixtures-\(ProcessInfo.processInfo.processIdentifier)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            writeFixtures(to: folder)
            for port in [fixturePort, framePort] {
                let server = Process(); server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", folder.path]
                server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
                try? server.run(); servers.append(server)
            }
            defer { servers.forEach { $0.terminate() } }
            await wait(800)
            let suite = "RiseFullscreenLive.\(ProcessInfo.processInfo.processIdentifier)"
            let preferences = UserDefaults(suiteName: suite)!
            preferences.set(ProcessInfo.processInfo.environment["RISE_FULLSCREEN_NATIVE"] == nil, forKey: PageFullscreen.simulatedKey)
            browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false, preferences: preferences)
            browser.window?.setContentSize(NSSize(width: 1280, height: 800)); browser.window?.center(); browser.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            check(browser.pageFullscreen.isSimulated, "Simulated fullscreen is on from the preference")

            if shouldRun("fixtures") { await fixtures() }
            if shouldRun("frames") { await frameFixtures() }
            if shouldRun("modes") { await modes() }
            if shouldRun("plaque") { await plaque() }
            if only?.contains("youtube-esc") == true { await youTubeExitTiming() }
            if shouldRun("sites") || only?.contains(where: { $0.hasPrefix("site:") }) == true { await sites() }

            print("\n\(passes) passed, \(failures) failed")
            servers.forEach { $0.terminate() }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            exit(failures == 0 ? 0 : 1)
        }
    }

    // MARK: Fixtures

    func writeFixtures(to folder: URL) {
        let main = """
        <!doctype html><meta charset=utf-8><title>Fullscreen fixture</title>
        <style>
          body { margin: 0; font: 14px -apple-system; min-height: 3000px }
          #box:fullscreen { background: rgb(0, 128, 0) !important }
          @media (min-width: 10px) { #box:-webkit-full-screen .inner { color: rgb(255, 0, 0) } }
          .wrap { transform: translateX(10px); overflow: hidden; width: 300px; height: 200px; position: relative; z-index: 1; filter: blur(0px) }
          .cover { position: fixed; left: 0; right: 0; bottom: 0; height: 80px; background: orange; z-index: 2147483647 }
          iframe { width: 320px; height: 180px; border: 4px solid blue }
        </style>
        <div class=wrap><div id=box style="width:200px;height:100px;background:red"><span class=inner>box</span></div></div>
        <div id=legacy style="width:100px;height:40px;background:#ddd">legacy</div>
        <div id=removable style="width:100px;height:40px;background:#bbb">removable</div>
        <div id=stubborn style="width:100px;height:40px;background:#999">stubborn</div>
        <video id=vid width=160 height=90 muted playsinline></video>
        <div id=shadowhost></div>
        <iframe id=allowed allowfullscreen src="http://localhost:\(framePort)/child.html?allowed"></iframe>
        <iframe id=denied src="http://localhost:\(framePort)/child.html?denied"></iframe>
        <div class=cover>A banner on top of everything</div>
        <script>
          window.events = [];
          for (const type of ['fullscreenchange', 'webkitfullscreenchange', 'fullscreenerror', 'webkitbeginfullscreen', 'webkitendfullscreen'])
            document.addEventListener(type, () => events.push(type + ':' + (document.fullscreenElement?.id || 'null')), true);
          // A site acting up: it squeezes its own fullscreen element with an inline !important width.
          stubborn.addEventListener('fullscreenchange', () => { if (document.fullscreenElement === stubborn) stubborn.style.setProperty('width', '50%', 'important'); });
          const root = shadowhost.attachShadow({ mode: 'open' });
          root.innerHTML = '<style>#inner:fullscreen { background: rgb(0, 0, 255) !important }</style><div id=inner style="width:50px;height:50px;background:pink">shadow</div>';
        </script>
        """
        let child = """
        <!doctype html><meta charset=utf-8>
        <style> body { margin: 0; background: #eee } #player { width: 100px; height: 60px; background: purple } #player:fullscreen { background: rgb(0, 0, 255) } </style>
        <div id=player>child</div>
        <script>
          window.events = [];
          document.addEventListener('fullscreenchange', () => events.push('fullscreenchange:' + (document.fullscreenElement?.id || 'null')));
        </script>
        """
        let embed = """
        <!doctype html><meta charset=utf-8><title>Embedded players</title>
        <body style="margin:0;padding:20px;font:14px -apple-system">
        <p>A YouTube embed and a Vimeo embed in frames, as blogs show them.</p>
        <div style="transform: scale(0.9); transform-origin: top left">
        <iframe id=yt width=560 height=315 src="https://www.youtube.com/embed/aqz-KE-bpKQ?autoplay=1&mute=1" allow="autoplay; encrypted-media; fullscreen" allowfullscreen></iframe>
        <iframe id=vimeo width=560 height=315 src="https://player.vimeo.com/video/76979871" allow="autoplay; fullscreen" allowfullscreen></iframe>
        </div>
        </body>
        """
        try? main.write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try? child.write(to: folder.appendingPathComponent("child.html"), atomically: true, encoding: .utf8)
        try? embed.write(to: folder.appendingPathComponent("embed.html"), atomically: true, encoding: .utf8)
    }

    func fixtures() async {
        print("\nFixtures")
        let web = await load("http://127.0.0.1:\(fixturePort)/index.html")
        let original = await string(web, "JSON.stringify(box.getBoundingClientRect())")

        await js(web, "window.result = 'pending'; box.requestFullscreen().then(() => result = 'ok', e => result = 'error ' + e.name); 0")
        await wait(500)
        var state = await pageState(web)
        check(await string(web, "result") == "ok", "requestFullscreen resolves")
        check(state["fe"] as? String == "div#box" && state["covers"] as? Bool == true, "The box inside a transformed, clipped wrapper covers the page: \(state)")
        check(state["onTop"] as? Bool == true, "The top layer puts it over a z-index 2147483647 banner (hit \(state["hit"] ?? "nil"))")
        check(web.fullscreenState == .notInFullscreen, "WebKit's own fullscreen stays out of it")
        check(await string(web, "getComputedStyle(box).backgroundColor") == "rgb(0, 128, 0)", "The page's :fullscreen rule applies")
        check(await string(web, "getComputedStyle(box.querySelector('.inner')).color") == "rgb(255, 0, 0)", "A :-webkit-full-screen rule inside @media applies")
        check(await string(web, "events.join()") == "fullscreenchange:box", "One fullscreenchange, unprefixed, for an unprefixed request: \(await string(web, "events.join()"))")
        check(await string(web, "String(document.fullscreen && document.webkitIsFullScreen && document.webkitFullscreenElement === box)") == "true", "The legacy getters agree")
        capture("fixture-box")
        escape(); await wait(500)
        state = await pageState(web)
        check(state["fe"] is NSNull && state["attributes"] as? Int == 0, "Escape leaves and cleans up every attribute: \(state)")
        check(await string(web, "events.join()") == "fullscreenchange:box,fullscreenchange:null", "Leaving fires fullscreenchange once more")
        let restored = await string(web, "JSON.stringify(box.getBoundingClientRect())"), popover = await js(web, "box.hasAttribute('popover')") as? Bool
        check(restored == original && popover == false, "The box is back where it was, without a popover attribute")

        // The legacy API, as older players call it.
        await js(web, "events = []; legacy.webkitRequestFullscreen(); 0"); await wait(400)
        check(await string(web, "events.join()") == "fullscreenchange:legacy,webkitfullscreenchange:legacy", "webkitRequestFullscreen fires both change events: \(await string(web, "events.join()"))")
        await js(web, "document.webkitExitFullscreen(); 0"); await wait(400)
        check(await string(web, "String(document.webkitFullscreenElement)") == "null", "webkitExitFullscreen leaves")

        // An element inside a shadow root.
        await js(web, "events = []; shadowhost.shadowRoot.getElementById('inner').requestFullscreen(); 0"); await wait(400)
        check(await string(web, "document.fullscreenElement?.id + ',' + shadowhost.shadowRoot.fullscreenElement?.id") == "shadowhost,inner", "fullscreenElement is retargeted to the shadow host")
        check(await string(web, "getComputedStyle(shadowhost.shadowRoot.getElementById('inner')).backgroundColor") == "rgb(0, 0, 255)", "The shadow root's :fullscreen rule applies")
        check(await string(web, "String(Math.round(shadowhost.shadowRoot.getElementById('inner').getBoundingClientRect().width) === innerWidth)") == "true", "The shadow element covers the page")
        await js(web, "document.exitFullscreen(); 0"); await wait(400)

        // A video's own fullscreen.
        await js(web, "events = []; vid.webkitEnterFullscreen(); 0"); await wait(400)
        check(await string(web, "String(vid.webkitDisplayingFullscreen && vid.controls)") == "true", "webkitEnterFullscreen shows the video with controls")
        check(await string(web, "events.join()").contains("webkitbeginfullscreen"), "webkitbeginfullscreen fires: \(await string(web, "events.join()"))")
        await js(web, "vid.webkitExitFullscreen(); 0"); await wait(400)
        check(await string(web, "String(!vid.webkitDisplayingFullscreen && !vid.controls)") == "true", "webkitExitFullscreen restores the video")

        // Removing the element leaves fullscreen, as in real fullscreen.
        await js(web, "events = []; removable.requestFullscreen(); 0"); await wait(400)
        await js(web, "removable.remove(); 0"); await wait(900)
        state = await pageState(web)
        check(state["fe"] is NSNull && state["attributes"] as? Int == 0, "Removing the element leaves fullscreen: \(state)")
        check(await string(web, "events.join()") == "fullscreenchange:removable,fullscreenchange:null", "...and says so: \(await string(web, "events.join()"))")

        // No user gesture, as WebKit's own fullscreen requires.
        await js(web, "window.late = 'pending'; setTimeout(() => box.requestFullscreen().then(() => late = 'ok', e => late = 'error ' + e.name), 1500); 0")
        await wait(2200)
        check(await string(web, "late").hasPrefix("error"), "A request long after the click is refused: \(await string(web, "late"))")

        // A site that breaks its own fullscreen element: WebKit's fullscreen takes over.
        await js(web, "events = []; stubborn.requestFullscreen(); 0")
        let fellBack = await waitForNative(web, .inFullscreen, timeout: 6)
        check(fellBack, "A squeezed element falls back to WebKit's fullscreen")
        check(await string(web, "document.fullscreenElement?.id") == "stubborn", "...for the same element")
        capture("fixture-fallback")
        await js(web, "document.exitFullscreen(); 0")
        check(await waitForNative(web, .notInFullscreen, timeout: 6), "WebKit's fullscreen exits")
        await wait(500)
        browser.closeTab(browser.selectedID!)
    }

    func frameFixtures() async {
        print("\nFrames")
        let tab = browser.addTab()
        tab.webView.configuration.userContentController.add(collector, contentWorld: .page, name: "probeFrames")
        tab.webView.configuration.userContentController.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.probeFrames.postMessage(location.href)", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        tab.load(URL(string: "http://127.0.0.1:\(fixturePort)/index.html")!)
        let web = tab.webView
        await wait(2000)
        guard let allowed = collector.frames.first(where: { $0.key.hasSuffix("?allowed") })?.value,
              let denied = collector.frames.first(where: { $0.key.hasSuffix("?denied") })?.value else {
            check(false, "Found both frames: \(collector.frames.keys)"); return
        }
        await js(web, "window.result = 'pending'; player.requestFullscreen().then(() => result = 'ok', e => result = 'error ' + e.name); 0", frame: allowed)
        await wait(800)
        var top = await pageState(web), inner = await pageState(web, frame: allowed)
        check(await string(web, "result", frame: allowed) == "ok", "The frame's request resolves")
        check(top["fe"] as? String == "iframe#allowed" && top["covers"] as? Bool == true, "The parent lifts the frame over the page: \(top)")
        check(inner["fe"] as? String == "div#player" && inner["covers"] as? Bool == true, "The frame's element covers the frame: \(inner)")
        check(await string(web, "getComputedStyle(player).backgroundColor", frame: allowed) == "rgb(0, 0, 255)", "The frame's :fullscreen rule applies")
        check(await string(web, "events.join()") == "fullscreenchange:allowed", "The parent fires its own change: \(await string(web, "events.join()"))")
        capture("frame-in")
        await js(web, "document.exitFullscreen(); 0", frame: allowed); await wait(700)
        top = await pageState(web); inner = await pageState(web, frame: allowed)
        check(top["fe"] is NSNull && top["attributes"] as? Int == 0 && inner["fe"] is NSNull, "The frame leaving releases the parent: \(top) \(inner)")

        await js(web, "player.requestFullscreen(); 0", frame: allowed); await wait(800)
        escape(); await wait(700)
        top = await pageState(web); inner = await pageState(web, frame: allowed)
        check(top["fe"] is NSNull && inner["fe"] is NSNull && inner["attributes"] as? Int == 0, "Escape in the parent releases the frame too: \(top) \(inner)")
        check(await string(web, "events.join()", frame: allowed) == "fullscreenchange:player,fullscreenchange:null,fullscreenchange:player,fullscreenchange:null", "The frame hears each change: \(await string(web, "events.join()", frame: allowed))")

        await js(web, "window.result = 'pending'; player.requestFullscreen().then(() => result = 'ok', e => result = 'error ' + e.name); 0", frame: denied)
        await wait(800)
        top = await pageState(web)
        check(await string(web, "result", frame: denied).hasPrefix("error") && top["fe"] is NSNull, "A frame without allowfullscreen is refused: \(await string(web, "result", frame: denied))")
        check(web.fullscreenState == .notInFullscreen, "...without WebKit's fullscreen either")
        browser.closeTab(tab.id)
    }

    func modes() async {
        print("\nSwitching modes")
        let web = await load("http://127.0.0.1:\(fixturePort)/index.html")
        await js(web, "events = []; box.requestFullscreen(); 0"); await wait(500)
        browser.toggleSimulatedFullscreen()
        check(!browser.pageFullscreen.isSimulated && browser.infoPlaque.text == "Native full screen enabled", "The shortcut turns simulated fullscreen off and says so")
        check(await waitForNative(web, .inFullscreen, timeout: 6), "The open page moves to WebKit's fullscreen")
        let nativeElement = await string(web, "document.fullscreenElement?.id"), leftover = (await pageState(web))["attributes"] as? Int
        check(nativeElement == "box" && leftover == 0, "...keeping the same element, without simulated attributes")
        capture("mode-native")
        browser.toggleSimulatedFullscreen()
        check(browser.pageFullscreen.isSimulated && browser.infoPlaque.text == "Simulated full screen enabled", "The shortcut turns it back on")
        check(await waitForNative(web, .notInFullscreen, timeout: 6), "WebKit's fullscreen ends")
        await wait(700)
        let state = await pageState(web)
        check(state["fe"] as? String == "div#box" && state["covers"] as? Bool == true, "...and the box is simulated fullscreen again: \(state)")
        capture("mode-simulated")
        escape(); await wait(500)
        check((await pageState(web))["fe"] is NSNull, "Escape leaves")
        print("    events: \(await string(web, "events.join()"))")

        browser.pageFullscreen.setSimulated(false, in: browser.tabs.map(\.webView))
        browser.reload(); await wait(1500)
        await js(web, "box.requestFullscreen(); 0")
        check(await waitForNative(web, .inFullscreen, timeout: 6), "With simulated fullscreen off, pages get WebKit's fullscreen")
        await js(web, "document.exitFullscreen(); 0")
        check(await waitForNative(web, .notInFullscreen, timeout: 6), "...and leave it")
        browser.pageFullscreen.setSimulated(true, in: browser.tabs.map(\.webView))
        browser.closeTab(browser.selectedID!)
    }

    func plaque() async {
        print("\nPlaque")
        _ = browser.addTab()
        await wait(300)
        browser.toggleSimulatedFullscreen()
        let shownAt = Date()
        let plaque = browser.infoPlaque, page = plaque.frame
        await wait(40)
        let early = plaque.convert(plaque.panel.frame, to: browser.root)
        check(early.minY < page.minY+FindBar.top-2, "The plaque drops in from above: \(early)")
        await wait(450)
        let rest = plaque.convert(plaque.panel.frame, to: browser.root)
        check(abs(rest.maxX-(page.maxX-FindBar.margin)) < 0.5 && abs(rest.minY-(page.minY+FindBar.top)) < 0.5 && rest.height == FindBar.rowHeight, "It rests in the find bar's corner, at the find bar's height: \(rest)")
        let text = plaque.textWidth
        check(rest.width < 260 && rest.width > text+30, "Its width fits the text (\(Int(text)) pt of text in \(Int(rest.width)) pt)")
        capture("plaque")
        await wait(max(0, Int((0.9-Date().timeIntervalSince(shownAt))*1000)))
        check(plaque.isPresented && Date().timeIntervalSince(shownAt) < 1, "It holds for a second (\(Int(Date().timeIntervalSince(shownAt)*1000)) ms in)")
        await wait(max(0, Int((1.12-Date().timeIntervalSince(shownAt))*1000)))
        check(!plaque.isPresented, "...then goes back up")
        await wait(500)
        check(plaque.isHidden, "...and is hidden once out of sight")
        // Toggling again while it shows swaps just the changing word.
        browser.toggleSimulatedFullscreen(); await wait(450)
        let before = plaque.convert(plaque.panel.frame, to: browser.root)
        browser.toggleSimulatedFullscreen()
        await wait(30); capture("plaque-swap")
        await wait(250)
        let after = plaque.convert(plaque.panel.frame, to: browser.root)
        check(plaque.lead == "Native" && plaque.rest == "full screen enabled", "A second toggle swaps only the word that changed")
        check(after.width < before.width && abs(after.maxX-before.maxX) < 0.5 && abs(after.minY-before.minY) < 0.5, "The panel narrows to fit, staying in its corner: \(before) → \(after)")
        browser.toggleSimulatedFullscreen()
        await wait(1700)
        check(browser.pageFullscreen.isSimulated && !plaque.isPresented, "Back to simulated, and the plaque goes up a second after the last toggle")
        browser.closeTab(browser.selectedID!)
    }

    /// How long YouTube takes to leave fullscreen after Escape, compared with its own button.
    func youTubeExitTiming() async {
        print("\nYouTube exit timing")
        let web = await load("https://www.youtube.com/watch?v=aqz-KE-bpKQ")
        await wait(2000)
        await js(web, "[...document.querySelectorAll('button')].find(b => /^(reject all|accept all)$/i.test(b.textContent.trim()))?.click(); 0")
        await wait(3000)
        let probe = "(() => { const f = document.querySelector('ytd-watch-flexy'); const p = document.querySelector('#movie_player'); return [document.fullscreenElement ? 1 : 0, f?.hasAttribute('fullscreen') ? 1 : 0, Math.round(p?.getBoundingClientRect().height ?? 0)].join(); })()"
        func measure(_ label: String, _ action: () async -> Void) async {
            let start = Date()
            let stamp = DateFormatter(); stamp.dateFormat = "HH:mm:ss.SSS"
            print("    \(label) at \(stamp.string(from: start)), focus: \(await string(web, "document.hasFocus() + ' ' + (document.activeElement?.tagName || '') + ' ' + (document.activeElement?.id || '')"))")
            await action()
            var last = "", changes: [String] = []
            while Date().timeIntervalSince(start) < 3 {
                let now = await string(web, probe)
                if now != last { changes.append("\(Int(Date().timeIntervalSince(start)*1000)) ms: \(now)"); last = now }
                await wait(5)
            }
            print("    \(label): " + changes.joined(separator: "  →  "))
        }
        for round in 1...6 {
            await js(web, "(() => { const r = document.querySelector('.ytp-fullscreen-button').getBoundingClientRect(); window.__clickAt = [r.left + r.width / 2, r.top + r.height / 2]; })(); 0")
            await mouseClick(web); await wait(2500)
            if round % 2 == 1 { await measure("Escape \(round)") { escape() } }
            else { await measure("button \(round)") { await js(web, "(() => { const r = document.querySelector('.ytp-fullscreen-button').getBoundingClientRect(); window.__clickAt = [r.left + r.width / 2, r.top + r.height / 2]; })(); 0"); await mouseClick(web) } }
            await wait(1500)
        }
    }

    // MARK: Real sites

    struct Site {
        let name, url: String
        /// The site's fullscreen button, tried in order.
        let buttons: [String]
        /// Runs in the frame whose URL contains this, for embedded players.
        var frame: String? = nil
        /// Clicks to make before the fullscreen button, like starting playback.
        var prepare: String? = nil
        /// JavaScript describing the site's own idea of fullscreen, shown in the output.
        var probe: String? = nil
        /// Whether the button also leaves fullscreen.
        var ownExit = true
        /// Clicks with the mouse, for players that ignore a scripted click.
        var realClick = false
    }
    let siteList: [Site] = [
        Site(name: "youtube", url: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", buttons: [".ytp-fullscreen-button"],
             probe: "const p = document.querySelector('#movie_player'); const r = p?.getBoundingClientRect(); return { flexy: document.querySelector('ytd-watch-flexy')?.hasAttribute('fullscreen'), player: r && [r.width, r.height].map(Math.round).join('x'), unsupported: [...document.querySelectorAll('.ytp-tooltip-text, .ytp-error')].map(e => e.textContent).join(' | ') }"),
        Site(name: "seedbox", url: "https://seedbox.bartoszbak.org/media/e1_bW92aWU6bTFfY1dKcGRIUnZjbkpsYm5RdlFtOXlZWFF1UTNWc2RIVnlZV3d1VEdWaGNtNXBibWR6TG05bUxrRnRaWEpwWTJFdVptOXlMazFoYTJVdVFtVnVaV1pwZEM1SGJHOXlhVzkxY3k1T1lYUnBiMjR1YjJZdVMyRjZZV3RvYzNSaGJpNHlNREEyTGpFd09EQndMa2hWVEZVdVYwVkNMVVJNTGtSRVVEVXVNUzVJTGpJMk5DMUNURTlQVFM1dGEzWQ",
             buttons: ["button[aria-label=\"Fullscreen\"]", "button[aria-label=\"Exit fullscreen\"]"],
             probe: "const s = document.querySelector('.player-shell'); const v = s?.querySelector('video, canvas'); const r = v?.getBoundingClientRect(); return { fallbackClass: s?.classList.contains('player-fullscreen-fallback'), shellBackground: s && getComputedStyle(s).backgroundColor, media: r && [r.width, r.height].map(Math.round).join('x'), label: document.querySelector('button[aria-label*=\"ullscreen\"]')?.getAttribute('aria-label') }"),
        Site(name: "vimeo", url: "https://player.vimeo.com/video/76979871", buttons: ["button.fullscreen", "[data-fullscreen-button]", "button[aria-label*=\"ull screen\" i]", "button[aria-label*=\"ullscreen\" i]"]),
        Site(name: "youtube-embed", url: "http://127.0.0.1:8871/embed.html", buttons: [".ytp-fullscreen-button", "button[aria-label*=\"ull screen\" i]", "button[aria-label*=\"ullscreen\" i]"], frame: "youtube.com/embed",
             prepare: "document.querySelector('.ytp-large-play-button')?.click(); 0"),
        Site(name: "vimeo-embed", url: "http://127.0.0.1:8871/embed.html", buttons: ["button.fullscreen", "[data-fullscreen-button]", "button[aria-label*=\"ull screen\" i]", "button[aria-label*=\"ullscreen\" i]"], frame: "player.vimeo.com"),
        Site(name: "videojs10", url: "https://plyr.io", buttons: ["button[data-plyr=\"fullscreen\"]", "media-fullscreen-button", "[aria-label*=\"ullscreen\" i]", "[aria-label*=\"ull screen\" i]"]),
        Site(name: "shaka", url: "https://shaka-player-demo.appspot.com/demo/#audiolang=en-US;textlang=en-US;uilang=en-US;asset=https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd;panel=HOME;build=uncompiled", buttons: [".shaka-fullscreen-button"],
             prepare: "window.__fsCalls = []; for (const [proto, names] of [[Element.prototype, ['requestFullscreen', 'webkitRequestFullscreen']], [HTMLVideoElement.prototype, ['webkitEnterFullscreen', 'webkitSetPresentationMode']]]) for (const name of names) { const original = proto[name]; proto[name] = function (...args) { __fsCalls.push(name + ':' + this.tagName); return original.apply(this, args); }; } 0",
             probe: "return { calls: (window.__fsCalls || []).join(), enabled: document.fullscreenEnabled, supports: document.querySelector('video')?.webkitSupportsFullscreen }"),
        Site(name: "w3schools", url: "https://www.w3schools.com/howto/tryhow_js_fullscreen2.htm", buttons: ["button[onclick*=\"openFullscreen\"]"], ownExit: false),
        Site(name: "ted", url: "https://www.ted.com/talks/sir_ken_robinson_do_schools_kill_creativity", buttons: ["button[aria-label*=\"ullscreen\" i]", "button[aria-label*=\"ull screen\" i]"], realClick: true),
        Site(name: "archive-jwplayer", url: "https://archive.org/embed/BigBuckBunny_124", buttons: [".jw-icon-fullscreen", "[aria-label*=\"ullscreen\" i]"], prepare: "document.querySelector('.jw-display-icon-display, .jw-icon-display')?.click(); 0"),
    ]

    /// A real click where the last button was, through the window like a user's.
    func mouseClick(_ web: WKWebView) async {
        guard let point = await js(web, "window.__clickAt") as? [Double], point.count == 2, let window = browser.window else { return }
        let local = NSPoint(x: point[0], y: web.isFlipped ? point[1] : web.bounds.height-point[1])
        let location = web.convert(local, to: nil)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
            await wait(type == .mouseMoved ? 300 : 40)
        }
    }

    static let deep = "const deep = (sel, root = document) => { const hit = root.querySelector(sel); if (hit) return hit; for (const el of root.querySelectorAll('*')) if (el.shadowRoot) { const found = deep(sel, el.shadowRoot); if (found) return found; } return null; };"

    func frameInfo(_ web: WKWebView, containing part: String) async -> WKFrameInfo? {
        for _ in 0..<60 {
            if let frame = collector.frames.first(where: { $0.key.contains(part) })?.value { return frame }
            await wait(250)
        }
        return nil
    }

    func sites() async {
        for site in siteList where shouldRun("site:" + site.name) || shouldRun("sites") && only?.contains(where: { $0.hasPrefix("site:") }) != true {
            print("\nSite: \(site.name)")
            collector.frames = [:]
            let tab = browser.addTab()
            tab.webView.configuration.userContentController.add(collector, contentWorld: .page, name: "probeFrames")
            tab.webView.configuration.userContentController.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.probeFrames.postMessage(location.href)", injectionTime: .atDocumentEnd, forMainFrameOnly: false))
            tab.load(URL(string: site.url)!)
            let web = tab.webView
            await wait(1500)
            let started = Date()
            while web.isLoading && Date().timeIntervalSince(started) < 25 { await wait(150) }
            // Consent walls in front of the player.
            if web.url?.host?.hasPrefix("consent.") == true {
                await js(web, "[...document.querySelectorAll('button')].find(b => /reject all|accept all/i.test(b.textContent))?.click(); 0")
                await wait(4000)
            }
            await js(web, "[...document.querySelectorAll('button')].find(b => /^(reject all|accept all|accept|i agree|agree|allow all)$/i.test(b.textContent.trim()))?.click(); 0")
            var frame: WKFrameInfo?
            if let part = site.frame {
                frame = await frameInfo(web, containing: part)
                guard frame != nil else { check(false, "\(site.name): found the player frame (\(collector.frames.keys.joined(separator: ", ")))"); browser.closeTab(tab.id); continue }
            }
            await js(web, "[...document.querySelectorAll('button')].find(b => /^(reject all|accept all)$/i.test(b.textContent.trim()))?.click(); 0")
            if let prepare = site.prepare { await wait(1500); await js(web, prepare, frame: frame); await wait(1500) }
            let selectors = site.buttons.map { "'" + $0.replacingOccurrences(of: "'", with: "\\'") + "'" }.joined(separator: ",")
            let found = await waitFor(web, "(() => { \(Self.deep) return [\(selectors)].some(s => deep(s)); })()", frame: frame, timeout: 20)
            if !found { print("    frame says: \(await string(web, "location.href + ' buttons ' + document.querySelectorAll('button').length + ' ' + [...document.querySelectorAll('button')].slice(0, 8).map(b => b.className + '/' + b.getAttribute('aria-label')).join(' | ') + ' err ' + (document.querySelector('.ytp-error')?.textContent || '')", frame: frame))") }
            guard found else { check(false, "\(site.name): found the fullscreen button"); capture("site-\(site.name)-missing"); browser.closeTab(tab.id); continue }
            await wait(2500)
            let click = "(() => { \(Self.deep) const b = [\(selectors)].map(s => deep(s)).find(Boolean); b.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, composed: true })); \(site.realClick ? "" : "b.click();") const r = b.getBoundingClientRect(); window.__clickAt = [r.left + r.width / 2, r.top + r.height / 2]; return b.outerHTML.slice(0, 120); })()"
            print("    clicked \(await string(web, click, frame: frame))"); if site.realClick { await mouseClick(web) }
            await wait(1800)
            let top = await pageState(web)
            let inner = frame == nil ? top : await pageState(web, frame: frame)
            let native = web.fullscreenState
            print("    top \(top)")
            if frame != nil { print("    frame \(inner)") }
            if let probe = site.probe { print("    site \(await json(web, probe, frame: frame))") }
            check(native == .notInFullscreen, "\(site.name): stays in the window (WebKit fullscreen state \(native.rawValue))")
            check(inner["rise"] is [String: Any] && (inner["covers"] as? Bool == true || inner["pinned"] as? String == "html"), "\(site.name): the player is simulated fullscreen, covering the page")
            if frame != nil { check(top["covers"] as? Bool == true && (top["pinned"] as? String)?.hasPrefix("iframe") == true, "\(site.name): the parent lifts the player's frame") }
            capture("site-\(site.name)-in")
            if native != .notInFullscreen {
                await js(web, "document.exitFullscreen(); 0", frame: frame)
                _ = await waitForNative(web, .notInFullscreen, timeout: 6)
            }
            // Leave through the site's own button, then enter again and leave with Escape.
            print("    clicked \(await string(web, click, frame: frame))"); if site.realClick { await mouseClick(web) }
            await wait(1200)
            var after = await pageState(web, frame: frame), afterTop = await pageState(web)
            if site.ownExit { check(after["fe"] is NSNull && after["attributes"] as? Int == 0 && afterTop["attributes"] as? Int == 0, "\(site.name): the site's own button leaves cleanly: \(after["fe"] ?? "nil")") }
            else { escape(); await wait(1000) }
            if let probe = site.probe { print("    site \(await json(web, probe, frame: frame))") }
            await js(web, click, frame: frame); if site.realClick { await mouseClick(web) }
            await wait(1500)
            escape(); await wait(1200)
            after = await pageState(web, frame: frame); afterTop = await pageState(web)
            check(after["fe"] is NSNull && after["attributes"] as? Int == 0 && afterTop["fe"] is NSNull, "\(site.name): Escape leaves cleanly")
            if let probe = site.probe { print("    site \(await json(web, probe, frame: frame))") }
            capture("site-\(site.name)-out")
            browser.closeTab(tab.id)
        }
    }
}
