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

        // Rise's own buttons: pinned in the sidebar, and listed in the site controls.
        browser.select(second.id)
        browser.setExtension(id, pinned: true)
        _ = await waitUntil("Pinning it puts its button in the sidebar") { self.browser.sidebar.extensionButtons.map(\.extensionID) == [id] }
        if let button = browser.sidebar.extensionButtons.first {
            check(button.toolTip == "Rise Test", "The sidebar button has its title: \(button.toolTip ?? "none")")
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
        browser.siteMenu()
        _ = await waitUntil("The site controls open") { self.browser.siteControlsPopover.isShown }
        let listed = browser.siteControlsPopover.contentViewController?.view.subviews.compactMap { ($0 as? NSButton)?.toolTip } ?? []
        check(listed.contains("Rise Test Extension"), "The site controls list it: \(listed)")
        browser.siteControlsPopover.close()
        browser.setExtension(id, pinned: false)
        _ = await waitUntil("Unpinning takes its button away") { self.browser.sidebar.extensionButtons.isEmpty }
    }
}
