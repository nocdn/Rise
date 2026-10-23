import AppKit
import RiseChromium
@testable import Rise

/// Chrome extensions in Rise's Chromium pages: a test extension, loaded at startup, whose
/// background, content script and popup report what they see.
@main @MainActor struct ChromiumExtensionMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+240) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ExtensionChecks(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ExtensionChecks: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    let suite = "RiseExtensionCheck-\(UUID().uuidString)"
    let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",").first.map(String.init)!
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }

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
        return URL(string: "http://localhost:\(port)/\(name).html")!
    }
    func open(_ url: URL) async -> BrowserTab {
        let tab = browser.addTab(url: url)
        _ = await waitUntil("\(url.lastPathComponent) loads") { tab.page.url == url && !tab.page.isLoading }
        return tab
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await checks() } catch { check(false, "\(error)") }
            UserDefaults.standard.removePersistentDomain(forName: suite)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func checks() async throws {
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: UserDefaults(suiteName: suite)!)
        browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        let first = await open(try page("first", "<h1>First</h1>"))
        let second = await open(try page("second", "<h1>Second</h1>"))
        func json(_ key: String, in page: WebPage) async -> [String: Any]? {
            guard let text = await value("return document.documentElement.dataset.\(key) ?? null", in: page) as? String else { return nil }
            return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        /// Asks the extension's background, through its content script in `page`.
        func ask(_ message: [String: Any], in page: WebPage) async -> [String: Any]? {
            let body = String(decoding: try! JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            _ = await value("delete document.documentElement.dataset.riseAnswer; postMessage({riseTest: \(body)}, '*'); return 0", in: page)
            var answer: [String: Any]?
            _ = await waitUntil("The extension answers \(body)") { answer = await json("riseAnswer", in: page); return answer != nil }
            return answer
        }

        // The content script runs in Rise's pages, and its background sees Rise's window and tabs.
        _ = await waitUntil("The extension's content script runs in Rise's pages") { await json("riseExtension", in: second.page) != nil }
        let id = (await value("return document.documentElement.dataset.riseExtensionId ?? null", in: second.page) as? String) ?? ""
        check(!id.isEmpty, "The extension's content script runs, as extension \(id)")
        guard let seen = await ask([:], in: second.page) else { return }
        let all = seen["all"] as? [[Any]] ?? [], windows = seen["windows"] as? [[Any]] ?? []
        let secondID = seen["tab"] as? Int ?? -1
        check(all.count == browser.tabs.count && all.contains { ($0[1] as? String)?.hasSuffix("first.html") == true },
              "tabs.query lists Rise's tabs: \(all)")
        check(seen["active"] as? [Int] == [secondID], "The active tab in the current window is the selected one: \(seen["active"] ?? "none")")
        check(windows.count == 1 && windows.first?[2] as? Int == browser.tabs.count, "windows.getAll lists Rise's window with its tabs: \(windows)")
        check(seen["index"] as? Int == all.firstIndex { $0[0] as? Int == secondID }, "A tab's index is its place in the sidebar")

        // A password manager's transport: Chromium finds a linked native host, starts it, and
        // exchanges framed JSON. The host's extension allowlist must still be enforced.
        let registrations = folder.appendingPathComponent("native-host-registrations")
        try FileManager.default.createDirectory(at: registrations, withIntermediateDirectories: true)
        let host = folder.appendingPathComponent("native-echo.py")
        try """
        #!/usr/bin/env python3
        import struct, sys
        header = sys.stdin.buffer.read(4)
        if len(header) == 4:
            body = sys.stdin.buffer.read(struct.unpack('=I', header)[0])
            sys.stdout.buffer.write(struct.pack('=I', len(body)) + body)
            sys.stdout.buffer.flush()
        """.write(to: host, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: host.path)
        let registration = registrations.appendingPathComponent("dev.bartosz.rise.test.echo.json")
        func registerHost(allowed: String) throws {
            let manifest: [String: Any] = ["name": "dev.bartosz.rise.test.echo", "description": "Rise native messaging test",
                                         "path": host.path, "type": "stdio", "allowed_origins": ["chrome-extension://\(allowed)/"]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: registration)
        }
        try registerHost(allowed: id)
        NativeMessagingHosts.link(into: folder.appendingPathComponent("chromium/NativeMessagingHosts"), from: [registrations])
        let echo = await ask(["cmd": "native", "payload": ["text": "Rise native messaging", "number": 42]], in: second.page)
        check(echo?["text"] as? String == "Rise native messaging" && echo?["number"] as? Int == 42,
              "The extension reaches a linked desktop host and receives its JSON response: \(echo ?? [:])")
        try registerHost(allowed: String(repeating: "a", count: 32))
        let refused = await ask(["cmd": "native", "payload": ["text": "must not reach the host"]], in: second.page)
        check((refused?["error"] as? String)?.localizedCaseInsensitiveContains("forbidden") == true,
              "The native host's extension allowlist is enforced: \(refused ?? [:])")
        try FileManager.default.removeItem(at: registration)
        NativeMessagingHosts.link(into: folder.appendingPathComponent("chromium/NativeMessagingHosts"), from: [registrations])

        // Switching tabs in Rise tells the extension.
        browser.select(first.id)
        let firstID = (await ask([:], in: first.page))?["tab"] as? Int ?? -1
        _ = await waitUntil("tabs.onActivated hears Rise switch tabs") {
            let activated = (await ask(["cmd": "activated"], in: first.page))?["activated"] as? [Int] ?? []
            return activated.last == firstID
        }
        // The extension opens, switches to and closes tabs in Rise.
        let count = browser.tabs.count
        let made = await ask(["cmd": "create", "url": "http://localhost:\(port)/second.html?made"], in: first.page)
        _ = await waitUntil("tabs.create opens a tab in Rise") { self.browser.tabs.count == count+1 && self.browser.selectedTab?.page.url?.query == "made" }
        check(made?["id"] as? Int != nil, "And gives the extension its tab: \(made ?? [:])")
        _ = await ask(["cmd": "activate", "id": secondID], in: first.page)
        _ = await waitUntil("tabs.update brings a tab forward in Rise") { self.browser.selectedID == second.id }
        if let madeID = made?["id"] as? Int {
            _ = await ask(["cmd": "remove", "id": madeID], in: first.page)
            _ = await waitUntil("tabs.remove closes it in Rise") { self.browser.tabs.count == count }
        }

        // Its entry in the page menu, for a selection, which it hears chosen.
        _ = await value("getSelection().selectAllChildren(document.querySelector('h1')); return 0", in: second.page)
        if let window = browser.window, let at = await value("const r = document.querySelector('h1').getBoundingClientRect(); return [r.x + 10, r.y + r.height / 2]", in: second.page) as? [Double] {
            let view = second.page.view
            let point = view.convert(NSPoint(x: at[0], y: view.isFlipped ? at[1] : view.bounds.height-at[1]), to: nil)
            var shown: NSMenu?
            browser.presentContextMenu = { menu, _, _ in shown = menu }
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .rightMouseDown ? 1 : 0) { window.sendEvent(event) }
            }
            _ = await waitUntil("A right-click on the selection opens Rise's menu") { shown != nil }
            let entry = shown?.items.first { $0.title == "Rise Test “Second”" }
            check(entry != nil, "The page menu has the extension's entry: \(shown?.items.map(\.title) ?? [])")
            if let entry, let action = entry.action { NSApp.sendAction(action, to: entry.target, from: entry) }
            var clicked: [Any] = []
            _ = await waitUntil("Choosing it tells the extension") {
                clicked = (await ask(["cmd": "clicked"], in: second.page))?["clicked"] as? [Any] ?? []
                return !clicked.isEmpty
            }
            check(clicked.first as? String == "rise-test" && clicked.dropFirst().first as? String == "Second" && clicked.last as? Int == secondID,
                  "With the selection and the tab: \(clicked)")
        }

        // Its toolbar button, and its popup, which sees the tab it was opened over.
        let actions = RCExtensions.actions
        check(actions.contains { $0.extensionID == id && $0.name == "Rise Test Extension" }, "Its toolbar button: \(actions.map(\.name))")
        if let action = actions.first(where: { $0.extensionID == id }), let view = (second.page as? ChromiumPage)?.browserView {
            check(action.title(forTab: view) == "Rise Test", "With its title")
            let popupURL = action.click(inTab: view)
            check(popupURL?.absoluteString == "chrome-extension://\(id)/popup.html", "Clicking it gives its popup: \(popupURL?.absoluteString ?? "none")")
            if let popupURL {
                let popup = ChromiumPage()
                popup.view.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
                browser.window?.contentView?.addSubview(popup.view)
                popup.load(popupURL)
                _ = await waitUntil("The popup loads in a page of Rise's", 15) {
                    await self.value("return document.body?.dataset.report ?? null", in: popup) != nil
                }
                let report = await value("return document.body?.dataset.report ?? null", in: popup) as? String ?? ""
                check(report.contains("\(secondID)") && report.contains("second.html"), "The popup's active tab is the one it opened over: \(report)")
                popup.view.removeFromSuperview()
            }
            check(action.icon(forTab: view) != nil, "Its icon loads")
        }

        // Rise's own buttons: pinned in the page bar, and listed in the site controls.
        browser.select(second.id)
        browser.setExtension(id, pinned: true)
        _ = await waitUntil("Pinning it puts its button in the page bar") { self.browser.navBar.extensionButtons.map(\.extensionID) == [id] }
        if let button = browser.navBar.extensionButtons.first {
            check(button.toolTip == "Rise Test", "The page bar button has its title: \(button.toolTip ?? "none")")
            button.performClick(nil)
            _ = await waitUntil("Clicking it opens its popup", 5) { self.browser.extensionPopup?.popover.isShown == true }
            if let popup = browser.extensionPopup {
                check(popup.popover.contentSize == NSSize(width: 240, height: 120), "The popup is the size of its page: \(popup.popover.contentSize)")
                _ = await waitUntil("The popup sees its tab") { (await self.value("return document.body?.dataset.report ?? ''", in: popup.page) as? String ?? "").contains("second.html") }
                let kind = await value("return document.body?.dataset.kind ?? ''", in: popup.page) as? String ?? ""
                check(kind == "popup", "Extensions see it as a popup, not a tab: \(kind)")
                if ProcessInfo.processInfo.environment["RISE_PEEK_OUT"] != nil, let shot = CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) {
                    try? NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("extension-popup.png"))
                }
                _ = await value("window.close(); return 0", in: popup.page)
                _ = await waitUntil("window.close() closes the popup") { self.browser.extensionPopup == nil }
            }
        }
        // Its keyboard shortcuts, pressed in Rise's window: one it hears, with the tab, and its
        // button's, which opens its popup as a click does.
        func press(_ key: String, _ code: UInt16) {
            guard let window = browser.window, let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: key.uppercased(), charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code) else { return }
            window.sendEvent(event)
        }
        press("y", 16)
        var commanded: [Any] = []
        _ = await waitUntil("Its shortcut tells the extension") {
            commanded = (await ask(["cmd": "commanded"], in: second.page))?["commanded"] as? [Any] ?? []
            return !commanded.isEmpty
        }
        check(commanded.first as? String == "rise-test-command" && commanded.last as? Int == secondID, "Its shortcut runs its command, for the tab: \(commanded)")
        press("u", 32)
        _ = await waitUntil("Its button's shortcut opens its popup") { self.browser.extensionPopup?.popover.isShown == true }
        if let popup = browser.extensionPopup {
            check(true, "Its button's shortcut opens its popup")
            popup.close()
            _ = await waitUntil("The popup closes") { self.browser.extensionPopup == nil }
        }
        browser.siteMenu()
        _ = await waitUntil("The site controls open") { self.browser.siteControlsPopover.isShown }
        let listed = browser.siteControlsPopover.contentViewController?.view.subviews.compactMap { ($0 as? NSButton)?.toolTip } ?? []
        check(listed.contains("Rise Test Extension"), "The site controls list it: \(listed)")
        browser.siteControlsPopover.close()
        browser.setExtension(id, pinned: false)
        _ = await waitUntil("Unpinning takes its button away") { self.browser.navBar.extensionButtons.isEmpty }
        // Password managers use this API to return to their popup after their desktop app
        // unlocks. It must reach Rise's popup host even when the extension isn't pinned.
        let requested = await ask(["cmd": "popup"], in: second.page)
        check(requested?["opened"] as? Bool == true, "chrome.action.openPopup resolves successfully: \(requested ?? [:])")
        _ = await waitUntil("The extension's openPopup request opens its popup", 3) { self.browser.extensionPopup?.popover.isShown == true }
        if let popup = browser.extensionPopup {
            let duplicate = await ask(["cmd": "popup"], in: second.page)
            check(duplicate?["error"] as? String != nil && browser.extensionPopup === popup,
                  "A duplicate popup request fails without replacing the existing popup: \(duplicate ?? [:])")
            _ = await waitUntil("The API-opened popup sees the selected tab") {
                (await self.value("return document.body?.dataset.report ?? ''", in: popup.page) as? String ?? "").contains("second.html")
            }
            popup.close()
        }
        // A window/popup may close before its first size report. The API callback must finish
        // once, and the delayed fallback must not resurrect the dismissed popup.
        let dismissed = ExtensionPopup(url: URL(string: "chrome-extension://\(id)/popup.html")!, theme: browser.theme)
        var answers: [Bool] = []
        dismissed.onShown = { answers.append($0) }
        dismissed.show(relativeTo: browser.navBar.settingsButton.bounds, of: browser.navBar.settingsButton)
        dismissed.close()
        try? await Task.sleep(for: .milliseconds(1100))
        check(answers == [false] && !dismissed.popover.isShown,
              "Closing a pending popup answers once and cannot reopen after the fallback")
    }
}
