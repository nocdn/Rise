// A page gets the shortcuts it might want before Rise does, in a real Rise window with real key
// events: one it ignores runs Rise's command at once, one it keeps offers Rise's command in the
// page bar if it could run, and pressing it again runs it. Plus Google Docs' own ⌘F, when online.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumPageShortcutChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumPageShortcutMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+150) { print("FAIL Page shortcut checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = ChromiumPageShortcutRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumPageShortcutRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    var page: WebPage!
    init(folder: URL) { self.folder = folder }
    func check(_ condition: Bool, _ description: String) {
        print(condition ? "PASS" : "FAIL", description); if !condition { failures += 1 }
    }
    @discardableResult func wait(_ description: String, seconds: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !(await condition()) {
            if Date() > end { check(false, "timed out: \(description)"); return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        check(true, description)
        return true
    }
    func value(_ script: String, in page: WebPage? = nil) async -> Any? {
        try? await (page ?? self.page).evaluate(script, arguments: [:], in: nil, world: .page)
    }
    /// A real press, through the app as the keyboard's are.
    func press(_ key: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = .command) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: browser.window!.windowNumber, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
    }
    /// What the page has seen of ⌘ keys, and it starts afresh.
    func seen() async -> [String] {
        let keys = await value("const k = keys; keys = []; return k") as? [String] ?? []
        return keys
    }
    func keep(_ keys: [String]) async {
        let list = keys.map { "'\($0)'" }.joined(separator: ",")
        _ = await value("keep = new Set([\(list)]); return true")
    }
    /// The bar's words, for what a key press has by now had time to do.
    func settled() async -> String? {
        try? await Task.sleep(for: .milliseconds(350))
        return browser.selectedBar.notice?.text
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            await run()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async {
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let html = """
        <!doctype html><title>Keys</title><textarea id=box></textarea><p>Some words to find</p><script>
        var keys = [], keep = new Set();
        addEventListener('keydown', e => { if (e.metaKey && e.key != 'Meta') { keys.push(e.key); if (keep.has(e.key)) e.preventDefault() } }, true);
        </script>
        """
        try? html.write(to: folder.appendingPathComponent("keys.html"), atomically: true, encoding: .utf8)
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: "rise-page-keys-\(UUID())")!)
        browser.window?.setContentSize(NSSize(width: 1200, height: 800)); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        let other = browser.addTab(url: URL(string: "about:blank")!)
        let tab = browser.addTab(url: URL(string: "http://127.0.0.1:\(port)/keys.html")!)
        page = tab.page
        await wait("The page loads", seconds: 15) { tab.page.title == "Keys" }
        browser.window?.makeFirstResponder(tab.page.view)
        await wait("It has the keyboard", seconds: 10) {
            let focused = await self.value("return document.hasFocus()") as? Bool == true
            return focused && self.browser.keyboardBrowserView != nil && self.browser.window?.isKeyWindow == true
        }
        // A page just shown ignores input for a moment, as Chromium does until it has painted.
        var tries = 0
        await wait("It's taking key presses", seconds: 10) {
            tries += 1; self.press("k", code: 40)
            try? await Task.sleep(for: .milliseconds(150))
            return await self.seen().contains("k")
        }
        print("  It took \(tries) press(es)")

        // ⌘S is the page's alone now.
        check(browser.keyboardShortcuts.bindings("toggleSidebar").map(\.display) == ["⌘B"], "Only ⌘B toggles the sidebar")
        var sidebar = browser.sidebarVisible
        press("s", code: 1)
        await wait("⌘S goes to the page") { await self.value("return keys.includes('s')") as? Bool == true }
        _ = await seen()
        let quiet = await settled()
        check(browser.sidebarVisible == sidebar && quiet == nil, "And the sidebar stays, with nothing offered")

        // A shortcut the page ignores still runs Rise's command, having been to the page first.
        press("b", code: 11)
        await wait("⌘B the page ignores toggles the sidebar") { self.browser.sidebarVisible != sidebar }
        check(await seen() == ["b"], "The page saw it first")
        sidebar = browser.sidebarVisible
        if !sidebar { browser.setSidebarVisible(true); sidebar = true }
        browser.window?.makeFirstResponder(tab.page.view)

        // One it keeps offers Rise's command in the page bar, and pressing it again runs it.
        await keep(["b"])
        press("b", code: 11)
        let offer = await settled()
        check(offer == "Press ⌘B again to Hide Sidebar", "⌘B the page keeps offers Rise's command: \(offer ?? "nothing")")
        check(browser.sidebarVisible == sidebar, "And the sidebar stays for now")
        check(await seen() == ["b"], "The page has it, as Google Docs' bold would")
        press("b", code: 11)
        await wait("Pressed again while it says so, the sidebar toggles") { self.browser.sidebarVisible != sidebar }
        check(await seen().isEmpty, "That press wasn't the page's")
        browser.setSidebarVisible(true)
        browser.selectedBar.hideNotice()
        browser.window?.makeFirstResponder(tab.page.view)
        // Too late, it's the page's again.
        press("b", code: 11)
        _ = await settled()
        browser.shortcutAgain?.until = Date().addingTimeInterval(-1)
        press("b", code: 11)
        _ = await settled()
        let sawBoth = await seen()
        check(sawBoth == ["b", "b"] && browser.sidebarVisible, "Once the offer's over, it's the page's again")
        browser.shortcutAgain = nil; browser.selectedBar.hideNotice()

        // ⌘Z: the page's, and only says so if Rise has something to undo.
        await keep(["z"])
        press("z", code: 6)
        let nothing = await settled()
        check(nothing == nil, "⌘Z the page keeps says nothing with nothing of Rise's to undo: \(nothing ?? "nothing")")
        check(await seen() == ["z"], "The page has it")
        browser.moveCurrentTabDown()
        let moved = browser.tabs.map(\.id)
        browser.window?.makeFirstResponder(tab.page.view)
        await wait("Moving a tab leaves something of Rise's to undo") { self.browser.tabOrderUndoPending }
        press("z", code: 6)
        let undoOffer = await settled()
        check(undoOffer == "Press ⌘Z again to undo Move Tab", "With something to undo, it offers: \(undoOffer ?? "nothing")")
        let sawUndo = await seen()
        check(browser.tabs.map(\.id) == moved && sawUndo == ["z"], "The page had that press, and the tabs stayed")
        press("z", code: 6)
        await wait("Pressed again, the tab moves back") { self.browser.tabs.map(\.id) != moved }
        check(await seen().isEmpty, "That press wasn't the page's")
        browser.selectedBar.hideNotice()

        // ⌘Z the page ignores undoes Rise's move straight away, and otherwise the text in the page.
        await keep([])
        browser.moveCurrentTabDown()
        let movedAgain = browser.tabs.map(\.id)
        browser.window?.makeFirstResponder(tab.page.view)
        press("z", code: 6)
        await wait("⌘Z the page ignores undoes Rise's move at once") { self.browser.tabs.map(\.id) != movedAgain }
        _ = await seen()
        _ = await value("box.focus(); document.execCommand('insertText', false, 'typed'); return true")
        press("z", code: 6)
        await wait("And with nothing of Rise's to undo, the text in the page") { await self.value("return box.value") as? String == "" }
        check((await settled()) == nil, "Saying nothing")
        _ = await seen()

        // The page's editing, which goes by way of the page now, still goes through the menu bar.
        NSPasteboard.general.clearContents()
        _ = await value("box.value = 'copied words'; box.focus(); return true")
        press("a", code: 0)
        await wait("⌘A selects") { await self.value("return box.selectionEnd-box.selectionStart") as? Int == 12 }
        press("c", code: 8)
        await wait("⌘C copies") { NSPasteboard.general.string(forType: .string) == "copied words" }
        _ = await value("box.value = ''; return true")
        press("v", code: 9)
        await wait("⌘V pastes") { await self.value("return box.value") as? String == "copied words" }
        press("x", code: 7); press("a", code: 0); press("x", code: 7)
        await wait("⌘X cuts") { await self.value("return box.value") as? String == "" }
        check(await seen().contains("c"), "The page saw them first, as it does in Chrome")
        press("l", code: 37)
        await wait("⌘L the page ignores opens the address") { self.browser.palette.isPresented }
        browser.hidePalette(); browser.window?.makeFirstResponder(tab.page.view)
        _ = await seen()

        // ⌘F: Rise's find where the page ignores it, the page's own where it keeps it.
        press("f", code: 3)
        await wait("⌘F the page ignores opens Rise's find") { self.browser.findBar.isPresented }
        browser.hideFind(); _ = await seen()
        browser.window?.makeFirstResponder(tab.page.view)
        await keep(["f"])
        press("f", code: 3)
        let findOffer = await settled()
        check(!browser.findBar.isPresented && findOffer == "Press ⌘F again to Find on Page", "⌘F the page keeps offers Rise's find: \(findOffer ?? "nothing")")
        press("f", code: 3)
        await wait("Pressed again, Rise's find opens") { self.browser.findBar.isPresented }
        browser.window?.makeFirstResponder(tab.page.view)
        _ = await seen()
        press("g", code: 5)
        try? await Task.sleep(for: .milliseconds(200))
        check(await seen().isEmpty, "While it's open, ⌘G is the find bar's")
        browser.hideFind(); browser.selectedBar.hideNotice()
        browser.window?.makeFirstResponder(tab.page.view)

        // What a page can't have.
        let count = browser.tabs.count
        await keep(["t"])
        press("t", code: 17)
        await wait("⌘T goes to a new tab though the page would keep it") { self.browser.tabs.count == count+1 || self.browser.palette.isPresented }
        browser.hidePalette()
        check(await value("return keys.length", in: tab.page) as? Int == 0, "The page never sees it")
        _ = other

        // The real thing: Google Docs' own find, on a public document.
        check(!BrowserController.drawsItsOwnText(URL(string: "https://www.example.com/document/d/1")), "Only Google's editors are taken for canvases")
        guard let docs = URL(string: "https://docs.google.com/document/d/195j9eDD3ccgjQRttHhJPymLJUCOUjs-jmwTrekvdjFE/edit") else { return }
        check(BrowserController.drawsItsOwnText(docs), "A Google Doc draws its own text")
        let doc = browser.addTab(url: docs)
        let ready = "return !!document.querySelector('.kix-appview-editor')"
        guard await wait("Google Docs loads", seconds: 40, { await self.value(ready, in: doc.page) as? Bool == true }) else { return }
        try? await Task.sleep(for: .seconds(2))
        browser.window?.makeFirstResponder(doc.page.view)
        press("f", code: 3)
        let box = "const b = document.querySelector('.docs-findinput-input, .docs-findinput-container input, input[aria-label*=\"Find\" i]'); return !!b && b.offsetParent !== null"
        await wait("⌘F in Google Docs opens its own find", seconds: 8) { await self.value(box, in: doc.page) as? Bool == true }
        let docsNotice = browser.selectedBar.notice?.text
        check(!browser.findBar.isPresented && docsNotice == "Press ⌘F again to Find on Page", "It keeps the key, and the bar offers Rise's find: \(docsNotice ?? "nothing")")
        press("f", code: 3)
        await wait("Pressed again, Rise's find opens") { self.browser.findBar.isPresented }
        check(browser.findBar.findPlaceholder.stringValue == "Can't search this document", "And says it can't search a canvas, rather than finding nothing")
        check(!BrowserController.drawsItsOwnText(URL(string: "https://docs.google.com/presentation/d/1/edit")), "Slides' text is in the page, so find can search it")
        browser.hideFind(); browser.selectedBar.hideNotice()
    }
}
