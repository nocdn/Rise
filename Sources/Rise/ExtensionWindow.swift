import AppKit
import RiseChromium

@MainActor extension BrowserController {
    /// Tells Chrome extensions of the window's tabs: once a turn, however many changed.
    func extensionTabsChanged() {
        guard ChromiumEngine.isRunning else { return }
        if extensionWindow == nil { extensionWindow = ExtensionWindow(browser: self) }
        (extensionWindow as? ExtensionWindow)?.setNeedsSync()
    }
}

/// Rise's window as Chrome extensions see it: a browser window with its Chromium tabs, in order,
/// the selected one in front. What extensions ask of it (opening, switching, moving, pinning and
/// closing tabs) Rise does as if asked itself.
@MainActor final class ExtensionWindow: NSObject, RCTabStripDelegate {
    weak var browser: BrowserController?
    private(set) lazy var strip = RCTabStrip(delegate: self)
    private var pending = false
    private var observers: [NSObjectProtocol] = []
    /// Extensions' toolbar buttons, by name.
    private(set) var actions: [RCExtensionAction] = []
    /// The pinned ones' buttons, in the page bar.
    private var buttons: [String: SidebarExtensionButton] = [:]
    private var actionsObservation: Any?
    private var listed: [String] = []

    init(browser: BrowserController) {
        self.browser = browser
        super.init()
        if let window = browser.window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMoveNotification,
                         NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncWindow() }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.strip.close() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: BrowserController.pinnedExtensionsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshButtons() }
        })
        actionsObservation = RCExtensions.observeActions { [weak self] in MainActor.assumeIsolated { self?.refreshButtons() } }
        Self.setUpInstallPrompt()
        syncWindow()
        refreshButtons()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func setNeedsSync() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.sync()
        }
    }
    func sync() {
        guard let browser else { return }
        var views: [RCBrowserView] = [], pinned = 0, active = -1, pinnedRun = true
        for tab in browser.tabs {
            guard let page = tab.page as? ChromiumPage else { continue }
            // Extensions count pinned tabs from the start of the window.
            if pinnedRun, tab.pinned { pinned += 1 } else { pinnedRun = false }
            if tab.id == browser.selectedID { active = views.count }
            views.append(page.browserView)
        }
        strip.setTabs(views, pinnedCount: pinned, activeIndex: active)
        // A button's icon, badge and title can be the tab's own.
        refreshButtons()
    }

    /// The pinned extensions' buttons in the page bar, as they are for the selected tab; the site
    /// controls show the list again when extensions come or go.
    func refreshButtons() {
        guard let browser else { return }
        actions = RCExtensions.actions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let tab = browser.selectedChromiumView
        var next: [SidebarExtensionButton] = []
        for id in browser.pinnedExtensions {
            guard let action = actions.first(where: { $0.extensionID == id }) else { continue }
            let button = buttons[id] ?? SidebarExtensionButton(extensionID: id) { [weak self] in
                guard let browser = self?.browser else { return }
                browser.runExtension(id, anchor: self?.buttons[id])
            }
            let title = action.title(forTab: tab)
            button.show(icon: action.icon(forTab: tab), title: title.isEmpty ? action.name : title, badge: action.badgeText(forTab: tab),
                        badgeColor: action.badgeColor(forTab: tab), enabled: action.isEnabled(forTab: tab))
            button.menu = browser.extensionMenu(for: action)
            next.append(button)
        }
        buttons = Dictionary(uniqueKeysWithValues: next.map { ($0.extensionID, $0) })
        if browser.navBar.extensionButtons != next { browser.navBar.extensionButtons = next }
        let ids = actions.map(\.extensionID) + ["|"] + browser.pinnedExtensions
        if ids != listed { listed = ids; browser.refreshSiteControls() }
    }

    /// Rise's install sheet in place of Chrome's dialog, shown in the window in front.
    static func setUpInstallPrompt() {
        guard !installPromptSet else { return }
        installPromptSet = true
        RCExtensions.setInstallPrompt { title, icon, permissions, acceptLabel, answer in
            MainActor.assumeIsolated {
                let browsers = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserController }
                guard let browser = (NSApp.keyWindow?.windowController as? BrowserController) ?? browsers.first else { answer(false); return }
                browser.showInstallPrompt(title: title, icon: icon, permissions: permissions, acceptLabel: acceptLabel, answer: answer)
            }
        }
        RCExtensions.setUninstallPrompt { title, icon, acceptLabel, answer in
            MainActor.assumeIsolated {
                let browsers = NSApp.orderedWindows.compactMap { $0.windowController as? BrowserController }
                guard let browser = (NSApp.keyWindow?.windowController as? BrowserController) ?? browsers.first else { answer(false); return }
                browser.showUninstallPrompt(title: title, icon: icon, acceptLabel: acceptLabel, answer: answer)
            }
        }
    }
    private static var installPromptSet = false
    private func syncWindow() {
        guard let window = browser?.window else { return }
        strip.active = window.isKeyWindow
        strip.frame = window.frame
    }
    private func tab(for view: RCBrowserView) -> BrowserTab? {
        browser?.tabs.first { ($0.page as? ChromiumPage)?.browserView === view }
    }

    // RCTabStripDelegate
    func tabStripOpenTab(with url: URL, index: Int, active: Bool) -> RCBrowserView? {
        guard let browser, ["http", "https", "chrome-extension", "about", "data", "file"].contains(url.scheme?.lowercased() ?? "")
                || RisePages.address(for: url)?.scheme == "rise" else { return nil }
        let tab = browser.addTab(url: RisePages.address(for: url) ?? url, background: !active)
        // Extensions get the tab back at once, so the window's tabs include it before then.
        sync()
        return (tab.page as? ChromiumPage)?.browserView
    }
    func tabStripAdoptTab(_ view: RCBrowserView, index: Int, active: Bool) -> Bool {
        guard let browser else { return false }
        browser.addTab(background: !active, page: ChromiumPage(browserView: view))
        sync()
        return true
    }
    func tabStripActivateTab(_ view: RCBrowserView) {
        if let tab = tab(for: view) { browser?.select(tab.id) }
    }
    func tabStripCloseTab(_ view: RCBrowserView) {
        if let tab = tab(for: view) { browser?.closeTab(tab.id) }
    }
    func tabStripMoveTab(_ view: RCBrowserView, to index: Int) {
        guard let browser, let tab = tab(for: view), let from = browser.tabs.firstIndex(where: { $0 === tab }) else { return }
        browser.tabs.remove(at: from)
        browser.tabs.insert(tab, at: max(0, min(index < 0 ? browser.tabs.count : index, browser.tabs.count)))
        browser.update(); browser.scheduleSave()
    }
    func tabStripSetTab(_ view: RCBrowserView, pinned: Bool) {
        guard let browser, let tab = tab(for: view), tab.pinned != pinned else { return }
        tab.pinned = pinned
        browser.update(); browser.scheduleSave()
    }
    func tabStripActivateWindow() {
        NSApp.activate(ignoringOtherApps: true)
        browser?.window?.makeKeyAndOrderFront(nil)
    }
}
