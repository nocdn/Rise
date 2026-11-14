import AppKit

/// A page attached to a question: the tab it came from, and what's shown on its chip.
struct AIChatAttachment: Equatable {
    let tabID: UUID?
    var title: String
    var url: URL?
    var favicon: NSImage?
    /// The host Dia shows under the title: `icones.js.org`.
    var subtitle: String {
        guard let url else { return "" }
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
    /// The same page, whatever its chip shows.
    func isSamePage(as other: AIChatAttachment) -> Bool { url != nil && url == other.url }
}

/// A piece of a question: words, or a page mentioned with @, in the order they were written.
enum AIChatQuestionPart: Equatable {
    case text(String)
    case mention(AIChatAttachment)
    /// What a mention shows: the page's title, or its host without one.
    static func title(of page: AIChatAttachment) -> String { page.title.isEmpty ? page.subtitle : page.title }
    /// How the model reads a mention, matching its <page>: `@[Title](https://…)`.
    static func reference(to page: AIChatAttachment) -> String {
        let title = title(of: page).replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        return page.url.map { "@[\(title)](\($0.absoluteString))" } ?? "@[\(title)]"
    }
}

/// One question and its answer, with the pages it was asked about as they read when it was sent.
struct AIChatTurn {
    let id = UUID()
    /// What was asked, its mentions of pages where they were written.
    var parts: [AIChatQuestionPart]
    var pages: [AIChatAttachment]
    var snapshots: [PageAssistant.Page] = []
    var answer = ""
    var failed = false
    init(question: String, pages: [AIChatAttachment]) { self.init(parts: [.text(question)], pages: pages) }
    init(parts: [AIChatQuestionPart], pages: [AIChatAttachment]) { self.parts = parts; self.pages = pages }
    /// The question as it reads, each mention by its page's title.
    var question: String {
        parts.map { part in
            switch part { case .text(let text): text; case .mention(let page): AIChatQuestionPart.title(of: page) }
        }.joined()
    }
    /// The question as the model reads it, each mention a reference to its page.
    var prompt: String {
        parts.map { part in
            switch part { case .text(let text): text; case .mention(let page): AIChatQuestionPart.reference(to: page) }
        }.joined()
    }
    /// The pages mentioned, in the order they were, each once.
    var mentions: [AIChatAttachment] {
        var seen: [AIChatAttachment] = []
        for case .mention(let page) in parts where !seen.contains(where: { $0.isSamePage(as: page) || $0 == page }) { seen.append(page) }
        return seen
    }
}

/// What the chat sends: its instructions, then each exchange, with each question's pages in
/// front of it. Earlier pages stay in the conversation, so a follow-up can still use them.
enum AIChatPrompt {
    static let instructions = """
    You are the assistant in Rise, a web browser, answering in a chat panel beside the page the user is reading. The user can attach web pages to a question; each arrives before it in a <page> element with its title, URL, any text they have selected on it, and the page's visible text. Where the question mentions an attached page, it's written @[title](URL), matching that page's <page> element, so a question can refer to its pages in the order the user wrote them: "compare @[A](…) with @[B](…)".

    When a question is about an attached page, answer from that page, and say so plainly when it doesn't cover something before adding what you know. Otherwise answer from your own knowledge. Lead with the answer itself, without preamble or restating the question. Keep it as short as the question allows: a sentence or a short paragraph for simple questions, a few short paragraphs or a list for bigger ones. Use Markdown only where it helps: **bold** for the key facts, lists for steps or several items, `code` for code, and headings only in long answers.
    """

    static func context(_ pages: [PageAssistant.Page]) -> String {
        pages.map { page in
            var header = "<page>\nTitle: \(page.title)\nURL: \(page.url)\n"
            if !page.selection.isEmpty { header += "Selected text: \(page.selection)\n" }
            return header+"\n\(page.text)\n</page>"
        }.joined(separator: "\n\n")
    }
    /// The question as the model reads it, after the pages it was asked about.
    static func content(_ turn: AIChatTurn) -> String {
        turn.snapshots.isEmpty ? turn.prompt : context(turn.snapshots)+"\n\n"+turn.prompt
    }
    static func messages(history: [AIChatTurn], current: AIChatTurn, instructions: String = instructions) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "system", "content": instructions]]
        for turn in history where !turn.failed && !turn.answer.isEmpty {
            messages.append(["role": "user", "content": content(turn)])
            messages.append(["role": "assistant", "content": turn.answer])
        }
        messages.append(["role": "user", "content": content(current)])
        return messages
    }
    /// "Thought for 3 seconds", as Dia words it, never less than a second.
    static func thought(_ seconds: TimeInterval) -> String {
        let whole = max(1, Int(seconds.rounded()))
        return "Thought for \(whole) second\(whole == 1 ? "" : "s")"
    }
}
