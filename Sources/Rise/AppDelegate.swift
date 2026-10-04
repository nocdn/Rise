import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        browser = BrowserController(); buildMenu()
        browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) { browser?.saveNow() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        if browser == nil { browser = BrowserController(); buildMenu(); browser.showWindow(nil) }
        for url in urls { browser.addTab(url: url) }
    }
    @objc func showBrowser() { browser.showWindow(nil); browser.newTab() }
    func buildMenu() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        func addMenu(_ title: String) -> NSMenu {
            let item = NSMenuItem(); item.title = title
            let menu = NSMenu(title: title); item.submenu = menu; bar.addItem(item); return menu
        }
        @discardableResult func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key); entry.keyEquivalentModifierMask = modifiers
            entry.target = target; menu.addItem(entry); return entry
        }
        let app = addMenu("Rise")
        item(app, "About Rise", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "Hide Rise", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option], target: NSApp)
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator()); item(app, "Quit Rise", #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        let file = addMenu("File")
        item(file, "New Tab", #selector(BrowserController.newTab), "t", target: browser)
        item(file, "Open Location…", #selector(BrowserController.focusAddress), "l", target: browser)
        item(file, "Close Tab", #selector(BrowserController.closeCurrentTab), "w", target: browser)
        item(file, "Reopen Closed Tab", #selector(BrowserController.reopenTab), "t", modifiers: [.command, .shift], target: browser)
        let edit = addMenu("Edit")
        item(edit, "Undo", Selector(("undo:")), "z")
        item(edit, "Redo", Selector(("redo:")), "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find on Page…", #selector(BrowserController.showFind), "f", target: browser)
        item(edit, "Find Next", #selector(BrowserController.findNext), "g", target: browser)
        item(edit, "Find Previous", #selector(BrowserController.findPrevious), "g", modifiers: [.command, .shift], target: browser)
        let view = addMenu("View")
        item(view, "Toggle Sidebar", #selector(BrowserController.toggleSidebar), "b", target: browser)
        let legacySidebarShortcut = item(view, "Toggle Sidebar", #selector(BrowserController.toggleSidebar), "s", target: browser)
        legacySidebarShortcut.isHidden = true; legacySidebarShortcut.allowsKeyEquivalentWhenHidden = true
        item(view, "Reload", #selector(BrowserController.reload), "r", target: browser)
        item(view, "Toggle Developer Mode", #selector(BrowserController.toggleDeveloper), "d", modifiers: .control, target: browser)
        item(view, "Change Theme", #selector(BrowserController.toggleTheme), target: browser)
        item(view, "Peek Current Page", #selector(BrowserController.peekCurrentPage), "p", modifiers: [.command, .shift], target: browser)
        item(view, "Split View", #selector(BrowserController.toggleSplit), target: browser)
        view.addItem(.separator())
        item(view, "Zoom In", #selector(BrowserController.zoomIn), "+", target: browser)
        item(view, "Zoom Out", #selector(BrowserController.zoomOut), "-", target: browser)
        item(view, "Actual Size", #selector(BrowserController.actualSize), "0", target: browser)
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control], target: browser.window)
        let history = addMenu("History")
        item(history, "Back", #selector(BrowserController.goBack), "[", target: browser)
        item(history, "Forward", #selector(BrowserController.goForward), "]", target: browser)
        item(history, "Next Tab", #selector(BrowserController.nextTab), "]", modifiers: [.command, .shift], target: browser)
        item(history, "Previous Tab", #selector(BrowserController.previousTab), "[", modifiers: [.command, .shift], target: browser)
        item(history, "Copy Link", #selector(BrowserController.copyURL), "C", modifiers: [.command, .shift], target: browser)
        history.addItem(.separator())
        item(history, "Clear Browsing History…", #selector(BrowserController.confirmClearBrowsingHistory), target: browser)
        let window = addMenu("Window"); NSApp.windowsMenu = window
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    }
}
