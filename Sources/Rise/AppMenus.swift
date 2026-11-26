import AppKit

@MainActor extension AppDelegate: NSMenuDelegate {
    func buildMenu() {
        browser.keyboardShortcuts.clearMenuItems()
        let bar = NSMenu(); NSApp.mainMenu = bar
        func addMenu(_ title: String, to parent: NSMenu = bar) -> NSMenu {
            let item = NSMenuItem(); item.title = title
            let menu = NSMenu(title: title); item.submenu = menu; parent.addItem(item); return menu
        }
        @discardableResult func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, id: String? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = target; menu.addItem(entry)
            browser.keyboardShortcuts.register(entry, group: menu.title, id: id)
            return entry
        }
        func alternate(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String) {
            let entry = item(menu, title, action, key, target: browser)
            entry.isHidden = true; entry.allowsKeyEquivalentWhenHidden = true
        }

        let app = addMenu("Rise")
        item(app, "About Rise", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        if let updates = AppUpdater.shared.menuItem() { app.addItem(updates) }
        item(app, "Settings…", #selector(BrowserController.showSettings), ",", target: browser)
        item(app, "Manage Extensions", #selector(BrowserController.manageExtensions), target: browser)
        item(app, "Sync Tabs with iCloud", #selector(toggleTabSync), target: self)
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services; app.addItem(servicesItem); NSApp.servicesMenu = services
        app.addItem(.separator())
        item(app, "Hide Rise", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option], target: NSApp)
        item(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        item(app, "Quit Rise", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = addMenu("File")
        item(file, "New Tab", #selector(BrowserController.newTab), "t", target: browser)
        item(file, "Open File…", #selector(BrowserController.openFile), "o", target: browser)
        item(file, "Open Location…", #selector(BrowserController.focusAddress), "l", target: browser)
        file.addItem(.separator())
        item(file, "Close Tab", #selector(BrowserController.closeCurrentTab), "w", target: browser)
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", modifiers: [.command, .shift], target: browser.window)
        item(file, "Reopen Closed Tab", #selector(BrowserController.reopenTab), "t", modifiers: [.command, .shift], target: browser)
        file.addItem(.separator())
        // The menu bar's share items go without the icons a page's menu shows them with.
        for entry in [item(file, "Share…", #selector(BrowserController.shareCurrentPage), target: browser),
                      item(file, "AirDrop", #selector(BrowserController.airDropCurrentPage), target: browser)] {
            entry.image = nil
            #if compiler(>=6.4)
            if #available(macOS 27, *) { entry.preferredImageVisibility = .hidden }
            #endif
        }
        item(file, "Copy Link", #selector(BrowserController.copyURL), "C", modifiers: [.command, .shift], target: browser)
        file.addItem(.separator())
        item(file, "Save Page Screenshot…", #selector(BrowserController.savePageScreenshot), target: browser)
        item(file, "Capture Full Page as Image", #selector(BrowserController.capturePageImage), target: browser)
        item(file, "Capture Full Page as PDF", #selector(BrowserController.capturePagePDF), target: browser)
        file.addItem(.separator())
        item(file, "Print…", #selector(BrowserController.printPage), "p", target: browser)
        item(file, "Print Using System Dialog…", #selector(BrowserController.printPageUsingSystemDialog), target: browser)

        let edit = addMenu("Edit")
        item(edit, "Undo", Selector(("undo:")))
        item(edit, "Redo", Selector(("redo:")))
        edit.addItem(.separator())
        item(edit, "Cut", #selector(NSText.cut(_:)), "x")
        item(edit, "Copy", #selector(NSText.copy(_:)), "c")
        item(edit, "Paste", #selector(NSText.paste(_:)), "v")
        item(edit, "Paste and Match Style", Selector(("pasteAndMatchStyle:")), "v", modifiers: [.command, .option, .shift])
        item(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        edit.addItem(.separator())
        item(edit, "Find on Page…", #selector(BrowserController.showFind), "f", target: browser)
        item(edit, "Find Next", #selector(BrowserController.findNext), "g", target: browser)
        item(edit, "Skip to Next Match Below", #selector(BrowserController.skipToNextMatch), "g", modifiers: [.command, .option], target: browser).isAlternate = true
        item(edit, "Find Previous", #selector(BrowserController.findPrevious), "G", modifiers: [.command, .shift], target: browser)
        item(edit, "Skip to Previous Match Above", #selector(BrowserController.skipToPreviousMatch), "G", modifiers: [.command, .option, .shift], target: browser).isAlternate = true

        let view = addMenu("View")
        item(view, "Hide Sidebar", #selector(BrowserController.toggleSidebar), "b", target: browser)
        view.addItem(.separator())
        item(view, "Reload", #selector(BrowserController.reload), "r", target: browser)
        item(view, "Reload Without Cache", #selector(BrowserController.hardReload), "r", modifiers: [.command, .shift], target: browser)
        item(view, "Stop Loading", #selector(BrowserController.stopLoadingPage), ".", target: browser)
        item(view, "Replace Times with Local Time", #selector(BrowserController.toggleLocalTimes), "t", modifiers: [.command, .option], target: browser)
        view.addItem(.separator())
        item(view, "Zoom In", #selector(BrowserController.zoomIn), "+", target: browser)
        alternate(view, "Zoom In", #selector(BrowserController.zoomIn), "=")
        item(view, "Zoom Out", #selector(BrowserController.zoomOut), "-", target: browser)
        item(view, "Actual Size", #selector(BrowserController.actualSize), "0", target: browser)
        view.addItem(.separator())
        let annotations = addMenu("Annotations", to: view)
        item(annotations, "Annotate Selection", #selector(BrowserController.annotateSelection), "a", modifiers: [.command, .control], target: browser)
        item(annotations, "Remove All Annotations on This Page", #selector(BrowserController.removePageAnnotations), target: browser)
        let pageOptions = addMenu("Page Options", to: view)
        item(pageOptions, "Dismiss Cookie Banners", #selector(BrowserController.toggleCookieConsent), target: browser)
        item(pageOptions, "Automatic PiP", #selector(BrowserController.toggleAutomaticPictureInPicture), target: browser)
        item(pageOptions, "Preload Links on Hover", #selector(BrowserController.toggleLinkPreloading), target: browser)
        item(pageOptions, "Autoplay YouTube Videos", #selector(BrowserController.toggleYouTubeAutoplay), target: browser)
        pageOptions.addItem(.separator())
        item(pageOptions, "Site Information", #selector(BrowserController.showSiteInformation), target: browser)
        item(pageOptions, "Reset Site Permissions", #selector(BrowserController.resetSitePermissions), target: browser)
        view.addItem(.separator())
        item(view, "Show Downloads", #selector(BrowserController.toggleDownloads), "l", modifiers: [.command, .option], target: browser)
        item(view, "Show Chat", #selector(BrowserController.toggleAIChat), "e", target: browser)
        let theme = browser.makeThemeMenu()
        theme.submenu?.identifier = NSUserInterfaceItemIdentifier("browserTheme"); theme.submenu?.delegate = self
        view.addItem(theme)
        item(view, "Change Theme", #selector(BrowserController.toggleTheme), target: browser)
        view.addItem(.separator())
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control], target: browser.window)
        item(view, "Simulated Full Screen", #selector(BrowserController.toggleSimulatedFullscreen), "f", modifiers: [.command, .shift], target: browser)
        view.addItem(.separator())
        let developerTools = addMenu("Developer Tools", to: view)
        item(developerTools, "Developer Mode", #selector(BrowserController.toggleDeveloper), "d", modifiers: .control, target: browser)
        item(developerTools, "Inspect Elements", #selector(BrowserController.toggleDevTools), "j", modifiers: [.command, .option], target: browser)
        item(developerTools, "Show Console", #selector(BrowserController.toggleDevToolsConsole), "k", modifiers: [.command, .option], target: browser)
        item(developerTools, "JavaScript Console…", #selector(BrowserController.javascriptConsole), target: browser)
        item(developerTools, "Show Page Source", #selector(BrowserController.showPageSource), "u", modifiers: [.command, .option], target: browser)
        developerTools.addItem(.separator())
        item(developerTools, "Card Motion Tester", #selector(BrowserController.toggleCardMotionTester), target: browser)
        item(developerTools, "Link Pulse Tester", #selector(BrowserController.toggleLinkPulseTester), target: browser)

        let history = addMenu("History")
        item(history, "Back", #selector(BrowserController.goBack), "[", target: browser)
        item(history, "Forward", #selector(BrowserController.goForward), "]", target: browser)
        history.addItem(.separator())
        let recentlyClosed = NSMenu(title: "Recently Closed Tabs")
        recentlyClosed.identifier = NSUserInterfaceItemIdentifier("recentlyClosedTabs"); recentlyClosed.delegate = self
        let recentItem = NSMenuItem(title: recentlyClosed.title, action: nil, keyEquivalent: "")
        recentItem.submenu = recentlyClosed; history.addItem(recentItem)
        menuNeedsUpdate(recentlyClosed)
        item(history, "Archived Tabs…", #selector(BrowserController.showArchivedTabs), target: browser)
        history.addItem(.separator())
        item(history, "Clear Browsing History…", #selector(BrowserController.confirmClearBrowsingHistory), target: browser)

        let bookmarks = addMenu("Bookmarks")
        item(bookmarks, "Bookmark This Page", #selector(BrowserController.bookmarkCurrentPage), "d", target: browser)
        item(bookmarks, "Show Bookmarks in Sidebar", #selector(BrowserController.toggleSidebarBookmarks), "b", modifiers: [.command, .option], target: browser)
        bookmarks.addItem(.separator())
        // The bookmarks themselves follow, as they are when the menu opens.
        bookmarks.identifier = NSUserInterfaceItemIdentifier("bookmarks"); bookmarks.delegate = self

        let tabs = addMenu("Tabs")
        item(tabs, "Next Tab", #selector(BrowserController.nextTab), "]", modifiers: [.command, .shift], target: browser)
        item(tabs, "Previous Tab", #selector(BrowserController.previousTab), "[", modifiers: [.command, .shift], target: browser)
        item(tabs, "Search Tabs", #selector(BrowserController.searchTabs), "a", modifiers: [.command, .shift], target: browser)
        tabs.addItem(.separator())
        item(tabs, "Duplicate Tab", #selector(BrowserController.duplicateCurrentTab), target: browser)
        item(tabs, "Pin Tab", #selector(BrowserController.pinCurrentTab), target: browser)
        item(tabs, "Move Tab Up", #selector(BrowserController.moveCurrentTabUp), target: browser)
        item(tabs, "Move Tab Down", #selector(BrowserController.moveCurrentTabDown), target: browser)
        item(tabs, "Move Tab to Top", #selector(BrowserController.moveCurrentTabToTop), target: browser)
        item(tabs, "Split View", #selector(BrowserController.toggleSplit), target: browser)
        item(tabs, "Duplicate into Split View", #selector(BrowserController.duplicateIntoSplit), "d", modifiers: [.command, .shift], target: browser)
        item(tabs, "Swap Split Sides", #selector(BrowserController.swapSplitSides), "d", modifiers: [.command, .option, .shift], target: browser)
        item(tabs, "Peek Current Page", #selector(BrowserController.peekCurrentPage), "p", modifiers: [.command, .shift], target: browser)
        item(tabs, "Stash Peek in New Tab", #selector(BrowserController.stashPeekInNewTab), "p", modifiers: [.command, .option], target: browser)
        item(tabs, "Sort Tabs by Domain", #selector(BrowserController.cleanUpTabs), "k", modifiers: [.command, .shift], target: browser)
        tabs.addItem(.separator())
        item(tabs, "Close Other Tabs", #selector(BrowserController.closeOtherTabs), target: browser)
        item(tabs, "Close Tabs Below", #selector(BrowserController.closeTabsBelow), target: browser)
        tabs.addItem(.separator())
        for index in 0..<9 {
            let entry = item(tabs, "Tab \(index+1)", #selector(BrowserController.selectNumberedTab(_:)), target: browser, id: "selectTab\(index+1)")
            entry.tag = index
        }

        let window = addMenu("Window"); NSApp.windowsMenu = window
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)

        let help = addMenu("Help"); NSApp.helpMenu = help
        item(help, "Rise on GitHub", #selector(BrowserController.showProject), target: browser)
        item(help, "Report an Issue…", #selector(BrowserController.reportIssue), target: browser)
        browser.keyboardShortcuts.applyToMenus()
        browser.keyboardShortcutsChanged()
        bar.separatingIconSections()
    }

    static let bookmarkMenuTag = 0xB00C
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.identifier?.rawValue == "browserTheme", let fresh = browser.makeThemeMenu().submenu {
            menu.removeAllItems()
            for item in fresh.items { fresh.removeItem(item); menu.addItem(item) }
            return
        }
        if menu.identifier?.rawValue == "bookmarks" {
            for item in menu.items where item.tag == Self.bookmarkMenuTag { menu.removeItem(item) }
            let empty = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: ""); empty.isEnabled = false
            let listed: [NSMenuItem] = browser.bookmarks.items.isEmpty ? [empty] : browser.bookmarks.items.map { bookmark in
                    let entry = browser.menuItem(bookmark.shownTitle) { [weak browser] in
                        browser?.openBookmark(bookmark.id, atTop: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
                    }
                    entry.toolTip = bookmark.url.absoluteString
                    if let icon = browser.bookmarkIcon(bookmark)?.copy() as? NSImage { icon.size = NSSize(width: 16, height: 16); entry.image = icon }
                    return entry
                }
            for item in listed { item.tag = Self.bookmarkMenuTag; menu.addItem(item) }
            return
        }
        guard menu.identifier?.rawValue == "recentlyClosedTabs" else { return }
        menu.removeAllItems()
        guard !browser.closedTabs.isEmpty else {
            let empty = NSMenuItem(title: "No Recently Closed Tabs", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty); return
        }
        for saved in browser.closedTabs.suffix(15).reversed() {
            let entry = browser.menuItem(saved.title) { [weak browser] in browser?.reopenClosedTab(saved.id) }
            entry.toolTip = saved.url
            menu.addItem(entry)
        }
    }
}
