// Rise's page scripts and messages on Chromium pages, in a real Rise window: scripts that run as
// each document starts, before the page's own, in every frame or only the main one, frames of
// another site (in a process of their own) included; messages to Rise and its replies; running
// scripts in a frame again; and what the page itself can't see.
// Run with python3 scripts/test-chromium-live.py scripts.
import AppKit
@testable import Rise
import RiseChromium

@main @MainActor struct ChromiumScriptMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+120) { print("FAIL the check stopped answering"); exit(1) }
        let app = RCApplication.shared
        let folder = ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!
        guard RCEngine.start(withCachePath: folder + "/chromium", keychain: false) else { print("FAIL Chromium didn't start"); exit(1) }
        let run = ChromiumScriptRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChromiumScriptRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var browser: BrowserController!
    var failures = 0
    let ports = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",").map(String.init)
    var notes: [PageMessage] = [], pageNotes: [PageMessage] = []
    init(folder: String) { self.folder = URL(fileURLWithPath: folder) }
    var site: String { "http://localhost:\(ports[0])" }
    var otherSite: String { "http://127.0.0.1:\(ports[1])" }

    func check(_ condition: Bool, _ message: String) {
        print(condition ? "PASS" : "FAIL", message); if !condition { failures += 1 }
    }
    func waitUntil(_ what: String, _ timeout: TimeInterval = 10, _ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while !(await condition()) {
            if Date().timeIntervalSince(start) > timeout { print("FAIL timed out:", what); failures += 1; return false }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return true
    }
    func value(_ script: String, in page: WebPage, frame: PageFrame? = nil, world: ScriptWorld = .page) async -> Any? {
        try? await page.evaluate(script, arguments: [:], in: frame, world: world)
    }
    func write(_ name: String, _ html: String) throws {
        try "<!doctype html><meta charset=utf-8><title>\(name)</title>\(html)".write(to: folder.appendingPathComponent("\(name).html"), atomically: true, encoding: .utf8)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await checks() } catch { check(false, "\(error)") }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func checks() async throws {
        // What each document saw of Rise's scripts as its own first script ran.
        let seen = "<script>window.seen = {start: document.documentElement.dataset.riseStart, late: document.documentElement.dataset.riseLate, handlers: typeof riseHandlers, isolated: typeof riseIsolated};</script>"
        try write("main", "\(seen)<h1>Main</h1><iframe src='\(site)/same.html'></iframe><iframe src='\(otherSite)/other.html'></iframe>")
        try write("same", "\(seen)<p>Same site")
        try write("other", "\(seen)<p>Other site")
        let main = URL(string: "\(site)/main.html")!

        browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false)
        browser.window?.setContentSize(NSSize(width: 1200, height: 780)); browser.window?.center(); browser.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        let tab = browser.addTab(url: URL(string: "about:blank")!)
        guard let page = tab.page as? ChromiumPage else { check(false, "The tab is a Chromium page"); return }
        _ = await waitUntil("The blank page loads") { page.url?.absoluteString == "about:blank" && !page.isLoading }

        page.addMessageHandler("riseCheckNote", world: .named("Rise.Check")) { [weak self] in self?.notes.append($0) }
        page.addMessageHandler("riseCheckAsk", world: .named("Rise.Check")) { message, reply in
            let body = message.body as? [String: Any]
            if body?["fail"] as? Bool == true { reply(nil, "nope") } else { reply(((body?["question"] as? Int) ?? 0)*7, nil) }
        }
        page.addMessageHandler("riseCheckPage", world: .page) { [weak self] in self?.pageNotes.append($0) }
        page.addUserScript("""
            document.documentElement.dataset.riseStart = 'yes';
            globalThis.riseIsolated = 1;
            riseHandlers.riseCheckNote.postMessage({where: location.href});
            if (window === top) {
              riseHandlers.riseCheckAsk.postMessage({question: 6}).then(answer => document.documentElement.dataset.riseAnswer = String(answer));
              riseHandlers.riseCheckAsk.postMessage({fail: true}).catch(error => document.documentElement.dataset.riseError = error.message);
            }
            """, world: .named("Rise.Check"), mainFrameOnly: false, handlers: ["riseCheckNote", "riseCheckAsk"])
        page.addUserScript("riseMainOnly: document.documentElement.dataset.riseMainOnly = 'yes';",
                           world: .named("Rise.Check"), mainFrameOnly: true, handlers: [])
        page.addUserScript("window.riseFromRise = 1; riseHandlers.riseCheckPage.postMessage(typeof riseHandlers);",
                           world: .page, mainFrameOnly: true, handlers: ["riseCheckPage"])

        // Adding a script runs it in the blank page too, which posts a moment later; only the
        // page's own posts count.
        try await Task.sleep(for: .milliseconds(500))
        notes = []; pageNotes = []
        tab.load(main)
        _ = await waitUntil("The page and its frames load") { page.url == main && !page.isLoading }
        _ = await waitUntil("Both frames post") { self.notes.count >= 3 }
        try await Task.sleep(for: .milliseconds(400))

        let start = await value("return window.seen", in: page) as? [String: Any]
        check(start?["start"] as? String == "yes", "Rise's script runs before the page's own: \(start ?? [:])")
        check(start?["handlers"] as? String == "undefined" && start?["isolated"] as? String == "undefined",
              "The page sees neither Rise's handlers nor its world's variables")
        check(await value("return riseIsolated", in: page, world: .named("Rise.Check")) as? Int == 1, "Rise's world keeps its own")

        let mainNotes = notes.filter { $0.frame.isMain }
        check(mainNotes.count == 1 && mainNotes.first?.frame.origin == site, "The main frame posts once, from \(site): \(notes.map { "\($0.frame.isMain) \($0.frame.origin ?? "nil")" })")
        let same = notes.first { !$0.frame.isMain && $0.frame.origin == site }
        let other = notes.first { !$0.frame.isMain && $0.frame.origin == otherSite }
        check(same != nil && other != nil && notes.count == 3, "Each frame posts once, the other site's in its own process too")
        check(await value("return document.documentElement.dataset.riseAnswer", in: page) as? String == "42", "A reply comes back to the script")
        check(await value("return document.documentElement.dataset.riseError", in: page) as? String == "nope", "And an error as one")
        check(await value("return document.documentElement.dataset.riseMainOnly", in: page) as? String == "yes", "A main-frame script runs in the main frame")

        if let other {
            let seen = await value("return window.seen", in: page, frame: other.frame) as? [String: Any]
            check(seen?["start"] as? String == "yes", "In the other site's frame, before its own script too: \(seen ?? [:])")
            check(await value("return location.origin", in: page, frame: other.frame) as? String == otherSite, "Scripts run in that frame again")
            check(await value("return riseIsolated", in: page, frame: other.frame, world: .named("Rise.Check")) as? Int == 1,
                  "In Rise's world there")
            check(await value("return document.documentElement.dataset.riseMainOnly ?? 'none'", in: page, frame: other.frame) as? String == "none",
                  "But not the main-frame script")
        }
        if let same {
            check(await value("return window.seen.start", in: page, frame: same.frame) as? String == "yes", "And in the same site's frame")
        }

        check(await value("return window.riseFromRise", in: page) as? Int == 1, "A script in the page's own world shares its globals")
        check(pageNotes.count == 1 && pageNotes.first?.body as? String == "object", "And posts from there: \(pageNotes.map(\.body))")
        do {
            _ = try await page.evaluate("throw new Error('boom')", arguments: [:], in: nil, world: .page)
            check(false, "A script that throws reports it")
        } catch { check("\(error.localizedDescription)".contains("boom"), "A script that throws reports it: \(error.localizedDescription)") }
        check(await page.evaluate("return a + b", arguments: ["a": 40, "b": 2], world: "Rise.Check") as? Int == 42, "Scripts take arguments")

        // Added later: in the current document too, and in documents to come.
        page.addScriptToEveryDocument("document.documentElement.dataset.riseLate = 'yes';", world: "Rise.Late")
        _ = await waitUntil("A late script runs in the current document") {
            await self.value("return document.documentElement.dataset.riseLate", in: page) as? String == "yes"
        }
        page.browserView.removeUserScripts(withPrefix: "riseMainOnly:")
        notes = []; pageNotes = []
        page.reload()
        _ = await waitUntil("Reloaded, with its frames") { !page.isLoading && self.notes.count >= 3 }
        try await Task.sleep(for: .milliseconds(400))
        let again = await value("return window.seen", in: page) as? [String: Any]
        check(again?["start"] as? String == "yes" && again?["late"] as? String == "yes", "After a reload, both run first: \(again ?? [:])")
        check(await value("return document.documentElement.dataset.riseMainOnly ?? 'none'", in: page) as? String == "none", "A removed script doesn't")
        check(notes.count == 3 && pageNotes.count == 1, "Each runs once a document: \(notes.count) notes, \(pageNotes.count) from the page's world")
    }
}
