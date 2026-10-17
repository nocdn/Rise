import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var browser: BrowserController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        browser = BrowserController(sessionURL: RiseProfile.directory?.appendingPathComponent("session.json")); buildMenu()
        browser.showWindow(nil)
        if Bundle.main.object(forInfoDictionaryKey: "RiseCloudKitEnabled") as? Bool == true {
            NSApp.registerForRemoteNotifications(matching: [])
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        browser?.pictureInPicture.tearDown(); browser?.saveNow()
        ChromiumEngine.shutdown()
    }
    func applicationDidBecomeActive(_ notification: Notification) { browser?.applyPendingSharedTabs(); browser?.tabSync?.refresh() }
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) { browser?.tabSync?.refresh() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) {
        if browser == nil { browser = BrowserController(); buildMenu(); browser.showWindow(nil) }
        for url in urls { browser.addTab(url: url) }
    }
    @objc func showBrowser() { browser.showWindow(nil); browser.newTab() }
    @objc func toggleTabSync() {
        guard let sync = browser?.tabSync else { return }
        sync.setEnabled(!sync.isEnabled)
        browser.applyPendingSharedTabs()
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleTabSync) else { return true }
        guard let sync = browser?.tabSync else { return false }
        item.state = sync.isEnabled ? .on : .off
        item.toolTip = sync.status.message
        return true
    }
}
