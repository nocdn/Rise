// Run: python3 scripts/test-chromium-live.py Tests/Live/ChromiumChatToolChecks.swift
//
// The chat's browser tools on the engine itself, out of sight: its window is never shown and
// the check isn't in the Dock, so it takes no focus. Pages come from a local site: a results page
// marked up as Google's and Kagi's are, an article written by its script, a PDF, and a page for a
// tab that hasn't loaded. With RISE_AI_LIVE=1 it also asks the real model to read a page.
import AppKit
import PDFKit
import RiseChromium
@testable import Rise

@main @MainActor struct ChromiumChatToolMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        DispatchQueue.main.asyncAfter(deadline: .now()+180) { print("FAIL chat tool checks timed out"); exit(1) }
        let app = RCApplication.shared
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISE_PEEK_OUT"]!)
        guard RCEngine.start(withCachePath: folder.path+"/chromium", keychain: false) else { exit(1) }
        let run = ChatToolRun(folder: folder)
        app.delegate = run; app.setActivationPolicy(.accessory); app.run()
        withExtendedLifetime(run) {}
    }
}

@MainActor final class ChatToolRun: NSObject, NSApplicationDelegate {
    let folder: URL
    var failures = 0
    init(folder: URL) { self.folder = folder }
    func check(_ value: Bool, _ name: String) {
        print(value ? "PASS" : "FAIL", name)
        if !value { failures += 1 }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do { try await exercise() } catch { check(false, String(describing: error)) }
            print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
            exit(failures == 0 ? 0 : 1)
        }
    }

    func exercise() async throws {
        let suite = "RiseChatToolChecks-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let port = ProcessInfo.processInfo.environment["RISE_CHECK_PORTS"]!.split(separator: ",")[0]
        let site = "http://localhost:\(port)"
        try fixtures(site: site)

        let browser = BrowserController(sessionURL: folder.appendingPathComponent("session.json"), restore: false, preferences: preferences)
        defer { browser.saveWork?.cancel(); browser.tabs.forEach { $0.cancelLoad() }; browser.window?.orderOut(nil) }
        let tools = AIChatBrowserTools(browser: browser)
        defer { tools.reader.close() }

        // Results picked out of a page marked up as Google's, and as Kagi's.
        let google = try await tools.reader.search(URL(string: site+"/google.html?q=otters")!)
        check(google.results.map(\.url) == ["https://otters.example/hands", "https://en.wikipedia.org/wiki/Sea_otter"],
              "Google's results, through its redirect links and without its own: \(google.results.map(\.url))")
        check(google.results.first?.title == "Why sea otters hold hands", "Each result's title")
        check(google.results.first?.snippet.contains("hold hands while they sleep") == true, "Each result's snippet: \(google.results.first?.snippet ?? "")")
        check(google.results.first?.snippet.contains("Wikipedia") == false, "A snippet holds no other result")
        let kagi = try await tools.reader.search(URL(string: site+"/kagi.html?q=otters")!)
        check(kagi.results.map(\.title) == ["Sea otter - Wikipedia", "Otters | WWF"], "Kagi's results: \(kagi.results.map(\.title))")
        let duck = try await tools.reader.search(URL(string: site+"/duckduckgo.html?q=otters")!)
        check(duck.results.map(\.url) == ["https://otters.example/hands", "https://www.worldwildlife.org/species/sea-otter"], "DuckDuckGo's results, through its redirect links: \(duck.results.map(\.url))")
        check(duck.results.first?.snippet == "Sea otters hold hands while they sleep.", "And their snippets: \(duck.results.first?.snippet ?? "")")
        let consent = try await tools.reader.search(URL(string: site+"/consent.html")!)
        check(consent.results.isEmpty && consent.text.contains("Before you continue"), "A page without results gives its text instead")

        // A page read out of sight, after its script has written it.
        let article = try await tools.reader.read(URL(string: site+"/article.html")!)
        check(article.title == "Otter facts", "A page's title: \(article.title)")
        check(article.text.contains("The secret word is marmalade."), "Text a page's script writes is read")
        let pdf = try await tools.reader.pdf(URL(string: site+"/otters.pdf")!, title: "")
        check(pdf.text.contains("Otters have the densest fur"), "A PDF's text: \(pdf.text.prefix(80))")

        // A tab that hasn't loaded, as one restored at launch, is loaded out of sight and muted to be read.
        let asleep = browser.addTab(background: true)
        asleep.requestedURL = URL(string: site+"/asleep.html")!; asleep.title = "Asleep"
        check(asleep.page.url == nil, "The tab starts without its page")
        let readTab = try XCTUnwrapTool(tools, "read_tab")
        let read = try await readTab.run(["tab": AIChatBrowserTools.shortID(asleep.id)], readTab.step(["tab": AIChatBrowserTools.shortID(asleep.id)]))
        check(read.output.contains("Woken up to be read."), "A sleeping tab is read: \(read.output.suffix(120))")
        check(asleep.heldSinceBackgroundPicture, "It loads muted and held until it's shown")

        // The words of a search found in a loaded tab's text.
        let loaded = browser.addTab(url: URL(string: site+"/recipe.html")!, background: true)
        let deadline = Date()+10
        while (loaded.page.isLoading || loaded.page.url == nil), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(500))
        let searchTabs = try XCTUnwrapTool(tools, "search_tabs")
        let found = try await searchTabs.run(["query": "marmalade"], searchTabs.step(["query": "marmalade"]))
        check(found.output.contains(AIChatBrowserTools.shortID(loaded.id)) && found.output.contains("In its text: …"), "Searching tabs finds words in their text: \(found.output)")

        // The real search engine, out of sight: whatever it shows a fresh profile.
        let web = try await tools.reader.search(browser.searchProvider.searchURL("sea otter")!)
        print("INFO \(browser.searchProvider.title) gave \(web.results.count) results: \(web.results.prefix(3).map(\.title)); text \(web.text.prefix(120))")
        let webSearch = try XCTUnwrapTool(tools, "web_search")
        let searched = try await webSearch.run(["query": "sea otter"], webSearch.step(["query": "sea otter"]))
        check(searched.output.hasPrefix("Results from"), "Searching the web gives results, from DuckDuckGo if the engine shows none: \(searched.output.prefix(200))")

        if ProcessInfo.processInfo.environment["RISE_AI_LIVE"] == "1" {
            var messages = AIChatPrompt.messages(history: [], current: AIChatTurn(question: "Read \(site)/article.html and tell me the secret word.", pages: []))
            messages[0]["content"] = (messages[0]["content"] as! String)+"\n\n"+AIChatBrowserTools.instructions+"\n\n"+tools.context()
            var answer = "", steps: [String] = []
            try await AIChatAgent.run(AIChatModels.model(for: .openRouter, messages: messages), tools: tools.tools) { event in
                switch event {
                case .text(let piece): answer += piece
                case .step(_, let step) where step.state != .running: steps.append(step.text)
                default: break
                }
            }
            print("INFO steps: \(steps); answer: \(answer)")
            check(answer.localizedCaseInsensitiveContains("marmalade"), "The model reads a page with the engine and answers from it")
        }
    }

    func XCTUnwrapTool(_ tools: AIChatBrowserTools, _ name: String) throws -> AIChatTool {
        guard let tool = tools.tools.first(where: { $0.name == name }) else { throw AIChatToolFailure(message: "No \(name)") }
        return tool
    }

    func fixtures(site: String) throws {
        func write(_ name: String, _ html: String) throws { try html.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        try write("google.html", """
        <!doctype html><meta charset="utf-8"><title>otters - Google Search</title><body>
        <div id="nav"><a href="/search?q=otters&tbm=isch"><h3>Images</h3></a></div>
        <div id="search">
          <div class="g"><div><a href="/url?q=https://otters.example/hands&sa=U&ved=1"><h3>Why sea otters hold hands</h3><cite>otters.example › hands</cite></a></div>
            <div class="VwiC3b">Sea otters hold hands while they sleep, so they don't drift apart.</div></div>
          <div class="g"><div><a href="https://en.wikipedia.org/wiki/Sea_otter"><h3>Sea otter</h3><cite>Wikipedia</cite></a></div>
            <div class="VwiC3b">The sea otter is a marine mammal native to the coasts of the northern Pacific.</div></div>
        </div>
        """)
        try write("kagi.html", """
        <!doctype html><title>otters - Kagi Search</title><body>
        <div class="search-result"><h3 class="__sri-title"><a class="__sri_title_link" href="https://en.wikipedia.org/wiki/Sea_otter">Sea otter - Wikipedia</a></h3>
          <div class="__sri-desc">The sea otter is a marine mammal.</div></div>
        <div class="search-result"><h3 class="__sri-title"><a class="__sri_title_link" href="https://www.worldwildlife.org/species/sea-otter">Otters | WWF</a></h3>
          <div class="__sri-desc">Sea otters are a keystone species.</div></div>
        """)
        try write("duckduckgo.html", """
        <!doctype html><meta charset="utf-8"><title>otters at DuckDuckGo</title><body>
        <div class="result"><h2 class="result__title"><a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fotters.example%2Fhands&rut=1">Why sea otters hold hands</a></h2>
          <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fotters.example%2Fhands">Sea otters hold hands while they sleep.</a></div>
        <div class="result"><h2 class="result__title"><a class="result__a" href="https://www.worldwildlife.org/species/sea-otter">Otters | WWF</a></h2>
          <a class="result__snippet" href="https://www.worldwildlife.org/species/sea-otter">A keystone species.</a></div>
        """)
        try write("consent.html", "<!doctype html><title>Before you continue to Google</title><h1>Before you continue to Google</h1><button>Accept all</button>")
        try write("article.html", """
        <!doctype html><title>Otter facts</title><body><main id="main">Loading…</main>
        <script>setTimeout(() => { document.getElementById('main').innerHTML = '<h1>Otter facts</h1><p>Otters hold hands. The secret word is marmalade.</p>'; }, 150)</script>
        """)
        try write("recipe.html", "<!doctype html><title>Recipe</title><p>Spread the toast thickly with marmalade and serve.</p>")
        try write("asleep.html", "<!doctype html><title>Asleep</title><p>Woken up to be read.</p>")
        // A one-page PDF with a line of text.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Otters have the densest fur of any animal.", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
        context.textPosition = CGPoint(x: 72, y: 700); CTLineDraw(line, context)
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: folder.appendingPathComponent("otters.pdf"))
    }
}
