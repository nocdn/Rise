import AppKit

/// Summaries of the pages links lead to, for the card an Option-hover opens over any link. Each
/// page is read in a page kept offscreen, with the person's sessions, and described by the find
/// bar's model in one paragraph. Kept for the launch; one that failed is tried again next time.
@MainActor final class LinkSummaries {
    struct Entry {
        var summary = ""
        var phase = PullRequestSummaries.Phase.idle
        var inputTokens: Int?
        /// It couldn't be written; the card says so, and it's tried again the next time it's asked for.
        var failed = false
    }
    private(set) var entries: [String: Entry] = [:]
    var onChange: ((String) -> Void)?
    /// Which service writes summaries.
    var provider: () -> ModelChoice = { .openRouter }
    /// Where the offscreen page lives: a window keeps it running.
    weak var host: NSView?
    private var page: WebPage?
    /// One page is read at a time; asking for another stops it.
    private var reading: (key: String, task: Task<Void, Never>)?
    private var writing: [String: Task<Void, Never>] = [:]
    private var idle: Task<Void, Never>?
    static let failure = "Couldn’t read that page."
    /// How long a page has to load before what it has so far is read anyway.
    static let loadLimit: TimeInterval = 12

    /// The page's address without its fragment, which doesn't change what's read.
    nonisolated static func key(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false); parts?.fragment = nil
        return "link:" + (parts?.url ?? url).absoluteString
    }
    /// Only web pages, not a mail address or a script.
    nonisolated static func summarizes(_ url: URL?) -> Bool { ["http", "https"].contains(url?.scheme?.lowercased() ?? "") }
    func entry(for url: URL) -> Entry { entries[Self.key(url)] ?? Entry() }

    /// Reads the page and writes its summary, unless there's one, or one on the way.
    func load(_ url: URL) {
        let key = Self.key(url)
        if let entry = entries[key], !entry.failed { return }
        if let reading, reading.key != key {
            // Its page wasn't read: it's asked for again next time.
            reading.task.cancel(); entries[reading.key] = nil
        }
        update(key) { $0 = Entry(phase: .generating) }
        idle?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            let page = await self.read(url)
            guard !Task.isCancelled else { return }
            self.reading = nil; self.scheduleTearDown()
            guard let page, !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { self.fail(key); return }
            self.write(key, page: page)
        }
        reading = (key, task)
    }
    /// Reads the page again and writes a new summary.
    func regenerate(_ url: URL) {
        let key = Self.key(url)
        guard writing[key] == nil, reading?.key != key else { return }
        entries[key] = nil
        load(url)
    }
    private func write(_ key: String, page: PageAssistant.Page) {
        writing[key] = Task { [weak self] in
            var text = ""
            do {
                let counted: @MainActor (Int) -> Void = { [weak self] count in self?.update(key) { $0.inputTokens = count } }
                for try await chunk in PullRequestSummarizer.summarize(LinkSummarizer.messages(page), provider: self?.provider() ?? .openRouter, inputTokens: counted) {
                    text += chunk
                    self?.update(key) { $0.summary = text }
                }
                let summary = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !summary.isEmpty else { throw URLError(.zeroByteResource) }
                self?.update(key) { $0.summary = summary; $0.phase = .done }
            } catch {
                if text.isEmpty { self?.fail(key) } else { self?.update(key) { $0.phase = .done } }
            }
            self?.writing[key] = nil
        }
    }
    private func fail(_ key: String) {
        update(key) { $0.summary = Self.failure; $0.phase = .done; $0.failed = true }
    }
    private func update(_ key: String, _ change: (inout Entry) -> Void) {
        var entry = entries[key] ?? Entry(); change(&entry); entries[key] = entry
        onChange?(key)
    }

    // MARK: Reading the page

    /// The page's text, once it has loaded (or the limit passed), with a moment for its scripts
    /// to draw what they fetch.
    private func read(_ url: URL) async -> PageAssistant.Page? {
        guard let page = hiddenPage() else { return nil }
        let before = page.url
        page.load(url)
        var started = false
        let deadline = Date().addingTimeInterval(Self.loadLimit)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return nil }
            if page.isLoading || page.url != before { started = true }
            if started, !page.isLoading { break }
        }
        guard started else { return nil }
        try? await Task.sleep(for: .milliseconds(500))
        if Task.isCancelled { return nil }
        let snapshot = try? await PageAssistant.snapshot(of: page)
        // Nothing keeps playing or running out of sight.
        page.load(URL(string: "about:blank")!)
        return snapshot
    }
    private func hiddenPage() -> WebPage? {
        let page = self.page ?? {
            let web = BrowserTab.makePage()
            // Desktop-sized, so pages lay out as they would in a tab.
            let container = HiddenAccessibilityView(frame: NSRect(x: -20000, y: 0, width: 1280, height: 900))
            web.view.frame = container.bounds; container.addSubview(web.view)
            host?.addSubview(container, positioned: .below, relativeTo: host?.subviews.first)
            self.page = web
            return web
        }()
        return page is ChromiumPage ? page : nil
    }
    private func scheduleTearDown() {
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, self?.reading == nil else { return }
            self?.tearDown()
        }
    }
    func tearDown() {
        idle?.cancel(); idle = nil
        reading?.task.cancel(); reading = nil
        page?.view.superview?.removeFromSuperview()
        (page as? ChromiumPage)?.browserView.close()
        page = nil
    }
}

/// The paragraph in a link's summary card, from the find bar's model.
enum LinkSummarizer {
    static let systemPrompt = """
    You write the summary in a browser's hover card for a link the user is pointing at, from the text of the page the link leads to.

    Write one paragraph, usually two to four sentences and at most 90 words, saying what the page is and what it says. Keep the details that matter: names, numbers, dates, prices, versions, results and conclusions. Start directly with the substance. Never start with "This page", "The page", "This article" or "This link", and don't mention the link, its address or that this is a summary. Write plain text only: no Markdown, quotes, lists or line breaks.

    If the text is only a sign-in page, an error, a cookie notice or otherwise has nothing to summarise, say what it is in one short sentence.
    """
    static func messages(_ page: PageAssistant.Page) -> [[String: Any]] {
        let context = "Title: \(page.title)\nURL: \(page.url)\n\n<page>\n\(page.text.prefix(40_000))\n</page>"
        return [["role": "system", "content": systemPrompt], ["role": "user", "content": context]]
    }
}
