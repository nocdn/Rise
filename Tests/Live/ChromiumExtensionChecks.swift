import AppKit
import RiseChromium
@testable import Rise

/// Chrome extensions in Rise's Chromium pages: a test extension, loaded at startup, whose
/// background, content script and popup report what they see; and the Chrome Web Store, where
/// Rise's Add to Rise button takes the place of the store's Chrome one and installs extensions.
@main @MainActor struct ChromiumExtensionMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+480) { print("FAIL the check stopped answering"); exit(1) }
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
                    // A JavaScript null can arrive as NSNull, which is a non-nil Any.
                    // Require the async tabs.query report itself before inspecting its tab.
                    (await self.value("return document.body?.dataset.report ?? null", in: popup) as? String)?.isEmpty == false
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
            check(button.hoverHint?.text == "Rise Test" && button.toolTip == nil,
                  "The page bar button has its title in the toolbar's hover hint: \(button.hoverHint?.text ?? "none")")
            check(button.hoverHint?.shortcut == "⌥⇧1", "With its shortcut, the first from the left: \(button.hoverHint?.shortcut ?? "none")")
            // The pointer on its button starts the extension's process, with a page that runs none of it.
            browser.warmExtension(id, true)
            check(browser.extensionWarmer?.id == id && browser.extensionWarmer?.page.browserView.scriptsDisabled == true,
                  "Hovering its button readies the extension, running none of its scripts")
            check(browser.spareExtensionPopup?.page.browserView.extensionPopup == true && browser.spareExtensionPopup?.page.url == nil,
                  "And a popup's page, with nothing in it yet")
            button.performClick(nil)
            _ = await waitUntil("Clicking it opens its popup", 5) { self.browser.extensionPopup?.isShown == true }
            if let popup = browser.extensionPopup {
                check(popup.contentSize == NSSize(width: 240, height: 120) && popup.card.frame.size == popup.contentSize,
                      "The popup's card is the size of its page: \(popup.card.frame.size)")
                let buttonFrame = button.convert(button.bounds, to: browser.root)
                check(abs(popup.card.frame.maxX-buttonFrame.maxX) < 0.5 && popup.card.frame.minY > buttonFrame.maxY,
                      "Its right edge lines up with its button's, under it: \(popup.card.frame) \(buttonFrame)")
                check(popup.card.superview === browser.root && popup.card.layer?.animation(forKey: CardMotionAnimator.inKeys[0]) != nil,
                      "It's in the window, growing in as the hover cards do")
                // A page that takes another size as it comes in, as big popups do: the card grows to
                // the left, and its way in carries on, still out of its button.
                let resized = CACurrentMediaTime()
                _ = await value("document.body.style.width = '320px'; return 0", in: popup.page)
                _ = await waitUntil("The card takes the page's new size") { popup.card.frame.width == 320 }
                if let spring = popup.card.layer?.animation(forKey: CardMotionAnimator.inKeys[0]) as? CASpringAnimation,
                   let from = (spring.fromValue as? NSValue)?.caTransform3DValue, from.m11 != 1 {
                    let pivot = from.m41/(1-from.m11), expected = buttonFrame.midX-popup.card.frame.minX
                    check(abs(pivot-expected) < 1 && spring.beginTime > 0 && spring.beginTime < resized,
                          "Resized on its way in, it still grows out of its button, carrying on: \(pivot) \(expected) \(spring.beginTime) \(resized)")
                } else {
                    check(false, "Resized on its way in, it still grows out of its button: its way in had ended first")
                }
                _ = await value("document.body.style.width = '240px'; return 0", in: popup.page)
                _ = await waitUntil("The popup sees its tab") { (await self.value("return document.body?.dataset.report ?? ''", in: popup.page) as? String ?? "").contains("second.html") }
                let kind = await value("return document.body?.dataset.kind ?? ''", in: popup.page) as? String ?? ""
                check(kind == "popup", "Extensions see it as a popup, not a tab: \(kind)")
                // Once its motion has settled.
                if ProcessInfo.processInfo.environment["RISE_PEEK_OUT"] != nil { try? await Task.sleep(for: .milliseconds(700)) }
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
        _ = await waitUntil("Its button's shortcut opens its popup") { self.browser.extensionPopup?.isShown == true }
        if let popup = browser.extensionPopup {
            check(true, "Its button's shortcut opens its popup")
            popup.close()
            _ = await waitUntil("The popup closes") { self.browser.extensionPopup == nil }
        }
        // Real clicks, through the app as the mouse sends them: on its button again, and outside
        // the card. Each collapses it back into its button with the cards' way out, and the
        // button's click doesn't open it again.
        func click(at point: NSPoint) {
            guard let window = browser.window else { return }
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.sendEvent(event)
                }
            }
        }
        for (place, target) in [("its button", { (button: NSView) in button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil) }),
                                ("the page", { (_: NSView) in NSPoint(x: 500, y: 200) })] {
            guard let button = browser.navBar.extensionButtons.first else { break }
            // With RISE_PEEK_OUT, frames of the screen under the button as the card opens.
            let opening: CGRect? = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"] == nil ? nil : browser.window.map { window in
                let anchor = button.convert(button.bounds, to: nil)
                let rect = window.convertToScreen(NSRect(x: anchor.maxX-300, y: anchor.minY-180, width: 320, height: 200+anchor.height))
                return CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0)-rect.maxY, width: rect.width, height: rect.height)
            }
            // Pressed as the mouse does: it opens on the press.
            click(at: button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil))
            if let opening {
                var shots: [CGImage] = []
                let start = Date()
                while Date().timeIntervalSince(start) < 0.7 {
                    if let shot = CGWindowListCreateImage(opening, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) { shots.append(shot) }
                    try? await Task.sleep(for: .milliseconds(5))
                }
                for (index, shot) in shots.enumerated() {
                    try? NSBitmapImageRep(cgImage: shot).representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent("open-\(place == "its button" ? "button" : "page")-\(index).png"))
                }
            }
            _ = await waitUntil("Its button opens its popup, to click \(place)", 5) { self.browser.extensionPopup?.isShown == true }
            guard let popup = browser.extensionPopup else { continue }
            try? await Task.sleep(for: .milliseconds(600))
            let card = popup.card
            // With RISE_PEEK_OUT, frames of the screen around the card as it collapses.
            var frames: [CGImage] = []
            let area: CGRect? = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"] == nil ? nil : browser.window.map { window in
                let rect = window.convertToScreen(browser.root.convert(card.frame.insetBy(dx: -30, dy: -30), to: nil))
                return CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0)-rect.maxY, width: rect.width, height: rect.height)
            }
            if let area, let shot = CGWindowListCreateImage(area, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) { frames.append(shot) }
            let others = browser.root.subviews.filter { $0 is ExtensionPopupCard && $0 !== card }
            check(others.isEmpty, "Earlier popups' cards have all gone, before clicking \(place): \(others.count) left")
            click(at: target(button))
            let leaving = card.layer?.animation(forKey: CardMotionAnimator.outKeys[1]) != nil
            check(browser.extensionPopup == nil && leaving && card.superview != nil, "Clicking \(place) collapses it with the cards' way out")
            if let area {
                let start = Date()
                while Date().timeIntervalSince(start) < 0.3 {
                    if let shot = CGWindowListCreateImage(area, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) { frames.append(shot) }
                    try? await Task.sleep(for: .milliseconds(8))
                }
                for (index, frame) in frames.enumerated() {
                    try? NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?
                        .write(to: folder.appendingPathComponent("collapse-\(place == "its button" ? "button" : "page")-\(index).png"))
                }
            }
            _ = await waitUntil("And it goes once it has collapsed, after clicking \(place)") { card.superview == nil }
            try? await Task.sleep(for: .milliseconds(1200))
            check(browser.extensionPopup == nil && !browser.root.subviews.contains { $0 is ExtensionPopupCard },
                  "Clicking \(place) doesn't open it again, and leaves no card behind")
        }
        browser.siteMenu()
        _ = await waitUntil("The site controls open") { self.browser.siteControlsPopover.isShown }
        let listed = browser.siteControlsPopover.contentViewController?.view.subviews.compactMap { ($0 as? NSButton)?.toolTip } ?? []
        check(listed.contains("Rise Test Extension"), "The site controls list it: \(listed)")
        browser.siteControlsPopover.close()
        // Pinned, its own request opens the popup under its button, as clicking it does.
        if let button = browser.navBar.extensionButtons.first(where: { $0.extensionID == id }) {
            _ = await ask(["cmd": "popup"], in: second.page)
            _ = await waitUntil("Its own request opens its popup", 3) { self.browser.extensionPopup?.isShown == true }
            check(browser.extensionPopup?.anchor === button, "Under its pinned button")
            browser.extensionPopup?.close()
            _ = await waitUntil("And it closes") { self.browser.extensionPopup == nil }
        }
        browser.setExtension(id, pinned: false)
        _ = await waitUntil("Unpinning takes its button away") { self.browser.navBar.extensionButtons.isEmpty }
        // Password managers use this API to return to their popup after their desktop app
        // unlocks. It must reach Rise's popup host even when the extension isn't pinned.
        let requested = await ask(["cmd": "popup"], in: second.page)
        check(requested?["opened"] as? Bool == true, "chrome.action.openPopup resolves successfully: \(requested ?? [:])")
        _ = await waitUntil("The extension's openPopup request opens its popup", 3) { self.browser.extensionPopup?.isShown == true }
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
        let dismissed = ExtensionPopup()
        var answers: [Bool] = []
        dismissed.onShown = { answers.append($0) }
        browser.raiseHoverCard(dismissed.card)
        dismissed.show(under: browser.navBar.settingsButton)
        dismissed.load(URL(string: "chrome-extension://\(id)/popup.html")!)
        dismissed.close()
        try? await Task.sleep(for: .milliseconds(1100))
        check(answers == [false] && !dismissed.isShown && dismissed.card.superview == nil,
              "Closing a pending popup answers once and cannot reopen after the fallback")

        await webStoreChecks()
    }

    /// An extension that's small, long-lived and opens nothing as it installs.
    let storeExtension = (id: "bcjindcccaagfpapjjmafapmmgkkhgoa", name: "JSON Formatter")

    /// The Chrome Web Store offers Chrome only. In its place, Rise's Add to Rise button, in sight
    /// under the listing's title, whether the listing was opened or reached through the store's own
    /// pages, which keep the pages they move on from in the page, hidden; and installing through
    /// Rise's sheet. It needs the network.
    func webStoreChecks() async {
        let store = "https://chromewebstore.google.com"
        func load(_ path: String) async -> BrowserTab {
            let tab = browser.addTab(url: URL(string: store + path)!)
            browser.select(tab.id)
            _ = await waitUntil("The Web Store loads \(path)", 30) { !tab.page.isLoading && tab.page.url?.host != nil }
            if tab.page.url?.host == "consent.google.com" {
                // Google asks about cookies first, here.
                _ = await value("const b = [...document.querySelectorAll('button')].find(b => /Reject all/i.test(b.textContent)); b?.click(); return !!b", in: tab.page)
                _ = await waitUntil("The Web Store loads after Google's cookie question", 30) {
                    !tab.page.isLoading && tab.page.url?.host == "chromewebstore.google.com"
                }
            }
            return tab
        }
        /// Rise's button: what it says, whether it's in sight and on top, the heading before it, and
        /// any of the store's Chrome offers in sight.
        func button(in page: WebPage) async -> [String: Any] {
            let text = await value("""
                const offers = [...document.querySelectorAll('body *')].filter(n => !n.childElementCount && n.getClientRects().length &&
                  /^(Add to Chrome|Install Chrome|Switch to Chrome to install extensions and themes)$/.test(n.textContent.trim())).map(n => n.textContent.trim());
                const b = [...document.querySelectorAll('button')].find(b => /^Add(ed)? to Rise$/.test(b.textContent.trim()));
                if (!b) return JSON.stringify({offers});
                const r = b.getBoundingClientRect(), hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
                const title = b.previousElementSibling;
                return JSON.stringify({text: b.textContent.trim(), size: [r.width, r.height], onTop: !!hit && (hit === b || b.contains(hit)), offers,
                  title: title?.tagName === 'H1' && title.getClientRects().length ? title.textContent.trim() : null});
                """, in: page) as? String
            return text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
        }
        func inSight(_ seen: [String: Any]) -> Bool {
            let size = seen["size"] as? [Double] ?? []
            return size.count == 2 && size[0] > 0 && size[1] > 0 && seen["onTop"] as? Bool == true
        }
        let (id, name) = storeExtension

        // Opened directly.
        let listing = await load("/detail/\(id)")
        var seen: [String: Any] = [:]
        _ = await waitUntil("Add to Rise shows on \(name)'s listing", 20) { seen = await button(in: listing.page); return inSight(seen) }
        check(inSight(seen) && (seen["title"] as? String)?.contains(name) == true && seen["text"] as? String == "Add to Rise",
              "A listing shows Add to Rise in sight, under its title: \(seen)")
        check((seen["offers"] as? [String])?.isEmpty == true, "And none of the store's Chrome offers: \(seen["offers"] ?? "none")")
        browser.closeTab(listing.id)

        // Reached through the store's search, as most are: the store opens the listing in the same
        // page, keeping the results in it, hidden, with their heading before the listing's.
        let search = await load("/search/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)")
        _ = await waitUntil("The store's search lists \(name)", 20) {
            await self.value("return !!document.querySelector('a[href*=\(id)]')", in: search.page) as? Bool == true
        }
        // Once the store's own scripts run, as they do by the time anyone clicks: before, the link
        // loads a new page.
        try? await Task.sleep(for: .seconds(4))
        _ = await value("window.riseSamePage = true; document.querySelector('a[href*=\(id)]').click(); return 0", in: search.page)
        _ = await waitUntil("Its link opens the listing", 20) { search.page.url?.path.contains(id) == true }
        _ = await waitUntil("Add to Rise shows on the listing reached from the search", 20) { seen = await button(in: search.page); return inSight(seen) }
        let samePage = await value("return window.riseSamePage === true", in: search.page) as? Bool == true
        let headings = await value("return [...document.querySelectorAll('h1')].map(h => h.textContent.trim() + (h.getClientRects().length ? '' : ' (hidden)')).join(', ')",
                                   in: search.page) as? String ?? ""
        check(inSight(seen) && (seen["title"] as? String)?.contains(name) == true,
              "Reached from the store's search (\(samePage ? "the same page" : "a new page"), headings: \(headings)), the listing shows Add to Rise in sight, under its own title: \(seen)")
        // However the store keeps its pages that day: a hidden heading before the listing's, as the
        // results' is, leaves Add to Rise under the listing's title, in sight.
        // (The store takes no HTML as text, only made elements.)
        let kept = await value("""
            const kept = document.createElement('div'), heading = document.createElement('h1');
            kept.id = 'rise-kept-page'; kept.hidden = true; heading.textContent = 'Search results'; kept.append(heading);
            (document.querySelector('main') || document.body).prepend(kept);
            return document.querySelector('main h1, h1') === heading
            """, in: search.page) as? Bool == true
        try? await Task.sleep(for: .milliseconds(800))
        seen = await button(in: search.page)
        check(kept && inSight(seen) && (seen["title"] as? String)?.contains(name) == true,
              "With a hidden page's heading first, before the listing's, Add to Rise stays under the listing's title, in sight: \(kept ? "\(seen)" : "the heading didn't go in")")
        _ = await value("document.getElementById('rise-kept-page')?.remove(); return 0", in: search.page)
        // Back to the results, which have no Add to Rise, and forward to the listing, which has, when
        // the store went to the listing in the same page.
        if samePage {
            _ = await value("history.back(); return 0", in: search.page)
            _ = await waitUntil("Back goes to the results", 20) { search.page.url?.path.hasPrefix("/search") == true && !search.page.isLoading }
            _ = await waitUntil("Add to Rise goes with the listing", 10) { !inSight(await button(in: search.page)) }
            let atResults = await button(in: search.page)
            check(search.page.url?.path.hasPrefix("/search") == true && !inSight(atResults),
                  "Back at the results, which show no Add to Rise: \(search.page.url?.absoluteString ?? "no page")")
            _ = await value("history.forward(); return 0", in: search.page)
            _ = await waitUntil("Forward brings the listing back, with Add to Rise in sight", 20) {
                guard search.page.url?.path.contains(id) == true else { return false }
                return inSight(await button(in: search.page))
            }
        } else {
            print("NOTE The store loaded the listing as a new page, so Back and Forward within its page weren't checked")
        }

        // Adding it: Rise's sheet asks, and it installs, pinned, with the button saying so.
        check(!browser.isExtensionInstalled(id), "\(name) isn't installed yet")
        _ = await value("[...document.querySelectorAll('button')].find(b => b.textContent.trim() === 'Add to Rise').click(); return 0", in: search.page)
        var sheet: (text: [String], buttons: [NSButton])?
        _ = await waitUntil("Add to Rise asks with Rise's install sheet", 60) { sheet = self.installSheet(); return sheet != nil }
        check(sheet?.text.contains { $0.contains(name) } == true, "Rise's sheet names \(name): \(sheet?.text ?? [])")
        sheet?.buttons.first { $0.title != "Cancel" }?.performClick(nil)
        _ = await waitUntil("\(name) installs", 60) { self.browser.isExtensionInstalled(id) }
        check(browser.isExtensionInstalled(id) && browser.pinnedExtensions.contains(id), "\(name) installs, pinned in the page bar")
        _ = await waitUntil("The button says it's added", 10) { await button(in: search.page)["text"] as? String == "Added to Rise" }
        let files = folder.appendingPathComponent("chromium/Default/Extensions/\(id)")
        check(!((try? FileManager.default.contentsOfDirectory(atPath: files.path)) ?? []).isEmpty, "Its files are in the profile")
    }

    /// Rise's install sheet on the window, if it's showing: its text and its buttons.
    func installSheet() -> (text: [String], buttons: [NSButton])? {
        guard let sheet = browser.window?.attachedSheet, let content = sheet.contentView else { return nil }
        var text: [String] = [], buttons: [NSButton] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { text.append(field.stringValue) }
            if let button = view as? NSButton, !button.title.isEmpty { buttons.append(button) }
            view.subviews.forEach(walk)
        }
        walk(content)
        return (text, buttons)
    }
}
