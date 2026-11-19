import Foundation
#if os(macOS)
import AppKit
#endif

/// Answers questions about the open page through the chosen AI provider, streamed token by token.
enum PageAssistant {
    struct Turn: Sendable { let question: String, answer: String }
    static let model = "openai/gpt-6-luna"
    static let reasoningEffort = "low"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// Roughly 30k tokens of page text; long pages are cut off at the end.
    static let pageCharacterLimit = 120_000
    /// How to answer, which the iOS app lets the user change; `answerFormat` always follows it.
    static let instructions = """
    You are the page assistant in Rise, a web browser. The user is reading a web page and asks a question about it in the browser's find bar. The page's text is below.

    Answer from the page. Be short and direct: usually one or two sentences, no preamble, and don't restate the question. Lead with the answer itself, such as the date, number, name or yes/no. If the page doesn't say, reply that it doesn't in one short sentence; only then add what you know, clearly marked as not from the page. Write plain sentences; use **bold** at most for the key fact, and no headings, tables or lists unless asked.
    """
    static var systemPrompt: String { instructions+"\n\n"+answerFormat }
    /// The snippet header that highlighting reads, so it isn't left to a custom prompt.
    static let answerFormat = """
    Output a single-line JSON object first, then a newline, then your answer as plain text with the light Markdown described above. The JSON object must contain exactly one field: "snippet", a string. When a specific passage on the page answers the question, put that passage in snippet, copied exactly and contiguously from the page, a sentence or two at most. Use an empty string when no passage supports the answer. JSON-escape quotes, backslashes and newlines inside the snippet so the header always occupies one line. Do not use code fences, labels, or any other text before the JSON header. Do not mention the snippet or highlighting in your answer.

    Example format (illustrative content, never evidence about the current page):
    {"snippet":"The public release is planned for March 3, 2027."}
    It is planned for **March 3, 2027**.
    """

    struct Page: Sendable {
        let title: String, url: String, selection: String, text: String
        /// Where the page's links go, so the model follows the page's own link to, say, its pricing
        /// rather than guessing the address.
        var links: [Link] = []
        struct Link: Sendable, Equatable { let text: String, url: String }
        /// The links as the model reads them, after the page's text; empty for none.
        var linksText: String {
            guard !links.isEmpty else { return "" }
            return "Links on the page (text: address):\n"+links.map { "- \($0.text): \($0.url)" }.joined(separator: "\n")
        }
    }
    /// The most links a page gives the model, and the most of each one's text.
    static let linkLimit = 150, linkTextLimit = 80
    /// Each web link once, by its text (or label) and its address without its fragment, skipping
    /// links to the page itself; hidden ones too, such as a menu's, whose text is still there.
    static let linksScript = #"""
    const out = [], seen = new Set([location.href.split('#')[0]]);
    for (const a of document.querySelectorAll('a[href]')) {
      let url; try { url = new URL(a.href, location.href); } catch { continue; }
      if (!/^https?:$/.test(url.protocol)) continue;
      url.hash = '';
      if (seen.has(url.href)) continue;
      const text = (a.innerText || a.textContent || a.getAttribute('aria-label') || a.title || '').replace(/\s+/g, ' ').trim().slice(0, limit);
      if (!text) continue;
      seen.add(url.href); out.push([text, url.href]);
      if (out.length >= count) break;
    }
    return JSON.stringify(out);
    """#
    @MainActor static func links(of webPage: any ScriptablePage) async -> [Page.Link] {
        guard let json = try? await webPage.runScript(linksScript, arguments: ["limit": linkTextLimit, "count": linkLimit], world: "Rise.ChatLinks") as? String,
              let pairs = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String]] else { return [] }
        return pairs.compactMap { $0.count == 2 ? Page.Link(text: $0[0], url: $0[1]) : nil }
    }

    enum Failure: LocalizedError {
        case service(String)
        var errorDescription: String? { if case .service(let message) = self { return message }; return nil }
    }

    /// The visible text of the page, plus whatever the user has selected on it.
    @MainActor static func snapshot(of webPage: any ScriptablePage) async throws -> Page {
        let source = await PageFind.visibleText(in: webPage)
        let script = "return [fallback && document.body ? document.body.innerText : '', String(window.getSelection() || '')]"
        let parts = try await webPage.runScript(script, arguments: ["fallback": source == nil], world: nil) as? [String] ?? []
        return Page(title: webPage.title ?? "", url: webPage.url?.absoluteString ?? "",
                    selection: parts.count > 1 ? parts[1] : "", text: String((source ?? parts.first ?? "").prefix(pageCharacterLimit)),
                    links: await links(of: webPage))
    }

    /// `fill` may place the page in the instructions itself, in which case it isn't added after.
    static func messages(question: String, history: [Turn], page: Page, instructions: String = instructions,
                         fill: (@Sendable (String, Page) -> String?)? = nil) -> [[String: Any]] {
        var context = "Title: \(page.title)\nURL: \(page.url)\n"
        if !page.selection.isEmpty { context += "Selected text: \(page.selection)\n" }
        context += "\n<page>\n\(page.text)\n</page>"
        let system = fill?(instructions, page).map { $0+"\n\n"+answerFormat } ?? instructions+"\n\n"+answerFormat+"\n\n"+context
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": "{\"snippet\":\"\"}\n"+turn.answer])
        }
        messages.append(["role": "user", "content": question])
        return messages
    }

    /// One request emits a snippet header followed by answer text. Highlight locally as soon
    /// as the header completes; no tool-result round trip is needed before the answer streams.
    @MainActor static func answer(_ question: String, history: [Turn],
                       page: @escaping @MainActor () async throws -> Page,
                       highlight: @escaping @MainActor (String) async -> Bool,
                       inputTokens: @escaping @MainActor (Int) -> Void = { _ in },
                       provider: ModelChoice = .openRouter,
                       instructions: String = instructions,
                       fill: (@Sendable (String, Page) -> String?)? = nil,
                       session: URLSession = .shared) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let messages = messages(question: question, history: history, page: try await page(), instructions: instructions, fill: fill)
                    try Task.checkCancellation()
                    try await streamAnswer(messages, provider: provider, session: session, highlight: highlight, inputTokens: inputTokens) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A caller with a page-wide conversation can reuse the same header parser and token stream.
    @MainActor static func streamAnswer(_ messages: [[String: Any]], provider: ModelChoice, session: URLSession,
                                     highlight: @escaping @MainActor (String) async -> Bool,
                                     inputTokens: @escaping @MainActor (Int) -> Void,
                                     yield: (String) -> Void) async throws {
        var decoder = PageAnswerStream(), responded = false
        // Content tokens may split anywhere inside the JSON header or its escaped strings.
        try await ModelService.run(messages, provider: provider, session: session) { event in
            try Task.checkCancellation()
            switch event {
            case .inputTokens(let count):
                inputTokens(count)
            case .responded:
                if !responded { responded = true; yield("") } // End Thinking on first output, before the snippet is complete.
            case .text(let content):
                if !responded { responded = true; yield("") }
                let output = try decoder.append(content)
                try Task.checkCancellation()
                if let snippet = output.snippet, !snippet.isEmpty { _ = await highlight(snippet) }
                try Task.checkCancellation()
                if !output.text.isEmpty { yield(output.text) }
            }
        }
        try Task.checkCancellation()
        let output = try decoder.finish()
        if let snippet = output.snippet, !snippet.isEmpty { _ = await highlight(snippet) }
        try Task.checkCancellation()
        if !output.text.isEmpty { yield(output.text) }
    }
}

#if os(macOS)
@MainActor extension BrowserController {
    /// Answers about the page in the bar's own tab.
    func configurePageAssistant(_ bar: FindBar, for tab: BrowserTab) {
        bar.answer = { [weak tab, weak bar] question, history in
            let webView = tab?.page
            let generation = bar?.answerGeneration
            return PageAssistant.answer(question, history: history, page: {
                guard let webView else { throw PageAssistant.Failure.service("There’s no page to ask about.") }
                // Clear before generation starts so it cannot race a fast new snippet.
                await PageFind.clearPassage(webView)
                try Task.checkCancellation()
                return try await PageAssistant.snapshot(of: webView)
            }, highlight: { quote in
                guard !Task.isCancelled, let webView else { return false }
                return await PageFind.highlightPassage(quote, in: webView)
            }, inputTokens: { [weak bar] count in
                guard let generation else { return }
                bar?.recordInputTokens(count, for: generation)
            }, provider: self.modelChoice)
        }
        bar.provider = { [weak self] in self?.modelChoice ?? .openRouter }
    }

    /// OpenRouter unless another is picked in rise://settings.
    var aiProvider: AIProvider { AIProvider(rawValue: preferences.string(forKey: AIProvider.preferenceKey) ?? "") ?? .openRouter }
    func selectAIProvider(_ provider: AIProvider) {
        preferences.set(provider.rawValue, forKey: AIProvider.preferenceKey)
    }
    func makeAIProviderMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "AI Provider", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "AI Provider")
        for provider in AIProvider.allCases {
            submenu.addItem(menuItem(provider.title, checked: aiProvider == provider) { [weak self] in
                self?.selectAIProvider(provider)
            })
        }
        item.submenu = submenu
        return item
    }
}
#endif
