import AppKit
import WebKit
@testable import Rise

@main @MainActor struct SiteControlsBenchmarks {
    static func main() {
        let app = NSApplication.shared
        let delegate = SiteControlsVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class SiteControlsVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let suite = "Rise.LiveSiteControls.\(UUID())", defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            do {
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false, preferences: defaults)
                browser.window?.setContentSize(NSSize(width:1100,height:760)); browser.showWindow(nil)
                NSApp.activate(ignoringOtherApps:true)
                let tab = browser.addTab()
                tab.webView.loadHTMLString("<title>Settings fixture</title><style>body{background:#f4f2e9;padding:60px;font:24px -apple-system;color:#354039}h1{font:60px Georgia}</style><h1>A native settings popover.</h1><p>The page stays in WebKit.</p>", baseURL: URL(string:"https://calendar.google.com"))
                try await wait { tab.webView.title == "Settings fixture" && !tab.webView.isLoading }
                try await Task.sleep(for:.milliseconds(100))
                let bridge = try await tab.webView.evaluateJavaScript("typeof window.riseSiteControls") as? String
                check(bridge == "object", "Site permission bridge runs in real WebKit")
                let notifications = try await tab.webView.evaluateJavaScript("Notification.name") as? String
                check(notifications == "RiseNotification", "Page notifications use Rise's native permission bridge")
                let origin = SitePermissions.origin(tab.url)!
                browser.sitePermissions.set(.block,for:.notifications,origin:origin)
                browser.siteMenu(); try await Task.sleep(for:.milliseconds(900))
                check(browser.siteControlsPopover.isShown, "Native site popover opens")
                check(browser.siteControlsPopover.animates == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Native settings animation is enabled")
                try save(browser.siteControlsPopover,"site-controls-light")
                let content = browser.siteControlsPopover.contentViewController as! SiteControlsController
                check(!content.view.subviews.contains { $0 is NSVisualEffectView }, "Native material is not covered by another background")
                check(content.quickActions.last?.toolTip == "More Site Controls" && content.view.bounds.height == 374, "More is at the top and the footer is removed")
                let rect = content.view.window!.convertToScreen(content.view.convert(content.view.bounds,to:nil))
                let button = browser.sidebar.settingsButton
                let anchor = browser.window!.convertToScreen(button.convert(button.bounds,to:nil))
                check(rect.maxY <= anchor.minY+5, "Popover appears below the URL-bar settings icon: \(rect), \(anchor)")
                browser.theme = .dark; browser.update(); browser.refreshSiteControls()
                try await Task.sleep(for:.milliseconds(120)); try save(browser.siteControlsPopover,"site-controls-dark")
                browser.theme = .neutral; browser.update(); browser.siteControlsPopover.close()
                try await Task.sleep(for:.milliseconds(900))
                check(!browser.siteControlsPopover.isShown, "Settings close with native animation")
                browser.sitePermissions.set(.ask,for:.notifications,origin:origin)
                // Exercise the real WebKit message/reply path without asking the
                // operating system for notification access during verification.
                _ = try await tab.webView.evaluateJavaScript("window.requestResult = null; webkit.messageHandlers.riseSiteControls.postMessage({kind:'permission'}).then(value => window.requestResult=value); undefined")
                try await wait { self.browser.permissionCoordinator.popover.isShown }
                try await Task.sleep(for:.milliseconds(100)); try save(browser.permissionCoordinator.popover,"site-permission")
                let prompt = browser.permissionCoordinator.popover.contentViewController as! PermissionPromptController
                check(prompt.message == "Allow calendar.google.com to send you notifications?", "Permission prompt uses the requesting origin")
                prompt.notNowButton.performClick(nil)
                try await Task.sleep(for:.milliseconds(50))
                let result = try await tab.webView.evaluateJavaScript("window.requestResult") as? String
                check(result == "default", "Not Now resolves the actual WebKit promise")
                var decisions:[Bool] = []
                browser.permissionCoordinator.request(in:tab.webView,origin:origin,capabilities:[.camera,.microphone]) { decisions.append($0) }
                browser.addTab()
                check(decisions == [false], "Switching tabs cancels the permission request exactly once")
                print("PASS: native light/dark settings, URL-bar anchor, real WebKit permission bridge, Not Now and tab cancellation")
                browser.saveWork?.cancel(); browser.window?.orderOut(nil); NSApp.terminate(nil)
            } catch { fputs("SITE CONTROLS VERIFICATION FAILED: \(error)\n",stderr); exit(1) }
        }
    }
    func check(_ value:Bool,_ message:String) { if !value { fputs("FAIL: \(message)\n",stderr); exit(1) } }
    func wait(_ predicate:() -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !predicate() && Date() < deadline { try await Task.sleep(for:.milliseconds(20)) }
        check(predicate(),"Timed out waiting for WebKit")
    }
    func save(_ popover:NSPopover,_ name:String) throws {
        guard let folder = ProcessInfo.processInfo.environment["RISE_POPOVER_FRAMES"], let view = popover.contentViewController?.view.window?.contentView?.superview else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(view.bounds.width*2),pixelsHigh:Int(view.bounds.height*2),bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        bitmap.size = view.bounds.size
        if let bytes = bitmap.bitmapData { memset(bytes,0,bitmap.bytesPerRow*bitmap.pixelsHigh) }
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to: URL(fileURLWithPath:folder).appendingPathComponent(name+".png"))
    }
}
