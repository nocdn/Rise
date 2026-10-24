// Numbered tab shortcuts and menu commands with Chromium's own editable view focused.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumMenuChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumMenuMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL menu checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { exit(1) }
        let run = ChromiumMenuRun(folder: URL(fileURLWithPath: folder))
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumMenuRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var menus: AppDelegate!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ description: String) {
        print(value ? "PASS" : "FAIL", description); if !value { failures += 1 }
    }
    func wait(_ condition: () -> Bool) async {
        let end = Date().addingTimeInterval(10)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(30)) }
        check(condition(), "Page ready")
    }
    func key(_ number: Int) -> NSEvent {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window!.windowNumber, context: nil,
            characters: String(number), charactersIgnoringModifiers: String(number), isARepeat: false, keyCode: codes[number-1])!
    }
    func event(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags, repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window!.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code)!
    }
    func menu(_ title: String) -> NSMenu { NSApp.mainMenu!.items.first { $0.title == title }!.submenu! }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        try "<!doctype html><title>Menu test</title><input id=editor value=unchanged>".write(
            to: folder.appendingPathComponent("menu.html"), atomically: true, encoding: .utf8)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let url = URL(string: "http://localhost:\(port)/menu.html")!
        let prefs = UserDefaults(suiteName: "rise-menu-check-\(UUID())")!
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
        browser.showWindow(nil); browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        for index in 0..<11 { browser.addTab(url: URL(string: url.absoluteString + "?tab=\(index)")!) }
        await wait { self.browser.tabs.allSatisfy { $0.page.title == "Menu test" && !$0.isLoading } }
        menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        let order = browser.tabs.map(\.id)
        for number in 1...9 {
            let page = browser.selectedTab!.page
            _ = await page.evaluate("document.getElementById('editor').focus(); return null", arguments: [:], world: nil)
            browser.window?.makeFirstResponder(page.view)
            NSApp.sendEvent(key(number))
            check(browser.selectedID == order[number-1], "⌘\(number) switches from Chromium's focused input")
            let text = await page.evaluate("return document.getElementById('editor').value", arguments: [:], world: nil)
            check(text as? String == "unchanged", "The page's input receives no shortcut digit")
        }
        check(browser.selectedID != order.last, "⌘9 selects ninth with eleven tabs open")
        browser.focusAddress(); NSApp.sendEvent(key(1))
        check(browser.selectedID == order[0] && !browser.palette.isPresented, "⌘1 also leaves the address editor")
        browser.reorderTabs(Array(order.reversed()), animated: false)
        check(NSApp.mainMenu!.performKeyEquivalent(with: key(2)), "The menu bar handles ⌘2")
        check(browser.selectedID == browser.tabs[1].id, "Menu shortcuts follow the reordered tabs")
        let numbered = menu("Tabs").items.filter { $0.action == #selector(BrowserController.selectNumberedTab(_:)) }
        menu("Tabs").update()
        check(numbered[1].state == .on && numbered[1].title.contains("Menu test"), "Tabs menu shows the page title and selected tab")

        browser.select(browser.tabs[5].id)
        let beforeMove = browser.tabs.map(\.id), current = browser.selectedTab!
        let page = current.page
        _ = await page.evaluate("document.getElementById('editor').focus(); return null", arguments: [:], world: nil)
        browser.window?.makeFirstResponder(page.view)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        NSApp.sendEvent(event(up, code: 126, modifiers: [.command, .option]))
        var moved = beforeMove; moved.swapAt(5, 4)
        check(browser.tabs.map(\.id) == moved, "⌥⌘↑ moves the current tab up one row from Chromium's focused input")
        try await Task.sleep(for: .milliseconds(40))
        NSApp.sendEvent(event(up, code: 126, modifiers: [.command, .option], repeatKey: true))
        moved.swapAt(4, 3)
        check(browser.tabs.map(\.id) == moved, "Holding the arrow repeats tab movement")
        try await Task.sleep(for: .milliseconds(40))
        NSApp.sendEvent(event(down, code: 125, modifiers: [.command, .option]))
        moved.swapAt(3, 4)
        check(browser.tabs.map(\.id) == moved, "⌥⌘↓ moves the same tab back down")
        let release = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: browser.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58)!
        NSApp.sendEvent(release)
        NSApp.sendEvent(event("z", code: 6, modifiers: .command))
        check(browser.tabs.map(\.id) == beforeMove, "⌘Z restores the position before the whole held-arrow sequence")
        NSApp.sendEvent(event("z", code: 6, modifiers: [.command, .shift]))
        check(browser.tabs.map(\.id) == moved, "⇧⌘Z redoes the held-arrow sequence")
        NSApp.sendEvent(event(up, code: 126, modifiers: [.command, .option, .control]))
        let atTop = [current.id] + beforeMove.filter { $0 != current.id }
        check(browser.tabs.map(\.id) == atTop, "⌃⌥⌘↑ sends the tab straight to the top")
        NSApp.sendEvent(event("z", code: 6, modifiers: .command))
        check(browser.tabs.map(\.id) == moved, "⌘Z puts a tab sent to the top back where it was")
        NSApp.sendEvent(event("z", code: 6, modifiers: [.command, .shift]))
        check(browser.tabs.map(\.id) == atTop, "⇧⌘Z redoes the jump to the top")
        check(browser.selectedID == current.id && browser.selectedTab?.page.view === page.view, "Moving keeps the same tab and page selected")
        let text = await page.evaluate("return document.getElementById('editor').value", arguments: [:], world: nil)
        check(text as? String == "unchanged", "Moving the tab preserves the page's input")
        _ = await page.evaluate("const input = document.getElementById('editor'); input.focus(); input.setSelectionRange(input.value.length, input.value.length); return null", arguments: [:], world: nil)
        NSApp.sendEvent(event("a", code: 0, modifiers: []))
        try await Task.sleep(for: .milliseconds(100))
        let edited = await page.evaluate("return document.getElementById('editor').value", arguments: [:], world: nil)
        check(edited as? String == "unchangeda", "The page still accepts text after moving its tab")
        NSApp.sendEvent(event("z", code: 6, modifiers: .command))
        try await Task.sleep(for: .milliseconds(100))
        let undoneText = await page.evaluate("return document.getElementById('editor').value", arguments: [:], world: nil)
        check(undoneText as? String == "unchanged" && browser.tabs.map(\.id) == atTop, "After editing, ⌘Z undoes page text without moving the tab")

        let active = browser.selectedTab!
        let previous = active.url
        active.load(URL(string: url.absoluteString + "?destination")!)
        await wait { active.url?.query == "destination" && !active.isLoading }
        let history = menu("History"); history.update()
        let back = history.items.firstIndex { $0.action == #selector(BrowserController.goBack) }!
        check(history.items[back].isEnabled, "Back enables after a real page navigation")
        history.performActionForItem(at: back)
        await wait { active.url == previous && !active.isLoading }
        history.update()
        check(history.items.first { $0.action == #selector(BrowserController.goForward) }?.isEnabled == true, "Forward enables after going back")
        for tab in Array(browser.tabs.dropFirst(2)) { browser.closeTab(tab.id) }
        let selected = browser.selectedID
        NSApp.sendEvent(key(9)); menu("Tabs").update()
        check(browser.selectedID == selected && !numbered[8].isEnabled, "An unavailable ⌘9 cannot invoke Chromium's last-tab shortcut")
    }
}
