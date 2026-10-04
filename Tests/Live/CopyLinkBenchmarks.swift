import AppKit
@testable import Rise

@main @MainActor struct CopyLinkBenchmarks {
    static func main() {
        let app = NSApplication.shared, delegate = CopyLinkVerification()
        app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
        withExtendedLifetime(delegate) {}
    }
}
@MainActor final class CopyLinkVerification: NSObject, NSApplicationDelegate {
    var browser: BrowserController!
    var closingTime: TimeInterval?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { [self] in
            do {
                browser = BrowserController(sessionURL: URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_BENCHMARK_SESSION"]!), restore: false)
                browser.linkPasteboard = .withUniqueName()
                browser.window?.setContentSize(NSSize(width: 1100, height: 760)); browser.window?.center(); browser.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                let tab = browser.addTab()
                tab.requestedURL = URL(string: "https://example.com/copied?full=1#anchor")
                browser.update(); browser.root.layoutSubtreeIfNeeded()
                browser.sidebar.setSidebarHovered(false, animated: false)
                browser.sidebar.setSidebarHovered(true)
                try await Task.sleep(for: .milliseconds(65))
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    let opacity = browser.sidebar.copyButton.layer?.presentation()?.opacity ?? -1
                    check(opacity > 0 && opacity < 1, "Icons visibly interpolate during the fade: \(opacity)")
                }
                try await Task.sleep(for: .milliseconds(140))
                browser.siteMenu(); try await Task.sleep(for: .milliseconds(80))
                browser.sidebar.setSidebarHovered(false)
                try await Task.sleep(for: .milliseconds(150))
                check(browser.siteControlsPopover.isShown, "Settings remain open after hovering out of the sidebar")
                check(browser.sidebar.settingsButton.alphaValue == 1 && browser.sidebar.copyButton.alphaValue == 1, "URL controls stay visible while settings is open")
                browser.copyURL(); try await Task.sleep(for: .milliseconds(350))
                check(browser.copiedLinkPopover.isShown, "Native copy confirmation opens")
                check(browser.copiedLinkPopover.animates == !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Native popover animations respect Reduce Motion")
                let content = browser.copiedLinkPopover.contentViewController as! CopiedLinkController
                check(content.view is CopyConfirmationView && !content.view.subviews.contains { $0 is NSVisualEffectView }, "Native popover material is not covered by a second material")
                check(abs(content.shareButton.frame.minX-content.message.frame.maxX-8) < 0.1, "Text/button spacing is tightened to 8 points")
                let rect = content.view.window!.convertToScreen(content.view.convert(content.view.bounds, to: nil))
                let bar = browser.sidebar.address
                let anchor = browser.window!.convertToScreen(bar.convert(bar.bounds, to: nil))
                check(rect.minX >= anchor.maxX-2 && abs(rect.midY-anchor.midY) < 12, "Popover points sideways into URL bar: \(rect), \(anchor)")
                check(browser.linkPasteboard.string(forType: .string) == tab.url!.absoluteString, "Full URL is copied")
                if let folder = ProcessInfo.processInfo.environment["RISE_POPOVER_FRAMES"] {
                    let view = content.view.window!.contentView!.superview!
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent("copied-link.png"))
                }
                let copied = tab.url!; var sent: URL?
                browser.airDropHandler = { sent = $0 }
                tab.requestedURL = URL(string: "https://changed.example")
                content.shareButton.performClick(nil)
                try await Task.sleep(for: .milliseconds(900))
                check(sent == copied && !browser.copiedLinkPopover.isShown, "Share button uses the copied link and closes confirmation: sent=\(String(describing: sent)), shown=\(browser.copiedLinkPopover.isShown)")
                browser.toggleSidebar(); browser.copyURL()
                try await Task.sleep(for: .milliseconds(80))
                check(browser.sidebarVisible && browser.copiedLinkPopover.isShown, "Copying with a hidden sidebar restores the anchor instantly")
                let timed = browser.copiedLinkPopover.contentViewController as! CopiedLinkController
                let observer = NotificationCenter.default.addObserver(forName: NSPopover.willCloseNotification, object: browser.copiedLinkPopover, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closingTime = ProcessInfo.processInfo.systemUptime }
                }
                defer { NotificationCenter.default.removeObserver(observer) }
                let started = ProcessInfo.processInfo.systemUptime
                timed.setHovered(false)
                try await Task.sleep(for: .milliseconds(1250))
                check(browser.copiedLinkPopover.isShown, "Popover stays visible until the 1.5 second timeout")
                try await Task.sleep(for: .milliseconds(1100))
                check(abs((closingTime ?? 0)-started-1.5) < 0.15, "Native dismissal starts at 1.5 seconds")
                check(!browser.copiedLinkPopover.isShown, "Popover dismisses automatically after 1.5 seconds with native closing animation")
                browser.theme = .dark; browser.update(); browser.copyURL()
                let hovered = browser.copiedLinkPopover.contentViewController as! CopiedLinkController
                let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: hovered.view.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
                hovered.view.mouseEntered(with: event)
                try await Task.sleep(for: .milliseconds(1750))
                check(browser.copiedLinkPopover.isShown, "Hovering retains the popover beyond its timeout")
                hovered.view.mouseExited(with: event)
                try await Task.sleep(for: .milliseconds(2400))
                check(!browser.copiedLinkPopover.isShown, "Leaving the popover restarts its 1.5 second dismissal timer")
                browser.copiedLinkPopover.close(); browser.linkPasteboard.releaseGlobally(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
                print("PASS: native material/animation, tighter spacing, 1.5 second dismissal, hover retention, AirDrop routing, stable anchors and hover fades")
                NSApp.terminate(nil)
            } catch { fputs("COPY LINK VERIFICATION FAILED: \(error)\n", stderr); exit(1) }
        }
    }
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
