// DevTools in a real Rise window, as Chrome's work: their menus, their close button, filling
// their panel, device mode around the page, their downloads, saving and choosing files, and
// ⌥⌘J and ⌥⌘K switching between Elements and the console or putting them away.
// Run with python3 scripts/test-chromium-live.py devtools.
import AppKit
@testable import Rise
import RiseCore
import RiseChromium

@main @MainActor struct ChromiumDevToolsMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let limit = Double(ProcessInfo.processInfo.environment["RISE_CHECK_TIMEOUT"] ?? "") ?? 240
        DispatchQueue.main.asyncAfter(deadline: .now()+limit) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumDevToolsRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumDevToolsRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    let suite = "RiseChromiumCheck-\(UUID().uuidString)"
    let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",").map(String.init)
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    @discardableResult
    func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { print("FAIL timed out:", what); failures += 1; return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        print("PASS", what)
        return true
    }
    func value(_ script: String, in page: WebPage) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: nil, world: .page)
    }
    /// Runs a script in DevTools' own page.
    func value(_ script: String, in view: RCBrowserView) async -> Any? {
        await withCheckedContinuation { done in view.evaluateFunctionBody(script, arguments: [:], frame: nil, world: nil) { value, _ in done.resume(returning: value) } }
    }
    /// A real click in `view`, at a point from its top left, as a person's.
    func click(_ view: NSView, at point: NSPoint) async {
        guard let window = view.window else { return }
        let location = view.convert(NSPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height-point.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(60))
        }
    }
    /// A panel for saving or opening files that's up.
    var filePanel: NSSavePanel? { NSApp.windows.compactMap { $0 as? NSSavePanel }.first { $0.isVisible } }
    /// Answers a file panel as its Save or Open, or Cancel, button would: macOS's panels run in a
    /// process of their own and don't take ok(_:), but end as their window's sheet.
    func finish(_ panel: NSSavePanel, ok: Bool) -> Bool {
        guard let parent = panel.sheetParent else { return false }
        parent.endSheet(panel, returnCode: ok ? .OK : .cancel)
        return true
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
        browser.downloadsFolder = folder.appendingPathComponent("Downloads")
        try? FileManager.default.createDirectory(at: browser.downloadsFolder, withIntermediateDirectories: true)
        browser.window?.setContentSize(NSSize(width: 1400, height: 860)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        try "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'><title>inspected</title><h1>Inspected</h1>"
            .write(to: folder.appendingPathComponent("inspected.html"), atomically: true, encoding: .utf8)
        let url = URL(string: "http://localhost:\(ports[0])/inspected.html")!
        let tab = browser.addTab(url: url)
        await waitUntil("The page loads") { tab.page.url == url && !tab.page.isLoading }
        browser.toggleDevTools()
        await waitUntil("DevTools slide in") { self.browser.devTools.isOpen && self.browser.devTools.progress == 1 }
        guard let frontend = browser.devTools.clip.subviews.first as? RCBrowserView else { check(false, "DevTools are in the panel"); return }
        await waitUntil("They inspect the page", 20) { frontend.title?.contains("inspected.html") == true }
        let legacy = "const UI = await import('./ui/legacy/legacy.js');"
        let selectedTab = legacy + "return UI.InspectorView.InspectorView.instance().tabbedPane.selectedTabId"
        await waitUntil("On the Elements panel", 10) { await self.value(selectedTab, in: frontend) as? String == "elements" }
        let picking = legacy + "return UI.ActionRegistry.ActionRegistry.instance().getAction('elements.toggle-element-search').toggled()"
        await waitUntil("Ready to select an element", 10) { await self.value(picking, in: frontend) as? Bool == true }
        _ = await value(legacy + "const action = UI.ActionRegistry.ActionRegistry.instance().getAction('elements.toggle-element-search'); if (action.toggled()) await action.execute(); return 0", in: frontend)

        // They fill their panel, with no room kept beside them for a page.
        let fill = await value(legacy + "return UI.InspectorView.InspectorView.instance().element.getBoundingClientRect().width / innerWidth", in: frontend) as? Double ?? 0
        check(fill > 0.99, "DevTools fill their panel: \(fill)")
        let deep = """
        const all = (root, selector, found = []) => {
          root.querySelectorAll(selector).forEach(node => found.push(node));
          root.querySelectorAll('*').forEach(node => node.shadowRoot && all(node.shadowRoot, selector, found));
          return found;
        };
        """
        // Their menus offer no other places to dock.
        check(await value(legacy + "return UI.DockController.DockController.instance().canDock()", in: frontend) as? Bool == false, "Their menu offers no other places to dock")

        // Their menus are Rise's: their entries, chosen as a person would while it's open. Chromium
        // runs a menu's entries in the frame that has focus, as DevTools' has once clicked in: a
        // click on the <h1>'s row selects it.
        browser.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let row = deep + """
        const node = all(document, 'li').find(item => item.textContent.startsWith('<h1') && item.textContent.includes('Inspected'));
        if (!node) return null; const box = node.getBoundingClientRect(); return [box.left+30, box.top+box.height/2];
        """
        if let point = await value(row, in: frontend) as? [Double], point.count == 2 {
            await click(frontend, at: NSPoint(x: point[0], y: point[1]))
        } else { check(false, "The <h1>'s row is in the Elements tree") }
        await waitUntil("DevTools have focus", 10) { await self.value("return document.hasFocus()", in: frontend) as? Bool == true }
        var shown: [String] = [], choose: String?
        let present = browser.presentContextMenu
        browser.presentContextMenu = { menu, _, _ in
            func titles(_ menu: NSMenu) -> [String] { menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) } }
            shown = titles(menu)
            if let choose, let index = menu.items.firstIndex(where: { $0.title == choose }) {
                menu.performActionForItem(at: index)
            }
        }
        choose = "Network"
        _ = await value(legacy + "UI.InspectorView.InspectorView.instance().tabbedPane.dropDownButton.dispatchEvent(new MouseEvent('click', {bubbles: true, button: 0})); return 0", in: frontend)
        if await waitUntil("The » opens DevTools' menu of their other tabs", 10, { shown.contains("Network") }) {
            await waitUntil("And opens the tab chosen", 10) { await self.value(selectedTab, in: frontend) as? String == "network" }
        }
        _ = await value(legacy + "await UI.ViewManager.ViewManager.instance().showView('elements'); return 0", in: frontend)
        shown = []; choose = "Hide element"
        let rightClick = deep + """
        const node = all(document, 'li').find(item => item.textContent.startsWith('<h1') && item.textContent.includes('Inspected'));
        if (!node) return false;
        const box = node.getBoundingClientRect();
        node.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, composed: true, button: 2, clientX: box.left+8, clientY: box.top+4}));
        return true;
        """
        await waitUntil("The <h1> is in the Elements tree", 10) { await self.value(rightClick, in: frontend) as? Bool == true }
        if await waitUntil("A node's right-click shows DevTools' menu", 10, { shown.contains("Edit as HTML") }) {
            check(shown.contains("Copy selector"), "With its submenus")
            await waitUntil("Hide element hides it in the page", 10) {
                await self.value("return document.querySelector('h1').classList.contains('__web-inspector-hide-shortcut__')", in: tab.page) as? Bool == true
            }
        }
        browser.presentContextMenu = present

        // Device mode: their toolbar and rulers in the page's place, around it, as in Chrome.
        let panel = browser.devTools, page = tab.page.view
        await waitUntil("DevTools' toolbox is under the page", 10) { panel.toolbox?.superview === page.superview && panel.toolbox?.isHidden == false }
        let body = page.frame
        let width = await value("return innerWidth", in: tab.page) as? Double ?? 0
        let deviceMode = legacy + "await UI.ActionRegistry.ActionRegistry.instance().getAction('emulation.toggle-device-mode').execute(); return 0"
        _ = await value(deviceMode, in: frontend)
        if await waitUntil("Device mode puts the page on its screen", 10, { panel.isInDeviceMode }) {
            await waitUntil("Inside the toolbox, under its toolbar", 10) { page.frame.width < body.width && page.frame.height < body.height && body.contains(page.frame) }
            await waitUntil("The page is laid out at the screen's size") {
                let inner = await self.value("return innerWidth", in: tab.page) as? Double ?? 0
                return abs(inner-Double(page.frame.width)) < 2 && inner != width
            }
            let toolbar = await value(deep + "return all(document, '.device-mode-toolbar').length", in: panel.toolbox!) as? Int ?? 0
            check(toolbar > 0, "With device mode's toolbar in the toolbox")
            _ = await value(deviceMode, in: frontend)
            await waitUntil("Device mode off, the page fills its place again", 10) { !panel.isInDeviceMode && page.frame == body }
            await waitUntil("At its own width") { await self.value("return innerWidth", in: tab.page) as? Double == width }
        }

        // A screenshot DevTools take downloads, as a page's downloads do.
        let download = """
        const canvas = new OffscreenCanvas(4, 4); canvas.getContext('2d').fillRect(0, 0, 4, 4);
        const link = document.createElement('a'); link.download = 'rise-devtools-shot.png';
        link.href = URL.createObjectURL(await canvas.convertToBlob({type: 'image/png'})); link.click(); return 0
        """
        _ = await value(download, in: frontend)
        await waitUntil("A DevTools screenshot downloads into Downloads", 10) {
            (try? FileManager.default.contentsOfDirectory(atPath: self.browser.downloadsFolder.path))?.contains { $0.hasPrefix("rise-devtools-shot") } == true
        }

        // Saving, as Save all as HAR and Save as do: a save panel, then the file.
        _ = await value("const Host = await import('./core/host/host.js'); Host.InspectorFrontendHost.InspectorFrontendHostInstance.save('rise-check.har', 'saved by DevTools', true, false); return 0", in: frontend)
        if await waitUntil("DevTools' Save shows a save panel", 10, { self.filePanel != nil }), let save = filePanel {
            save.directoryURL = folder; save.nameFieldStringValue = "rise-check.har"
            // Saved, it would go where the panel says, in the person's Downloads, not the check's.
            check(finish(save, ok: false), "It's a sheet on Rise's window")
        }

        // Choosing a file, as Load profile does: a real click on a file input in DevTools.
        _ = await value("const input = document.createElement('input'); input.type = 'file'; input.id = 'rise-check-file'; input.style.cssText = 'position:fixed;left:0;top:0;width:300px;height:120px;z-index:99999;opacity:1'; document.body.append(input); return 0", in: frontend)
        try await Task.sleep(for: .milliseconds(300))
        await click(frontend, at: NSPoint(x: 60, y: 40))
        if await waitUntil("A file input in DevTools shows an open panel", 10, { self.filePanel is NSOpenPanel }) {
            if let open = filePanel { check(finish(open, ok: false), "It's a sheet on Rise's window") }
        }
        _ = await value("document.getElementById('rise-check-file')?.remove(); return 0", in: frontend)

        // Their close button closes them.
        let close = deep + "const button = all(document, '.close-devtools')[0]; if (!button?.checkVisibility()) return false; button.click(); return true"
        await waitUntil("DevTools show their close button, which closes them", 10) { await self.value(close, in: frontend) as? Bool == true }
        await waitUntil("They close") { panel.shadow.isHidden && panel.tabID == nil && panel.toolbox == nil }
        check(page.frame == browser.pageBody, "The page has its place back")

        // ⌥⌘K opens them on the console; ⌥⌘J switches to Elements, picking; ⌥⌘K back to the
        // console, not picking; and each, on its own panel, puts them away.
        browser.toggleDevToolsConsole()
        await waitUntil("⌥⌘K slides them in") { panel.isOpen && panel.progress == 1 }
        guard let console = panel.clip.subviews.first as? RCBrowserView else { check(false, "DevTools are in the panel again"); return }
        await waitUntil("They open on the console", 20) { await self.value(selectedTab, in: console) as? String == "console" }
        await waitUntil("Rise hears they show the console") { panel.shownPanel == "console" }
        browser.toggleDevTools()
        await waitUntil("⌥⌘J on the console switches to Elements") { await self.value(selectedTab, in: console) as? String == "elements" }
        await waitUntil("Ready to select an element there", 10) { await self.value(picking, in: console) as? Bool == true }
        check(panel.isOpen, "Switching leaves them open")
        browser.toggleDevToolsConsole()
        await waitUntil("⌥⌘K on Elements switches to the console") { await self.value(selectedTab, in: console) as? String == "console" }
        check(await value(picking, in: console) as? Bool == false, "The console doesn't pick an element")
        browser.toggleDevToolsConsole()
        await waitUntil("⌥⌘K on the console puts them away") { panel.shadow.isHidden && panel.tabID == nil }
        browser.toggleDevTools()
        await waitUntil("⌥⌘J opens them again") { panel.isOpen && panel.progress == 1 && panel.shownPanel == "elements" }
        if let elements = panel.clip.subviews.first as? RCBrowserView {
            await waitUntil("On Elements, picking", 20) { await self.value(picking, in: elements) as? Bool == true }
        }
        browser.toggleDevTools()
        await waitUntil("⌥⌘J on Elements puts them away") { panel.shadow.isHidden && panel.tabID == nil }
    }
}
