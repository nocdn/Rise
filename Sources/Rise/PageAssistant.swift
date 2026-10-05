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

    When a specific sentence or phrase on the page answers the question, call highlight_on_page once, before answering, with that passage copied exactly from the page text: contiguous, verbatim, a sentence or two at most. The browser highlights it and scrolls to it. Skip the tool when no single passage answers the question, and don't mention the highlight in your answer.
    """
    static let highlightTool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "highlight_on_page",
            "description": "Highlight the passage of the page that answers the user's question and scroll it into view, using the browser's find highlighting.",
            "parameters": [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "The passage, copied verbatim and contiguous from the page text; a sentence or two at most."]],
                "required": ["text"], "additionalProperties": false
            ] as [String: Any]
        ] as [String: Any]
    ]
    /// Tool rounds before the model has to answer in text.
    static let maxToolRounds = 2

    struct Page { let title: String, url: String, selection: String, text: String }

    enum Failure: LocalizedError {
        case service(String)
        var errorDescription: String? { if case .service(let message) = self { return message }; return nil }
    }

    /// The visible text of the page, plus whatever the user has selected on it.
    @MainActor static func snapshot(of webView: WKWebView) async throws -> Page {
        let script = "return [document.body ? document.body.innerText : '', String(window.getSelection() || '')]"
        let parts = try await webView.callAsyncJavaScript(script, contentWorld: .defaultClient) as? [String] ?? []
        return Page(title: webView.title ?? "", url: webView.url?.absoluteString ?? "",
                    selection: parts.count > 1 ? parts[1] : "", text: String((parts.first ?? "").prefix(pageCharacterLimit)))
    }

    static func messages(question: String, history: [FindBar.Turn], page: Page) -> [[String: Any]] {
        var context = "Title: \(page.title)\nURL: \(page.url)\n"
        if !page.selection.isEmpty { context += "Selected text: \(page.selection)\n" }
        context += "\n<page>\n\(page.text)\n</page>"
        var messages: [[String: Any]] = [["role": "system", "content": systemPrompt+"\n\n"+context]]
        for turn in history {
            messages.append(["role": "user", "content": turn.question])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": question])
        return messages
    }

    struct ToolCall { var id = "", name = "", arguments = "" }

    /// Streams the answer's text as it arrives. A `highlight_on_page` call ends the model's
    /// turn, so the passage is highlighted right away and the result sent back for the
    /// written answer. Cancelling the consumer cancels the request.
    static func answer(_ question: String, history: [FindBar.Turn],
                       page: @escaping @MainActor () async throws -> Page,
                       highlight: @escaping @MainActor (String) async -> Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages = messages(question: question, history: history, page: try await page())
                    for round in 0...maxToolRounds {
                        try Task.checkCancellation()
                        var body: [String: Any] = ["model": model, "stream": true, "reasoning": ["effort": reasoningEffort],
                                                   "messages": messages, "tools": [highlightTool]]
                        if round == maxToolRounds { body["tool_choice"] = "none" }
                        let (text, calls) = try await streamRound(body) { continuation.yield($0) }
                        if calls.isEmpty { break }
                        messages.append(["role": "assistant", "content": text.isEmpty ? NSNull() : text, "tool_calls": calls.map {
                            ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any]
                        }])
                        for call in calls {
                            try Task.checkCancellation()
                            let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                            let quote = arguments?["text"] as? String ?? ""
                            let found = call.name == "highlight_on_page" && !quote.isEmpty ? await highlight(quote) : false
                            messages.append(["role": "tool", "tool_call_id": call.id, "content": found
                                ? "Highlighted on the page. Now answer the question."
                                : "That exact text isn't on the page, so nothing was highlighted. Answer without it, or retry once with text copied verbatim."])
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One streamed completion: yields its text and collects any tool calls it makes.
    private static func streamRound(_ body: [String: Any], yield: (String) -> Void) async throws -> (String, [ToolCall]) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Rise", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Failure.service(errorMessage(in: data) ?? "The model couldn’t answer (HTTP \(http.statusCode)).")
        }
        var text = "", calls: [Int: ToolCall] = [:]
        // Server-sent events: `data: {chunk}` lines, with `: comment` keep-alives in between.
        // Tool calls arrive as fragments keyed by index: the id and name first, then the arguments.
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            let data = Data(payload.utf8)
            if let message = errorMessage(in: data) { throw Failure.service(message) }
            let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let delta = (chunk?["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any] else { continue }
            if let content = delta["content"] as? String, !content.isEmpty { text += content; yield(content) }
            // Signal non-text output too, so Thinking ends on a tool call or reasoning fragment.
            if (calls.isEmpty && !(delta["tool_calls"] as? [[String: Any]] ?? []).isEmpty)
                || !(delta["reasoning"] as? String ?? "").isEmpty
                || !(delta["reasoning_details"] as? [[String: Any]] ?? []).isEmpty { yield("") }
            for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = fragment["index"] as? Int ?? 0
                var call = calls[index] ?? ToolCall()
                if let id = fragment["id"] as? String { call.id = id }
                let function = fragment["function"] as? [String: Any]
                if let name = function?["name"] as? String { call.name += name }
                if let arguments = function?["arguments"] as? String { call.arguments += arguments }
                calls[index] = call
            }
        }
        return (text, calls.sorted { $0.key < $1.key }.map(\.value))
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
            // A new question replaces the last answer's highlight.
            if let webView { Task { await PageFind.clearPassage(webView) } }
            return PageAssistant.answer(question, history: history, page: {
                guard let webView else { throw PageAssistant.Failure.service("There’s no page to ask about.") }
                return try await PageAssistant.snapshot(of: webView)
            }, highlight: { quote in
                guard let webView else { return false }
                return await PageFind.highlightPassage(quote, in: webView)
            })
        }
    }
}
