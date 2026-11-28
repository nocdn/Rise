// Look Up on a Chromium page: a force click on a word marks it and opens Rise's popover, with the
// dictionary's entry, the line of the page the word is in, a spinner while the AI provider
// explains it, then the explanation, kept for the next time the word is looked up on the page.
// The AI service is answered here, after a pause, so nothing reaches it. With
// RISE_LOOKUP_PICTURES set, pictures of each state are kept in RISE_PEEK_OUT.
// python3 scripts/test-chromium-live.py Tests/Live/ChromiumLookUpChecks.swift
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct LookUpMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+90) { print("FAIL timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.appendingPathComponent("chromium").path, keychain: false) else { exit(1) }
        URLProtocol.registerClass(LookUpServiceStub.self)
        let run = LookUpRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

/// Answers OpenRouter with an explanation, a second and a half later.
final class LookUpServiceStub: URLProtocol {
    nonisolated(unsafe) static var bodies: [String] = []
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "openrouter.ai" }
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
        let reply = text.contains("Looked up: whiteboard")
            ? ["The board ", "where a design was sketched in a meeting — the page means the protocol you **argued for**, not what the API does."]
            : ["A request that’s **safe to repeat**: ", "sending it twice has the same effect as sending it once, so a client can retry after a timeout ",
               "without charging a card twice or creating a duplicate order."]
        var stream = ""
        for content in reply {
            let chunk: [String: Any] = ["choices": [["delta": ["content": content]]]]
            stream += "data: "+String(decoding: try! JSONSerialization.data(withJSONObject: chunk), as: UTF8.self)+"\n\n"
        }
        stream += "data: [DONE]\n\n"
        let client = client, request = request
        DispatchQueue.global().asyncAfter(deadline: .now()+1.5) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(stream.utf8)); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
    static func requests() -> [String] { lock.lock(); defer { lock.unlock() }; return bodies }
}

@MainActor final class LookUpRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ valid: Bool, _ text: String) { print(valid ? "PASS" : "FAIL", text); if !valid { failures += 1 } }
    func waitUntil(_ seconds: Double, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(50)) }
        return await condition()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await run() } catch { check(false, error.localizedDescription) }
            browser?.tabs.forEach { $0.cancelLoad() }; browser?.window?.orderOut(nil)
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
        }
    }

    /// Every view under `view`, deepest last.
    func views(_ view: NSView) -> [NSView] { [view]+view.subviews.flatMap(views) }
    func labels(_ view: NSView) -> [String] {
        views(view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }
    }

    /// A force click's Look Up on the word `id` marks, through Chromium's own path.
    func forceClick(_ id: String, in tab: BrowserTab) async throws {
        let rect = try await tab.page.evaluate("const r = document.getElementById(id).getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]",
                                               arguments: ["id": id], world: nil) as? [Double] ?? []
        guard rect.count == 2, let page = views(tab.page.view).first(where: { NSStringFromClass(type(of: $0)) == "RenderWidgetHostViewCocoa" }) else {
            throw NSError(domain: "No page view or word", code: 1)
        }
        let zoom = tab.page.zoom
        let local = NSPoint(x: rect[0]*zoom, y: page.isFlipped ? rect[1]*zoom : page.bounds.height-rect[1]*zoom)
        // Chromium reads only where it was.
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: page.convert(local, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: browser.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        page.quickLook(with: event)
    }

    func popoverView() -> LookUpContentView? {
        NSApp.windows.lazy.filter(\.isVisible).compactMap { $0.contentView.flatMap { self.views($0).lazy.compactMap { $0 as? LookUpContentView }.first } }.first
    }

    /// The window and the popover beside it, as on screen, with RISE_LOOKUP_PICTURES set: whatever
    /// is in front of them is pictured too.
    func picture(_ name: String) {
        guard ProcessInfo.processInfo.environment["RISE_LOOKUP_PICTURES"] != nil, let window = browser.window, let screen = window.screen else { return }
        let frame = window.frame
        let top = screen.frame.maxY-frame.maxY
        let file = folder.appendingPathComponent(name).path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R", "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))", file]
        try? process.run(); process.waitUntilExit()
        print("PICTURE", file)
    }

    func run() async throws {
        let suite = "Rise.LookUp.\(UUID())", preferences = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        // The check answers OpenRouter itself, but Rise asks only with a key.
        browser.aiKeys.read = { _ in nil }; browser.aiKeys.write = { _, _ in }; browser.setAIKey("fixture", for: .openRouter)
        browser.window?.setFrameAutosaveName(""); browser.window?.setContentSize(NSSize(width: 1100, height: 720)); browser.window?.center()
        browser.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        try """
        <!doctype html><meta charset=utf-8><title>The contract you ship outlives your code</title>
        <style>body{font:17px/1.8 -apple-system,system-ui;background:#f3f4f6;color:#1f2430;margin:0;padding:60px 120px}
        .card{background:#fff;border:1px solid #e3e5ea;border-radius:14px;padding:22px 30px;max-width:620px}</style>
        <div class=card><p>An API is the contract between client and server. It's how the outside world asks your service to do work, and once you ship v1 it's far harder to change than the implementation behind it.</p>
        <p>Three protocols dominate today: REST, GraphQL, and gRPC. Each one trades developer experience, network efficiency, and tooling for the others. Picking the right one matters, but a good API is mostly about predictability, <span id=word>idempotency</span>, and clear errors, not which protocol you wrote on the <span id=board>whiteboard</span>.</p></div>
        """.write(to: folder.appendingPathComponent("lesson.html"), atomically: true, encoding: .utf8)
        let url = URL(string: "http://localhost:\(port)/lesson.html")!
        let tab = browser.addTab(url: url)
        _ = await waitUntil(15) { tab.page.url?.path == url.path && !tab.page.isLoading }
        try? await Task.sleep(for: .milliseconds(600))

        // A word the dictionary doesn't have: the popover is its line and the explanation alone.
        try await forceClick("word", in: tab)
        let opened = await waitUntil(5) { self.popoverView()?.window?.isVisible == true }
        check(opened, "A force click on a word opens Rise's Look Up popover")
        let marked = views(tab.page.view.superview ?? tab.page.view).contains { $0 is LookUpHighlight }
        check(marked, "And marks the word on the page")
        if let content = popoverView() {
            let shown = labels(content)
            check(shown.contains("Generating explanation in context"), "It's generating an explanation: \(shown)")
            check(shown.contains { $0.contains("predictability, idempotency, and clear errors") }, "Under the line of the page it's in: \(shown)")
        }
        try? await Task.sleep(for: .milliseconds(500))
        picture("lookup-generating.png")
        let before = popoverView()?.window?.frame.height ?? 0
        let explained = await waitUntil(8) { self.labels(self.popoverView() ?? NSView()).contains { $0.hasPrefix("A request that’s safe to repeat") } }
        check(explained, "The explanation takes its place")
        try? await Task.sleep(for: .milliseconds(700))
        let after = popoverView()?.window?.frame.height ?? 0
        check(after > before+20, "And the popover grows to fit it: \(before) → \(after)")
        check(!labels(popoverView() ?? NSView()).contains("Generating explanation in context"), "In the waiting line's place")
        picture("lookup-generated.png")
        let request = LookUpServiceStub.requests().last ?? ""
        check(request.contains("Looked up: idempotency") && request.contains("<passage>") && request.contains("predictability, idempotency, and clear errors"),
              "It asks with the word and the passage it's in")

        // A dictionary word: its entry above the hairline.
        try await forceClick("board", in: tab)
        let reopened = await waitUntil(5) { self.labels(self.popoverView() ?? NSView()).contains("white·board") }
        check(reopened, "Another word's Look Up shows its dictionary entry: \(labels(popoverView() ?? NSView()))")
        try? await Task.sleep(for: .milliseconds(300))
        check(views(tab.page.view.superview ?? tab.page.view).filter { $0 is LookUpHighlight }.count == 1, "Marking only that word")
        try? await Task.sleep(for: .milliseconds(500))
        picture("lookup-dictionary-generating.png")
        _ = await waitUntil(8) { self.labels(self.popoverView() ?? NSView()).contains { $0.hasPrefix("The board") } }
        try? await Task.sleep(for: .milliseconds(700))
        picture("lookup-dictionary-generated.png")

        // Typing on the page closes it, and the mark goes with it.
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: browser.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        let closed = await waitUntil(3) { self.popoverView() == nil }
        check(closed, "Escape closes it")
        try? await Task.sleep(for: .milliseconds(400))
        check(!views(tab.page.view.superview ?? tab.page.view).contains { $0 is LookUpHighlight }, "And unmarks the word")

        // The same word again on the page: its explanation is kept, so it's there at once.
        let asked = LookUpServiceStub.requests().count
        try await forceClick("word", in: tab)
        let ready = await waitUntil(2) { self.popoverView()?.window?.isVisible == true }
        let shown = labels(popoverView() ?? NSView())
        check(ready && shown.contains { $0.hasPrefix("A request that’s safe to repeat") } && !shown.contains("Generating explanation in context"),
              "Looking the same word up again shows its explanation at once: \(shown)")
        check(LookUpServiceStub.requests().count == asked, "Without asking again")
        picture("lookup-kept.png")

        // Without an API key, a dictionary word still shows its entry, saying why there's no explanation.
        browser.setAIKey(nil, for: .openRouter)
        let unkeyed = LookUpServiceStub.requests().count
        try await forceClick("board", in: tab)
        let plain = await waitUntil(3) { self.labels(self.popoverView() ?? NSView()).contains("No API key set for explanations") }
        let said = labels(popoverView() ?? NSView())
        check(plain && said.contains("white·board") && !said.contains("Generating explanation in context") && !said.contains { $0.hasPrefix("“") },
              "Without an API key, the dictionary's entry shows and says there's no key: \(said)")
        check(LookUpServiceStub.requests().count == unkeyed, "And nothing is asked")
        picture("lookup-no-key.png")
    }
}
