// python3 scripts/test-chromium-live.py Tests/Live/ChromiumTimeConversionChecks.swift
import AppKit
@testable import Rise
import RiseCore
import RiseChromium

@main @MainActor struct TimeConversionMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+100) { print("FAIL timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = TimeConversionRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class TimeConversionRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ valid: Bool, _ text: String) { print(valid ? "PASS" : "FAIL", text); if !valid { failures += 1 } }
    func wait(_ text: String, _ predicate: () async -> Bool) async throws {
        let until = Date().addingTimeInterval(10)
        while !(await predicate()), Date() < until { try await Task.sleep(for: .milliseconds(20)) }
        let valid = await predicate(); check(valid, text)
        if !valid { throw NSError(domain: text, code: 1) }
    }
    func value(_ body: String, _ page: WebPage) async -> Any? { await page.evaluate(body, arguments: [:], world: nil) }
    func key(_ type: NSEvent.EventType, at timestamp: TimeInterval, key: String = "t", code: UInt16 = 17,
             modifiers: NSEvent.ModifierFlags = [.command, .option], repeat repeated: Bool = false) {
        browser.window!.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
            windowNumber: browser.window!.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
            isARepeat: repeated, keyCode: code)!)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            browser?.timeReplacement.cancelHold(); browser?.saveWork?.cancel()
            browser?.tabs.forEach { $0.cancelLoad() }; browser?.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }
    func run() async throws {
        let suite = "Rise.TimeConversion.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        browser.window?.setFrameAutosaveName(""); browser.window?.setContentSize(NSSize(width: 1000, height: 720))
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        let item = browser.keyboardShortcuts.commands.first { $0.id == TimeReplacement.command }?.items.first
        check(item?.keyEquivalent == "t" && item?.keyEquivalentModifierMask == [.command, .option], "The View menu exposes ⌘⌥T")
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let url = URL(string: "http://localhost:\(port)/times.html")!
        try """
        <!doctype html><title>Time conversions</title><style>body{font:20px system-ui;padding:30px}</style>
        <p id=time>10 AM PT</p><p id=split>Starts at <b>10 AM</b> <i>PT</i>.</p>
        <p id=stamp>2026-12-01T10:05:06.123456Z</p><textarea id=edit>10 AM PT</textarea>
        """.write(to: folder.appendingPathComponent("times.html"), atomically: true, encoding: .utf8)
        let tab = browser.addTab(url: url), page = tab.page as! ChromiumPage
        browser.hidePalette()
        try await wait("The real Chromium page loads") { await self.value("return !!document.querySelector('#time')", page) as? Bool == true }
        let original = await value("return document.body.innerHTML", page) as? String
        let conversion = browser.timeReplacement.conversion(for: page)
        let expected = SelectionTimes.find(in: "10 AM PT").first.map { SelectionTimes.onPage($0) }!

        // Real context-menu request, with the selection's submenu, without opening a popup on screen.
        _ = await value("getSelection().selectAllChildren(document.querySelector('#time'));return 0", page)
        var context: NSMenu?
        browser.presentContextMenu = { menu, _, _ in context = menu }
        let rect = await value("const r=document.querySelector('#time').getBoundingClientRect();return [r.x+20,r.y+r.height/2]", page) as! [Double]
        let point = page.view.convert(NSPoint(x: rect[0], y: page.view.isFlipped ? rect[1] : page.view.bounds.height-rect[1]), to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            browser.window!.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try await wait("The time's native context menu arrives") { context != nil }
        let replace = context?.items.first?.submenu?.items.first { $0.title == "Replace on Page" }
        check(replace != nil, "The selected time offers Replace on Page beside its calendar actions")
        if let replace, let action = replace.action { NSApp.sendAction(action, to: replace.target, from: replace) }
        try await wait("The menu converts the page and shows its information panel") {
            await self.value("return document.querySelector('#time').textContent", page) as? String == expected && self.browser.timeReplacement.panel.isPresented
        }
        check(await value("return document.querySelector('#edit').value", page) as? String == "10 AM PT", "Editable fields remain untouched")
        browser.timeReplacement.panel.onRevert?()
        try await wait("The panel's Revert restores the exact original DOM") { await self.value("return document.body.innerHTML", page) as? String == original }

        // Quick press: preview begins on key down, then a release commits and announces it.
        var start = ProcessInfo.processInfo.systemUptime
        key(.keyDown, at: start); key(.keyUp, at: start+0.08)
        try await wait("A fast tap commits and reliably shows the notice") { conversion.isActive && self.browser.timeReplacement.panel.isPresented && conversion.count == 3 }
        start += 1; key(.keyDown, at: start); key(.keyUp, at: start+0.08)
        try await wait("A second tap restores the page") { await self.value("return document.body.innerHTML", page) as? String == original && !conversion.isActive }

        start += 1; key(.keyDown, at: start)
        await conversion.waitUntilReady()
        try await wait("Holding shows local times immediately") { await self.value("return document.querySelector('#time').textContent", page) as? String == expected }
        check(!browser.timeReplacement.panel.isPresented, "Holding does not show any notice")
        key(.keyDown, at: start+0.4, repeat: true)
        key(.keyUp, at: start+0.7)
        try await wait("Release restores a held preview without a notice") { await self.value("return document.body.innerHTML", page) as? String == original && !conversion.isActive }
        check(!browser.timeReplacement.panel.isPresented, "Key repeats never turn a hold into a tap")

        start += 1; key(.keyDown, at: start)
        try await wait("Another preview starts") { conversion.isActive }
        let other = browser.addTab(url: url)
        try await wait("Switching tabs cancels the preview on its original page") { await self.value("return document.body.innerHTML", page) as? String == original && !conversion.isActive }
        browser.select(tab.id)
        start += 1; key(.keyDown, at: start)
        try await wait("A preview starts after a tab change") { conversion.isActive }
        browser.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        try await wait("Losing focus restores the preview even without a key-up event") { !conversion.isActive }

        _ = other
        check(browser.keyboardShortcuts.set(TimeReplacement.command, at: 0, to: "Command+Alt+Y") == nil, "The tap/hold shortcut is customizable")
        start += 1; key(.keyDown, at: start, key: "y", code: 16); key(.keyUp, at: start+0.07, key: "y", code: 16)
        try await wait("The customized shortcut retains tap semantics") { conversion.isActive && self.browser.timeReplacement.panel.isPresented }
        start += 1; key(.keyDown, at: start, key: "y", code: 16)
        key(.keyUp, at: start+0.7, key: "y", code: 16)
        check(conversion.isActive && !browser.timeReplacement.panel.isPresented, "Holding an already-converted page preserves its previous state silently")
        _ = try await conversion.set(false)
        check(await value("return document.body.innerHTML", page) as? String == original, "The final page still restores exactly")

        start += 1; key(.keyDown, at: start, key: "y", code: 16)
        try await wait("The modifier-release preview starts") { conversion.isActive }
        key(.flagsChanged, at: start+0.7, key: "", code: 58, modifiers: .command)
        key(.keyUp, at: start+0.8, key: "y", code: 16, modifiers: .command)
        try await wait("Releasing a modifier restores the preview before the main key is released") { !conversion.isActive }

        browser.showPeek(url: url, from: page.view, animated: false)
        try await wait("A Peek page loads") {
            guard let peek = self.browser.peekTab?.page else { return false }
            return await self.value("return !!document.querySelector('#time')", peek) as? Bool == true
        }
        let peek = browser.peekTab!.page as! ChromiumPage
        start += 1; key(.keyDown, at: start, key: "y", code: 16); key(.keyUp, at: start+0.08, key: "y", code: 16)
        try await wait("The shortcut converts the frontmost Peek") {
            await self.value("return document.querySelector('#time').textContent", peek) as? String == expected && self.browser.timeReplacement.panel.isPresented
        }
        check(browser.timeReplacement.panel.superview === browser.peekCard?.subviews.first, "The information panel is inside Peek rather than behind it")
        check(await value("return document.body.innerHTML", page) as? String == original, "Converting Peek leaves the background page untouched")
        browser.timeReplacement.panel.onRevert?()
        try await wait("Peek's Revert restores its page") { await self.value("return document.querySelector('#time').textContent", peek) as? String == "10 AM PT" }
        browser.closePeek()
    }
}
