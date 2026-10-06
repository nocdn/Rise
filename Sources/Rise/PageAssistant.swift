import Foundation
import WebKit

/// Answers questions about the open page through OpenRouter, streamed token by token.
enum PageAssistant {
    // Temporary test key, hardcoded on purpose until it is rotated and moved to settings.
    static let apiKey = "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"
    static let model = "openai/gpt-6-luna"
    static let reasoningEffort = "low"
    static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// Roughly 30k tokens of page text; long pages are cut off at the end.
    static let pageCharacterLimit = 120_000
    static let systemPrompt = """
    You are the page assistant in Rise, a web browser. The user is reading a web page and asks a question about it in the browser's find bar. The page's text is below.

    Answer from the page. Be short and direct: usually one or two sentences, no preamble, and don't restate the question. Lead with the answer itself, such as the date, number, name or yes/no. If the page doesn't say, reply that it doesn't in one short sentence; only then add what you know, clearly marked as not from the page. Write plain sentences; use **bold** at most for the key fact, and no headings, tables or lists unless asked.

    Output a single-line JSON object first, then a newline, then your answer as plain text with the light Markdown described above. The JSON object must contain exactly one field: "snippet", a string. When a specific passage on the page answers the question, put that passage in snippet, copied exactly and contiguously from the page, a sentence or two at most. Use an empty string when no passage supports the answer. JSON-escape quotes, backslashes and newlines inside the snippet so the header always occupies one line. Do not use code fences, labels, or any other text before the JSON header. Do not mention the snippet or highlighting in your answer.

    Example format (illustrative content, never evidence about the current page):
    {"snippet":"The public release is planned for March 3, 2027."}
    It is planned for **March 3, 2027**.
    """

    struct Page { let title: String, url: String, selection: String, text: String }

    enum Failure: LocalizedError {
        case service(String)
        var errorDescription: String? { if case .service(let message) = self { return message }; return nil }
    }

    /// The visible text of the page, plus whatever the user has selected on it.
    @MainActor static func snapshot(of webView: WKWebView) async throws -> Page {
        let source = await PageFind.visibleText(in: webView)
        let script = "return [fallback && document.body ? document.body.innerText : '', String(window.getSelection() || '')]"
        let parts = try await webView.callAsyncJavaScript(script, arguments: ["fallback": source == nil], contentWorld: .defaultClient) as? [String] ?? []
        return Page(title: webView.title ?? "", url: webView.url?.absoluteString ?? "",
                    selection: parts.count > 1 ? parts[1] : "", text: String((source ?? parts.first ?? "").prefix(pageCharacterLimit)))
    }

    static func messages(question: String, history: [FindBar.Turn], page: Page) -> [[String: Any]] {
        var context = "Title: \(page.title)\nURL: \(page.url)\n"
        if !page.selection.isEmpty { context += "Selected text: \(page.selection)\n" }
        context += "\n<page>\n\(page.text)\n</page>"
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt+"\n\n"+context]]
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": "{\"snippet\":\"\"}\n"+turn.answer])
        }
        messages.append(["role": "user", "content": question])
        return messages
    }

    /// One request emits a snippet header followed by answer text. Highlight locally as soon
    /// as the header completes; no tool-result round trip is needed before the answer streams.
    static func answer(_ question: String, history: [FindBar.Turn],
                       page: @escaping @MainActor () async throws -> Page,
                       highlight: @escaping @MainActor (String) async -> Bool,
                       session: URLSession = .shared) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let messages = messages(question: question, history: history, page: try await page())
                    try Task.checkCancellation()
                    let body: [String: Any] = ["model": model, "stream": true,
                                              "reasoning": ["effort": reasoningEffort], "messages": messages]
                    try await streamAnswer(body, session: session, highlight: highlight) { continuation.yield($0) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func streamAnswer(_ body: [String: Any], session: URLSession,
                                     highlight: @escaping @MainActor (String) async -> Bool,
                                     yield: (String) -> Void) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Rise", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Failure.service(errorMessage(in: data) ?? "The model couldn’t answer (HTTP \(http.statusCode)).")
        }
        var decoder = PageAnswerStream(), responded = false
        // SSE content tokens may split anywhere inside the JSON header or its escaped strings.
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            let data = Data(payload.utf8)
            if let message = errorMessage(in: data) { throw Failure.service(message) }
            let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let delta = (chunk?["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            let content = delta["content"] as? String ?? ""
            if !responded && (!content.isEmpty || !(delta["reasoning"] as? String ?? "").isEmpty
                || !(delta["reasoning_details"] as? [[String: Any]] ?? []).isEmpty) {
                responded = true; yield("") // End Thinking on first output, before the snippet is complete.
            }
            if !content.isEmpty {
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

    private static func errorMessage(in data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (object?["error"] as? [String: Any])?["message"] as? String
    }
}

@MainActor extension BrowserController {
    /// Answers about the page in the bar's own tab.
    func configurePageAssistant(_ bar: FindBar, for tab: BrowserTab) {
        bar.answer = { [weak tab] question, history in
            let webView = tab?.webView
            return PageAssistant.answer(question, history: history, page: {
                guard let webView else { throw PageAssistant.Failure.service("There’s no page to ask about.") }
                // Clear before generation starts so it cannot race a fast new snippet.
                await PageFind.clearPassage(webView)
                try Task.checkCancellation()
                return try await PageAssistant.snapshot(of: webView)
            }, highlight: { quote in
                guard !Task.isCancelled, let webView else { return false }
                return await PageFind.highlightPassage(quote, in: webView)
            })
        }
    }
}
