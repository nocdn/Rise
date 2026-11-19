// Rise's page tools on Chromium: Page Assistant, a pull request's hover card, Gmail's inbox reader,
// Copy Text from Page Image, Share Page, the tab switcher and Smart Rename. Run with
// scripts/test-chromium-live.py tools. The AI service and GitLab's API are answered here, so
// nothing reaches them; Gmail is real, and a fresh profile is signed out of it. The clipboard is put back.
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumToolMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+240) { print("DONE timeout"); ChromiumToolRun.restore(); exit(0) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        _ = RCEngine.start(withCachePath: folder + "/chromium", keychain: false)
        URLProtocol.registerClass(ServiceStub.self)
        let run = ChromiumToolRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// Answers the AI service with a streamed reply, and GitLab's API with nothing found, so the
/// merge request's card describes it from its page.
final class ServiceStub: URLProtocol {
    nonisolated(unsafe) static var bodies: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "openrouter.ai" || host.hasSuffix("rise-check.test")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; body.append(buffer, count: read) }
        }
        let text = String(decoding: body, as: UTF8.self)
        Self.lock.lock(); Self.bodies.append(text); Self.lock.unlock()
        guard request.url?.host == "openrouter.ai" else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        let reply = text.contains("When does it launch") ? ["{\"snippet\":\"March 3\"}\n", "It launches on ", "**March 3**."] : ["Adds the launch banner."]
        var stream = ""
        for content in reply {
            let chunk: [String: Any] = ["choices": [["delta": ["content": content]]]]
            stream += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self) + "\n\n"
        }
        stream += "data: [DONE]\n\n"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stream.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return bodies }
}

@MainActor final class ChromiumToolRun: NSObject, NSApplicationDelegate {
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
    func value(_ script: String, in page: WebPage, world: ScriptWorld = .page) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: nil, world: world)
    }
    func write(_ path: String, _ html: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try html.write(to: url, atomically: true, encoding: .utf8)
    }
    func open(_ url: URL) async -> BrowserTab {
        let tab = browser.addTab(url: url)
        _ = await waitUntil(15) { tab.page.url?.path == url.path && !tab.page.isLoading }
        return tab
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.saved = (NSPasteboard.general.pasteboardItems ?? []).map { item in Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }) }
        Task {
            let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
            let local = "http://localhost:\(port)"
            try write("launch.html", "<!doctype html><meta charset=utf-8><title>Launch</title><h1>Launch notes</h1><p>The launch is on <b id=date>March 3</b>, after the beta.</p>")
            try write("words.html", "<!doctype html><meta charset=utf-8><title>Words</title><body style='margin:40px;font:64px Helvetica'>Rise reads this picture")
            try write("group/app/-/merge_requests/12/index.html", "<!doctype html><meta charset=utf-8><title>Add the launch banner (!12) · Merge requests · Group / App · GitLab</title><h1>Add the launch banner</h1><p>Shows a banner on launch day.</p>")
            let prefs = UserDefaults(suiteName: "rise-tools-probe-\(ProcessInfo.processInfo.processIdentifier)")!
            browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: prefs)
            // The check answers OpenRouter itself, but Rise asks only with a key.
            browser.aiKeys.read = { _ in nil }; browser.aiKeys.write = { _, _ in }; browser.setAIKey("fixture", for: .openRouter)
            browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)

            // Page Assistant reads the page and what's selected on it, answers, and highlights the
            // passage it quotes.
            let launch = await open(URL(string: local + "/launch.html")!)
            _ = await value("getSelection().selectAllChildren(document.getElementById('date')); return 0", in: launch.page)
            let snapshot = try? await PageAssistant.snapshot(of: launch.page)
            check(snapshot?.title == "Launch" && snapshot?.text.contains("The launch is on March 3") == true && snapshot?.selection == "March 3",
                  "Page Assistant reads the page's title, text and selection: \(snapshot.map { "\($0.title) | \($0.selection) | \($0.text.prefix(60))" } ?? "nothing")")
            var answer = ""
            if let ask = browser.findBar(for: launch).answer {
                do { for try await token in ask("When does it launch?", []) { answer += token } } catch { answer += "error \(error)" }
            }
            check(answer.contains("It launches on") && answer.contains("March 3"), "It answers about the page: \(answer)")
            check(ServiceStub.requests().contains { $0.contains("When does it launch") && $0.contains("The launch is on March 3") },
                  "With the page's text in the question it sends")
            let highlighted = await waitUntil(3) { await self.value("return CSS.highlights.get('rise-passage')?.size ?? 0", in: launch.page, world: .named(PageFind.worldName)) as? Int ?? 0 > 0 }
            check(highlighted, "And highlights the passage it quotes")
            await PageFind.clearPassage(launch.page)
            let cleared = await value("return CSS.highlights.get('rise-passage')?.size ?? 0", in: launch.page, world: .named(PageFind.worldName)) as? Int
            check(cleared == 0, "Which goes again when cleared")

            // A merge request's hover card describes it from its page when GitLab's API can't.
            let mergeURL = URL(string: "http://gitlab.rise-check.test:\(port)/group/app/-/merge_requests/12/")!
            let merge = await open(mergeURL)
            check(merge.page.url?.host == "gitlab.rise-check.test" && merge.title.hasPrefix("Add the launch banner"), "A merge request opens: \(merge.page.url?.absoluteString ?? "") \(merge.title)")
            browser.select(launch.id)
            browser.tabHoverChanged(merge.id, hovering: true)
            let shown = await waitUntil(5) { self.browser.tabHoverCards.shownID == merge.id }
            check(shown && browser.tabHoverCards.pullRequestCard.superview != nil, "Hovering its tab opens its card")
            let pr = PullRequest(url: mergeURL)!
            let described = await waitUntil(15) { self.browser.tabHoverCards.summaries.entry(for: pr).phase == .done }
            check(described && browser.tabHoverCards.summaries.entry(for: pr).summary == "Adds the launch banner.",
                  "Which describes it: \(browser.tabHoverCards.summaries.entry(for: pr).summary)")
            check(ServiceStub.requests().contains { $0.contains("Shows a banner on launch day") }, "From the text of its page")
            browser.tabHoverChanged(merge.id, hovering: false)
            browser.hideTabHoverCard()

            // Gmail's card reads the inbox through a hidden page of its own, which finds a fresh
            // profile signed out.
            let account = GmailAccount(url: URL(string: "https://mail.google.com/mail/u/0/#inbox"))!
            let tabsBefore = browser.tabs.count
            browser.gmailInbox.prepare(account: account, category: .primary, source: launch.page, host: browser.root)
            let signedOut = await waitUntil(30) { self.browser.gmailInbox.error != nil }
            check(signedOut && browser.gmailInbox.error == GmailPageReader.Failure.signedOut.message,
                  "Gmail's inbox reader loads Gmail out of sight, signed out here: \(browser.gmailInbox.error ?? "no answer")")
            let hidden = browser.root.subviews.contains { $0 is HiddenAccessibilityView && $0.frame.minX < -10000 }
            check(hidden && browser.tabs.count == tabsBefore, "Its page stays offscreen, and isn't a tab")
            browser.gmailInbox.tearDown()
            check(!browser.root.subviews.contains { $0 is HiddenAccessibilityView }, "And goes when it's done")

            // Copy Text from Page Image reads the page's picture.
            let words = await open(URL(string: local + "/words.html")!)
            try? await Task.sleep(for: .milliseconds(800))
            NSPasteboard.general.clearContents()
            browser.copyTextFromPageImage()
            let read = await waitUntil(10) { NSPasteboard.general.string(forType: .string) != nil }
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            check(read && text.localizedCaseInsensitiveContains("Rise reads this picture"), "Copy Text from Page Image copies the page's words: \(text)")
            let sheet = browser.window?.attachedSheet
            func labels(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels) }
            let said: [String] = sheet?.contentView.map(labels) ?? []
            check(said.contains("Text copied"), "And says so: \(said)")
            if let sheet { browser.window?.endSheet(sheet) }

            // Share Page offers the page's address.
            let started = Date()
            browser.shareCurrentPage()
            check(Date().timeIntervalSince(started) < 2 && browser.sharingPicker != nil, "Share Page opens the share picker")
            try? await Task.sleep(for: .milliseconds(600))
            if let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) { NSApp.postEvent(esc, atStart: false) }
            try? await Task.sleep(for: .milliseconds(400))

            // The tab switcher shows each tab's picture, and switches to the one picked.
            browser.select(launch.id); try? await Task.sleep(for: .milliseconds(500))
            browser.select(words.id); try? await Task.sleep(for: .milliseconds(500))
            let pictured = await waitUntil(10) { [launch, words, merge].allSatisfy { $0.thumbnail != nil } }
            browser.advanceTabSwitch(1)
            let revealed = await waitUntil(2) { !self.browser.tabSwitcher.isHidden && self.browser.tabSwitcher.superview != nil }
            func images(_ v: NSView) -> [NSImage] { ((v as? NSImageView)?.image.map { [$0] } ?? []) + v.subviews.flatMap(images) }
            let shownPictures = browser.tabs.filter { tab in images(browser.tabSwitcher).contains { $0 === tab.thumbnail } }.count
            check(revealed && pictured && shownPictures == browser.tabs.count,
                  "The tab switcher shows every tab with its picture (\(shownPictures) of \(browser.tabs.count))")
            browser.commitTabSwitch()
            check(browser.selectedID == launch.id && launch.page.view.window != nil, "And switches to the last tab used")

            // Tabs never shown get their pictures in the background, out of sight.
            let unseen = (1...2).map { browser.addTab(url: URL(string: local + "/words.html?unseen=\($0)")!, background: true) }
            let backgroundPictured = await waitUntil(20) { unseen.allSatisfy { $0.thumbnail != nil } }
            let putBack = await waitUntil(3) { unseen.allSatisfy { $0.page.view.superview == nil } }
            // The page drew: its picture isn't one flat colour.
            func colours(_ image: NSImage?) -> Int {
                guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 0 }
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current?.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: 32, height: 32)); NSGraphicsContext.restoreGraphicsState()
                return Set((0..<32*32).map { bitmap.colorAt(x: $0%32, y: $0/32)?.description ?? "" }).count
            }
            check(backgroundPictured && putBack && browser.selectedID == launch.id && unseen.allSatisfy { colours($0.thumbnail) > 1 },
                  "Tabs opened in the background get switcher pictures without being shown (\(unseen.filter { $0.thumbnail != nil }.count) of 2)")
            browser.select(unseen[0].id)
            check(unseen[0].page.view.window != nil && !unseen[0].heldSinceBackgroundPicture && !unseen[0].page.isCovered,
                  "And show normally once picked")
            browser.select(launch.id)

            // Smart Rename, for now, shimmers the tab's title.
            browser.smartRename(launch.id)
            check(browser.sidebar.rows[launch.id]?.titleShimmer.isRunning == true, "Smart Rename shimmers the tab's title")

            print("\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
            Self.restore()
            print("DONE"); exit(0)
        }
    }
}
