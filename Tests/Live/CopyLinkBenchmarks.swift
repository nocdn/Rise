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
                let notice = browser.infoPlaque
                check(notice.isPresented && notice.text == "Link copied", "Copying shows the blue notice")
                let share = notice.actionButton!
                let label = notice.panel.frame.minX+InfoPlaque.inset+InfoPlaque.iconSize+InfoPlaque.iconGap+InfoPlaque.width(of: "Link copied")
                check(abs(notice.convert(share.frame, from: share.superview).minX-label-InfoPlaque.buttonGap) < 0.5, "The share button sits 8 points after the text")
                check(browser.linkPasteboard.string(forType: .string) == tab.url!.absoluteString, "Full URL is copied")
                if let folder = ProcessInfo.processInfo.environment["RISE_POPOVER_FRAMES"] {
                    let view = browser.root
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent("copied-link.png"))
                }
                let copied = tab.url!; var sent: URL?
                browser.airDropHandler = { sent = $0 }
                tab.requestedURL = URL(string: "https://changed.example")
                share.performClick(nil)
                try await Task.sleep(for: .milliseconds(900))
                check(sent == copied && !notice.isPresented, "Share button uses the copied link and puts the notice away: sent=\(String(describing: sent)), shown=\(notice.isPresented)")
                tab.requestedURL = copied
                browser.toggleSidebar(); browser.copyURL()
                try await Task.sleep(for: .milliseconds(80))
                check(!browser.sidebarVisible && notice.isPresented, "Copying with a hidden sidebar shows the notice without the sidebar")
                try await Task.sleep(for: .milliseconds(700)); browser.copyURL()
                try await Task.sleep(for: .milliseconds(700))
                check(notice.isPresented, "Copying again holds the notice for another second")
                try await Task.sleep(for: .milliseconds(1000))
                check(!notice.isPresented, "The notice goes back up a second after the last copy")
                browser.toggleSidebar(); browser.theme = .dark; browser.update(); browser.copyURL()
                notice.setHovered(true)
                try await Task.sleep(for: .milliseconds(1750))
                check(notice.isPresented, "Hovering holds the notice beyond its timeout")
                notice.setHovered(false)
                try await Task.sleep(for: .milliseconds(1400))
                check(!notice.isPresented, "Leaving the notice restarts its one second hold")
                // Another kind of notice sits beside the copied link, and moves over as it leaves.
                browser.theme = .neutral; browser.update(); browser.copyURL(); try await Task.sleep(for: .milliseconds(400))
                browser.showInfo("Simulated full screen enabled", image: InfoPlaque.fullScreenIcon, kind: "fullscreen")
                try await Task.sleep(for: .milliseconds(400))
                check(notice.notices.count == 2, "Both notices show: \(notice.notices.map(\.kind))")
                let first = notice.notices[0], second = notice.notices[1]
                let corner = first.panel.frame.maxX
                check(abs(second.panel.frame.maxX-(first.panel.frame.minX-InfoPlaque.spacing)) < 0.5, "The second sits to the left of the first")
                if let folder = ProcessInfo.processInfo.environment["RISE_POPOVER_FRAMES"] {
                    let view = browser.root
                    let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: folder).appendingPathComponent("side-by-side.png"))
                }
                while first.isPresented { try await Task.sleep(for: .milliseconds(5)) }
                let leftAt = second.panel.frame.maxX
                try await Task.sleep(for: .milliseconds(70))
                check(first.slide.value > 0.05 && second.panel.frame.maxX > leftAt+8,
                      "The second moves right while the first is still leaving: slide \(first.slide.value), moved \(second.panel.frame.maxX-leftAt)")
                try await Task.sleep(for: .milliseconds(600))
                check(abs(second.panel.frame.maxX-corner) < 0.5, "...and takes the corner")
                browser.linkPasteboard.releaseGlobally(); browser.saveWork?.cancel(); browser.window?.orderOut(nil)
                print("PASS: blue notice with share button, held by repeat copies and hover, side by side with another notice, AirDrop routing and hover fades")
                NSApp.terminate(nil)
            } catch { fputs("COPY LINK VERIFICATION FAILED: \(error)\n", stderr); exit(1) }
        }
    }
    func check(_ value: Bool, _ message: String) { if !value { fputs("FAIL: \(message)\n", stderr); exit(1) } }
}
