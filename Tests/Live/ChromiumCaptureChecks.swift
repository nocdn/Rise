// The camera button's whole-page captures on Chromium: its JPEG and PDF popover, the captures saved,
// copied and told, the settings that turn saving and copying off, and Rise's sheet before an
// extension is removed. Run with scripts/test-chromium-live.py capture. The clipboard is put back.
import AppKit
import PDFKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumCaptureMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+240) { print("DONE timeout"); ChromiumCaptureRun.restore(); exit(0) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        _ = RCEngine.start(withCachePath: folder + "/chromium", keychain: false)
        let run = ChromiumCaptureRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumCaptureRun: NSObject, NSApplicationDelegate {
    let folder: URL; var browser: BrowserController!
    var failures = 0
    static var saved: [[NSPasteboard.PasteboardType: Data]] = []
    static func restore() {
        let board = NSPasteboard.general; board.clearContents()
        board.writeObjects(saved.map { item in let p = NSPasteboardItem(); item.forEach { p.setData($0.value, forType: $0.key) }; return p })
    }
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }
    func check(_ ok: Bool, _ message: String) { print("\(ok ? "PASS" : "FAIL") \(message)"); if !ok { failures += 1 } }
    func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return await condition()
    }
    func shot(_ window: NSWindow?, _ name: String, region: Bool = false) {
        guard let window else { return }
        var image: CGImage?
        if region, let screen = NSScreen.screens.first {
            var rect = window.frame; rect.origin.y = screen.frame.maxY - rect.maxY
            image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
        } else { image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]) }
        if let image { try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png")) }
    }
    func files(_ ext: String) -> [URL] { ((try? FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("captures"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == ext } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.saved = (NSPasteboard.general.pasteboardItems ?? []).map { item in Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }) }
        Task {
            let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
            let rows = (0..<60).map { "<p style='height:60px;margin:0;background:hsl(\($0*6),70%,60%)'>Row \($0)</p>" }.joined()
            try "<!doctype html><title>Tall Page</title><body style='margin:0'>\(rows)".write(to: folder.appendingPathComponent("tall.html"), atomically: true, encoding: .utf8)
            let suite = "rise-capture-probe-\(ProcessInfo.processInfo.processIdentifier)"
            let prefs = UserDefaults(suiteName: suite)!
            prefs.set(folder.appendingPathComponent("captures"), forKey: BrowserController.capturesFolderKey)
            browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
            browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            let tab = browser.addTab(url: URL(string: "http://localhost:\(port)/tall.html")!)
            _ = await waitUntil(15) { tab.page.url?.lastPathComponent == "tall.html" && !tab.page.isLoading }
            try? await Task.sleep(for: .seconds(1))
            // The popover, from the settings popover's camera: two equal buttons, JPEG and PDF;
            // Escape closes only it.
            browser.siteMenu()
            _ = await waitUntil(3) { self.browser.siteControlsPopover.isShown }
            try? await Task.sleep(for: .milliseconds(400))
            let camera = (browser.siteControlsPopover.contentViewController as? SiteControlsController)?.quickActions.first { $0.toolTip == "Capture Whole Page" }
            camera?.performClick(nil)
            _ = await waitUntil(3) { self.browser.capturePopover.isShown }
            let buttons = browser.capturePopover.contentViewController?.view.subviews.compactMap { $0 as? NSButton } ?? []
            check(browser.capturePopover.isShown && buttons.map(\.attributedTitle.string) == ["JPEG", "PDF"] && buttons[0].frame.size == buttons[1].frame.size,
                  "The camera button's popover has JPEG and PDF, the same size: \(buttons.map { "\($0.attributedTitle.string) \($0.frame.size)" })")
            try? await Task.sleep(for: .milliseconds(400))
            shot(browser.window, "capture-popover", region: true)
            let settingsShown = browser.siteControlsPopover.isShown
            if let window = browser.capturePopover.contentViewController?.view.window,
               let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                NSApp.sendEvent(esc)
            }
            let closed = await waitUntil(2) { !self.browser.capturePopover.isShown }
            check(closed && settingsShown && browser.siteControlsPopover.isShown, "Escape closes just the capture popover, not the settings one under it (settings shown \(browser.siteControlsPopover.isShown))")
            browser.siteControlsPopover.close(); try? await Task.sleep(for: .milliseconds(300))

            // JPEG, saved and copied, told in the page bar.
            let pageHeight = (try? await tab.page.evaluate("return document.documentElement.scrollHeight", arguments: [:], in: nil, world: .page)) as? Double ?? 0
            browser.captureWholePage(.jpeg)
            let jpegSaved = await waitUntil(10) { !self.files("jpg").isEmpty }
            let jpeg = files("jpg").first.flatMap { NSImage(contentsOf: $0) }
            check(jpegSaved && files("jpg").first?.lastPathComponent == "Tall Page.jpg", "A JPEG saves to the captures folder, named for the page: \(files("jpg").map(\.lastPathComponent))")
            check((jpeg?.size.height ?? 0) >= pageHeight - 2 && pageHeight > 3000, "Of the whole page, not only what shows: \(jpeg?.size ?? .zero) for a page \(pageHeight) high")
            check(NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("public.jpeg")) != nil, "And it's copied")
            _ = await waitUntil(3) { self.browser.navBar.notice != nil }
            let notice = browser.navBar.notice
            check(notice?.text == "Saved to captures", "The page bar says where: \(notice?.text ?? "nothing")")
            try? await Task.sleep(for: .milliseconds(500))
            shot(browser.window, "capture-jpeg-notice", region: true)
            check(notice?.linkLabel?.stringValue == "captures", "The folder's name is a link")
            try? await Task.sleep(for: .milliseconds(1000))
            check(browser.navBar.notice === notice, "It stays for two seconds")
            _ = await waitUntil(2) { self.browser.navBar.notice == nil }
            check(browser.navBar.notice == nil && browser.navBar.text.alphaValue == 1, "Then the address comes back")
            try? await Task.sleep(for: .milliseconds(500))

            // PDF, one page, the page's size.
            browser.captureWholePage(.pdf)
            let pdfSaved = await waitUntil(10) { !self.files("pdf").isEmpty }
            let document = files("pdf").first.flatMap { PDFDocument(url: $0) }
            let bounds = document?.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
            check(pdfSaved && document?.pageCount == 1, "A PDF saves, one page: \(document?.pageCount ?? 0) pages, \(bounds.size) pt")
            check(abs(bounds.height - pageHeight*0.75) < 4, "As long as the page")
            check(NSPasteboard.general.data(forType: .pdf) != nil, "And it's copied")
            _ = await waitUntil(3) { self.browser.navBar.notice?.text == "Saved as PDF to captures" }
            check(browser.navBar.notice?.text == "Saved as PDF to captures", "The page bar says it's a PDF: \(browser.navBar.notice?.text ?? "nothing")")
            try? await Task.sleep(for: .milliseconds(500))
            shot(browser.window, "capture-pdf-notice", region: true)

            // Not copied when that's off; asked where when saving automatically is off.
            NSPasteboard.general.clearContents()
            browser.setCopiesCaptures(false); browser.setSavesCapturesAutomatically(false)
            browser.captureWholePage(.jpeg)
            let asked = await waitUntil(10) { self.browser.window?.attachedSheet is NSSavePanel }
            check(asked, "With saving automatically off, it asks where")
            if let sheet = browser.window?.attachedSheet { browser.window?.endSheet(sheet, returnCode: .cancel) }
            check(NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("public.jpeg")) == nil, "With copying off, it isn't copied")
            browser.setCopiesCaptures(true); browser.setSavesCapturesAutomatically(true)

            // Rise's sheet before an extension is removed.
            ExtensionWindow.setUpInstallPrompt()
            RCExtensions.setInstallPrompt { _, _, _, _, answer in answer(true) }
            let id = "eimadpbcbfnmbkopoojfekhnkhdbieeh"
            RCExtensions.install(fromWebStore: id) { _, _ in }
            _ = await waitUntil(60) { RCExtensions.actions.contains { $0.extensionID == id } }
            ExtensionWindow.setUpInstallPrompt()
            browser.showExtensions(id)
            try? await Task.sleep(for: .seconds(4))
            if let page = browser.tabs.first(where: { $0.page.url?.scheme == "rise" }) {
                browser.select(page.id); try? await Task.sleep(for: .seconds(1))
                func remove() async { _ = try? await page.page.evaluate("chrome.management.uninstall('\(id)', {showConfirmDialog: true}).catch(() => {}); return 0", arguments: [:], in: nil, world: .page) }
                await remove()
                let sheet = await waitUntil(5) { self.browser.window?.attachedSheet != nil }
                let alert = browser.window?.attachedSheet
                func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
                let titles = alert?.contentView.map(all)?.compactMap { $0 as? NSButton }.map(\.title).filter { !$0.isEmpty } ?? []
                check(sheet && Set(titles) == ["Remove", "Cancel"] && titles.count == 2, "Removing an extension asks in Rise's sheet, Remove or Cancel: \(titles)")
                shot(browser.window, "remove-sheet", region: true)
                check(!NSApp.windows.contains { $0.isVisible && String(describing: type(of: $0)).contains("NativeWidgetMac") }, "Not Chrome's dialog")
                alert?.contentView.map(all)?.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }?.performClick(nil)
                try? await Task.sleep(for: .seconds(1))
                check(RCExtensions.actions.contains { $0.extensionID == id }, "Cancel keeps it")
                await remove()
                _ = await waitUntil(5) { self.browser.window?.attachedSheet != nil }
                browser.window?.attachedSheet?.contentView.map(all)?.compactMap { $0 as? NSButton }.first { $0.title == "Remove" }?.performClick(nil)
                check(await waitUntil(5) { !RCExtensions.actions.contains { $0.extensionID == id } }, "Remove removes it")
            } else { check(false, "The extensions page opens") }
            Self.restore()
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(0)
        }
    }
}
