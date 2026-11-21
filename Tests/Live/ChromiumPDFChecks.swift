// Find on page and Page Assistant in a PDF Chromium draws itself, in a real Rise window.
// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumPDFChecks.swift
import AppKit
import CoreText
import RiseChromium
@testable import Rise

@main @MainActor struct ChromiumPDFMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL PDF checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = PDFRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// A PDF's text is in Chromium's PDF viewer, out of reach of Rise's in-page finder and of the
/// scripts that read a page for the model, so both use the engine's own search and text for it.
@MainActor final class PDFRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name)
        if !value { failures += 1 }
    }
    func waitUntil(_ seconds: Double, _ ready: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !(await ready()), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return await ready()
    }
    /// Three pages of known words, as a PDF with a real text layer.
    func writePDF(to url: URL) {
        let pages = ["The first page names an apple and a banana.",
                     "The second page says cherry, and then cherry once more.",
                     "The third page ends with an apple."]
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for text in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await run() } }
    func run() async {
        let suite = "Rise.PDFChecks.\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false,
                                        preferences: UserDefaults(suiteName: suite)!)
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        writePDF(to: folder.appendingPathComponent("fruit.pdf"))
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let tab = browser.addTab(url: URL(string: "http://rise-check.test:\(port)/fruit.pdf")!)
        let page = tab.page as! ChromiumPage
        check(await waitUntil(20) { page.browserView.showsPDF }, "The tab shows a PDF")

        // The model's text: every page, in order, under its number.
        let text = await PageFind.visibleText(in: page) ?? ""
        check(text.hasPrefix("[Page 1 of 3]\nThe first page names an apple and a banana."), "Page Assistant reads the first page: \(text.prefix(80).debugDescription)")
        check(text.contains("[Page 2 of 3]\nThe second page says cherry, and then cherry once more."), "and the second")
        check(text.contains("[Page 3 of 3]\nThe third page ends with an apple."), "and the third")
        let snapshot = try? await PageAssistant.snapshot(of: page)
        check(snapshot?.text == text && snapshot?.title.isEmpty == false, "The question's page is the PDF's text")

        // ⌘F's searches: counted across pages, stepped through both ways, wrapping.
        var matches = await PageFind.find("apple", direction: .restart, in: page)
        check(matches == PageFind.Matches(count: 2, index: 0), "Two apples, the first chosen: \(matches)")
        matches = await PageFind.find("apple", direction: .next, in: page)
        check(matches == PageFind.Matches(count: 2, index: 1), "Next is the second: \(matches)")
        matches = await PageFind.find("apple", direction: .next, in: page)
        check(matches == PageFind.Matches(count: 2, index: 0), "And next wraps to the first: \(matches)")
        matches = await PageFind.find("apple", direction: .previous, in: page)
        check(matches == PageFind.Matches(count: 2, index: 1), "Previous wraps back: \(matches)")
        matches = await PageFind.find("apple", direction: .refresh, in: page)
        check(matches == PageFind.Matches(count: 2, index: 1), "Refresh keeps its place: \(matches)")
        matches = await PageFind.find("CHERRY", direction: .restart, in: page)
        check(matches.count == 2, "Searching ignores case: \(matches)")
        matches = await PageFind.find("durian", direction: .restart, in: page)
        check(matches == PageFind.Matches(count: 0, index: -1), "Nothing that isn't there: \(matches)")

        // The bar itself, as typing in it searches.
        browser.select(tab.id); browser.showFind()
        let bar = browser.findBar
        bar.input.stringValue = "banana"; bar.run(.restart)
        check(await waitUntil(5) { bar.count.stringValue == "1/1" }, "The find bar counts the PDF's matches: \(bar.count.stringValue)")
        browser.hideFind()
        check(await waitUntil(5) { !page.documentFinder.isActive }, "Closing the bar ends the engine's search")
        // What's selected in the PDF is the question's selection, as on any page.
        browser.window?.makeFirstResponder(pageFocusTarget(page.browserView))
        // A click in the document gives it the keys, as a person's would.
        let view = page.browserView, window = browser.window!
        let middle = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: middle, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        }
        try? await Task.sleep(for: .milliseconds(500))
        NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil)
        check(await waitUntil(5) { page.documentSelection.contains("banana") }, "The PDF's selection is read: \(page.documentSelection.prefix(60).debugDescription)")
        let selected = try? await PageAssistant.snapshot(of: page)
        check(selected?.selection.contains("cherry") == true, "and given with the question")

        // The model's quote, found and shown, even run across a page and into the next.
        let found = await PageFind.highlightPassage("[Page 2 of 3]\nThe second page says cherry, and then\ncherry once more.", in: page)
        check(found && page.documentFinder.showsPassage, "The model's quote is found in the PDF")
        let across = await PageFind.highlightPassage("cherry once more. The third page ends", in: page)
        check(across, "A quote across two pages is found by its opening words")
        await PageFind.clearPassage(page)
        check(!page.documentFinder.isActive, "Clearing the passage ends its search")
        check(await PageFind.highlightPassage("grapes are nowhere", in: page) == false, "A quote that isn't there isn't")

        // Leaving the PDF, find goes back to the page's own finder.
        try? """
        <!doctype html><title>Words</title><p>An apple on a page of HTML.</p>
        """.write(to: folder.appendingPathComponent("words.html"), atomically: true, encoding: .utf8)
        page.load(URL(string: "http://rise-check.test:\(port)/words.html")!)
        check(await waitUntil(10) { !page.browserView.showsPDF && !page.isLoading }, "The tab leaves the PDF")
        try? await Task.sleep(for: .milliseconds(300))
        matches = await PageFind.find("apple", direction: .restart, in: page)
        check(matches == PageFind.Matches(count: 1, index: 0), "HTML is searched as before: \(matches)")
        await PageFind.clear(page, selectingCurrent: false)

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
