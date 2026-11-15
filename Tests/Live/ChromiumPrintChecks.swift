// python3 scripts/test-chromium-live.py Tests/Live/ChromiumPrintChecks.swift
import AppKit
@testable import Rise
import RiseChromium
import PDFKit

/// Printing as in Chrome: File > Print and ⌘P open Chrome's print preview over the page, as do the
/// page's own print() and Print… in the page's menu, and a PDF prints as itself.
@main @MainActor struct PrintChecksMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+(ProcessInfo.processInfo.environment["RISE_PRINT_HOLD"] == nil ? 180 : 420)) { print("FAIL timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        let run = PrintChecksRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class PrintChecksRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var menus: AppDelegate!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ valid: Bool, _ text: String) { print(valid ? "PASS" : "FAIL", text); if !valid { failures += 1 } }
    func wait(_ text: String, seconds: TimeInterval = 10, _ predicate: () async -> Bool) async throws {
        let until = Date().addingTimeInterval(seconds)
        while !(await predicate()), Date() < until { try await Task.sleep(for: .milliseconds(50)) }
        let valid = await predicate(); check(valid, text)
        if !valid { throw NSError(domain: text, code: 1) }
    }
    func value(_ body: String, _ page: WebPage) async -> Any? { try? await page.evaluate(body, arguments: [:], in: nil, world: .page) }
    func shot(_ name: String) {
        // The screen where the window is: Chromium draws in layers a capture of the window alone misses.
        guard let window = browser.window, let screen = NSScreen.screens.first else { return }
        var rect = window.frame; rect.origin.y = screen.frame.maxY-rect.maxY
        guard let image = CGWindowListCreateImage(rect, .optionOnScreenOnly, kCGNullWindowID, .bestResolution) else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name).png"))
        if let out = ProcessInfo.processInfo.environment["RISE_PRINT_SHOTS"] {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
        }
    }
    func press(_ key: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = .command) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: browser.window!.windowNumber, context: nil, characters: key,
                                             charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!)
        }
    }
    func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
        browser.window!.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: browser.window!.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .rightMouseDown || type == .leftMouseDown ? 1 : 0)!)
    }
    func point(_ selector: String, in page: WebPage) async -> NSPoint {
        let xy = await value("const r=document.querySelector('\(selector)').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]", page) as! [Double]
        return page.view.convert(NSPoint(x: xy[0], y: page.view.isFlipped ? xy[1] : page.view.bounds.height-xy[1]), to: nil)
    }
    func rightClick(_ selector: String, in page: WebPage) async -> NSMenu? {
        var menu: NSMenu?
        browser.presentContextMenu = { shown, _, _ in menu = shown }
        let at = await point(selector, in: page)
        mouse(.mouseMoved, at: at); try? await Task.sleep(for: .milliseconds(50))
        mouse(.rightMouseDown, at: at); mouse(.rightMouseUp, at: at)
        for _ in 0..<50 where menu == nil { try? await Task.sleep(for: .milliseconds(20)) }
        return menu
    }
    func fileMenuItem(_ title: String) -> NSMenuItem? {
        NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu?.items.first { $0.title == title }
    }
    /// Print preview is a dialog of the page's own, over it; leaving the page closes it.
    func closePreview(_ page: ChromiumPage) async throws {
        page.reload()
        try await wait("Reloading closes the print preview") { page.browserView.canPrint && !page.isLoading }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            browser?.saveWork?.cancel(); browser?.tabs.forEach { $0.cancelLoad() }; browser?.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }

    func run() async throws {
        let suite = "Rise.PrintChecks.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        menus = AppDelegate(); menus.browser = browser; menus.buildMenu()
        browser.window?.setFrameAutosaveName(""); browser.window?.setContentSize(NSSize(width: 1200, height: 900))
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let site = "http://localhost:\(ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0])"
        try """
        <!doctype html><title>Booking confirmed</title><body style='font:20px system-ui;margin:40px'>
        <h1>Booking confirmed</h1><p id=text>Reference ABC123. Print this page for your visit.</p>
        <button id=print onclick='window.clicked=(window.clicked||0)+1;window.print()' style='font:20px system-ui'>Print</button>
        <script>addEventListener('beforeprint',()=>window.printing=(window.printing||0)+1)</script>
        <p style='height:60px'></p><p id=blank style='height:200px'>&nbsp;</p>
        """.write(to: folder.appendingPathComponent("print.html"), atomically: true, encoding: .utf8)

        let tab = browser.addTab(url: URL(string: site+"/print.html")!), page = tab.page as! ChromiumPage
        browser.hidePalette()
        try await wait("The page loads") { await self.value("return document.readyState==='complete'", page) as? Bool == true && !page.isLoading }
        browser.window?.makeFirstResponder(page.view)

        // File > Print…, ⌘P.
        let item = fileMenuItem("Print…")
        check(item?.keyEquivalent == "p" && item?.keyEquivalentModifierMask == .command, "File has Print… on ⌘P")
        check(item.map { browser.validateMenuItem($0) } == true, "Print… is available for a loaded page")
        check(fileMenuItem("Print Using System Dialog…") != nil, "File has Print Using System Dialog…")
        check(page.browserView.canPrint, "The page can print")
        browser.printPage()
        try await wait("File > Print opens Chrome's print preview over the page") { !page.browserView.canPrint }
        try await Task.sleep(for: .seconds(4))
        shot("1-file-print")
        check(item.map { browser.validateMenuItem($0) } == false, "Print… waits while the preview is open, as Chrome's does")
        // Held open for Save as PDF to be chosen in it by hand (or by an agent), into this folder.
        if let saves = ProcessInfo.processInfo.environment["RISE_PRINT_HOLD"].map(URL.init(fileURLWithPath:)) {
            print("HOLDING window \(browser.window!.windowNumber)")
            let saved = { (try? FileManager.default.contentsOfDirectory(at: saves, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "pdf" } }
            try await wait("Save as PDF saves the page", seconds: 240) { saved() != nil }
            try await Task.sleep(for: .seconds(1))
            let text = saved().flatMap { PDFDocumentText.of($0) } ?? ""
            check(text.contains("Booking confirmed") && text.contains("ABC123"), "The saved PDF is the page: \(text.prefix(60))")
            return
        }
        try await closePreview(page)

        press("p", code: 35)
        try await wait("⌘P, which the page doesn't use, opens the print preview") { !page.browserView.canPrint }
        try await closePreview(page)

        // The page's own Print button.
        // Deferred, as print() holds the page's script until the preview closes, as Chrome's does.
        _ = await value("setTimeout(()=>document.querySelector('#print').click());return 0", page)
        try await wait("The page's own print() opens the print preview") { !page.browserView.canPrint }
        try await Task.sleep(for: .seconds(2))
        shot("2-page-print-button")
        try await closePreview(page)

        // Print… in the page's menu, and with a selection.
        let pageMenu = await rightClick("#blank", in: page)
        let pagePrint = pageMenu?.items.first { $0.title == "Print…" }
        check(pagePrint?.isEnabled == true, "The page's menu has Print…")
        if let pagePrint, let action = pagePrint.action { NSApp.sendAction(action, to: pagePrint.target, from: pagePrint) }
        try await wait("Print… from the page's menu opens the print preview") { !page.browserView.canPrint }
        try await closePreview(page)
        _ = await value("const r=document.createRange();r.selectNodeContents(document.querySelector('#text'));getSelection().removeAllRanges();getSelection().addRange(r);return 0", page)
        let selectionMenu = await rightClick("#text", in: page)
        check(selectionMenu?.items.contains { $0.title == "Print…" && $0.isEnabled } == true, "A selection's menu has Print…")
        _ = await value("getSelection().removeAllRanges();return 0", page)

        // A PDF prints as itself, through Chrome's PDF viewer.
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: CGDataConsumer(data: pdf as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("A PDF to print" as NSString).draw(at: NSPoint(x: 72, y: 760), withAttributes: [.font: NSFont.systemFont(ofSize: 28)])
        NSGraphicsContext.current = nil
        context.endPDFPage(); context.closePDF()
        try (pdf as Data).write(to: folder.appendingPathComponent("doc.pdf"))
        let pdfTab = browser.addTab(url: URL(string: site+"/doc.pdf")!), pdfPage = pdfTab.page as! ChromiumPage
        try await wait("The PDF opens in Chrome's viewer") { !pdfPage.isLoading && pdfPage.url?.path == "/doc.pdf" }
        try await Task.sleep(for: .seconds(2))
        check(pdfPage.browserView.canPrint, "The PDF can print")
        browser.printPage()
        try await wait("Print on a PDF opens the print preview") { !pdfPage.browserView.canPrint }
        try await Task.sleep(for: .seconds(2))
        shot("3-pdf-print")
    }
}

enum PDFDocumentText {
    static func of(_ url: URL) -> String? { PDFDocument(url: url)?.string }
}
