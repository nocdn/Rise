import Foundation

/// The prompts behind Summarise, Explain in Context and Ask, which AI options lets the user
/// rewrite. A saved prompt that matches the one Rise ships, or is empty, goes back to following it.
/// `{title}` and the like place the page's details in the prompt; without any, Rise adds them after.
enum AIPrompt: String, CaseIterable {
    case summarise, explain, ask

    var title: String {
        switch self {
        case .summarise: "Summarise Prompt"
        case .explain: "Explain in Context Prompt"
        case .ask: "Ask in Page Prompt"
        }
    }

    /// The `{name}`s each prompt can use.
    var placeholders: [String] {
        switch self {
        case .summarise: ["title", "address", "text"]
        case .explain: ["selection", "passage", "title", "address", "text"]
        case .ask: ["title", "address", "selection", "text"]
        }
    }

    /// Under the field: the placeholders, and what happens without them.
    var detail: String {
        let names = placeholders.map { "{\($0)}" }
        let list = names.dropLast().joined(separator: ", ")+" and "+names.last!
        switch self {
        case .summarise: return "Use \(list) for the page. Without them, Rise adds the page after the prompt."
        case .explain: return "Use \(list). Without them, Rise adds the page after the prompt."
        case .ask: return "Use \(list). Without them, Rise adds the page after. The answer format always follows."
        }
    }

    var defaultText: String {
        switch self {
        case .summarise: PageSummary.systemPrompt
        case .explain: SelectionExplanation.systemPrompt
        case .ask: PageAssistant.instructions
        }
    }

    private var key: String { "AIPrompt."+rawValue }

    /// The prompt in use: the user's, or the one Rise ships.
    var text: String { UserDefaults.standard.string(forKey: key) ?? defaultText }
    var isCustom: Bool { UserDefaults.standard.string(forKey: key) != nil }

    func save(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == defaultText { reset() }
        else { UserDefaults.standard.set(text, forKey: key) }
    }

    func reset() { UserDefaults.standard.removeObject(forKey: key) }

    /// The system prompt to send: the placeholders filled in, or with none, the prompt followed by
    /// `context`, as before placeholders.
    func system(context: String, values: [String: String]) -> String {
        Self.fill(text, values: values, known: placeholders) ?? text+"\n\n"+context
    }

    /// The prompt with its known placeholders filled in, or nil if it has none.
    static func fill(_ text: String, values: [String: String], known: [String]) -> String? {
        let found = PromptPlaceholder.scan(text, known: known).filter(\.isValid)
        guard !found.isEmpty else { return nil }
        let filled = NSMutableString(string: text)
        for placeholder in found.reversed() {
            filled.replaceCharacters(in: placeholder.range, with: values[placeholder.name] ?? "")
        }
        return filled as String
    }
}

/// A `{name}` in a prompt, or the beginnings of one, as Snap's file names check theirs: known
/// names are placeholders, and anything else in braces is malformed.
struct PromptPlaceholder: Equatable {
    let range: NSRange
    let name: String
    /// Why it's malformed, or nil for a placeholder Rise fills in.
    let problem: String?
    var isValid: Bool { problem == nil }

    static func scan(_ text: String, known: [String]) -> [PromptPlaceholder] {
        let string = text as NSString, open: unichar = 123, close: unichar = 125, newline: unichar = 10
        var found: [PromptPlaceholder] = [], index = 0
        while index < string.length {
            let character = string.character(at: index)
            if character == close {
                found.append(PromptPlaceholder(range: NSRange(location: index, length: 1), name: "", problem: "Remove the unmatched }."))
                index += 1
                continue
            }
            guard character == open else { index += 1; continue }
            // An unclosed brace runs to the end of its line, not the rest of the prompt.
            var end = index+1
            while end < string.length, ![open, close, newline].contains(string.character(at: end)) { end += 1 }
            if end < string.length, string.character(at: end) == close {
                let name = string.substring(with: NSRange(location: index+1, length: end-index-1))
                let problem: String? = name.isEmpty ? "Placeholder names can’t be empty."
                    : name.contains(where: \.isWhitespace) ? "Placeholders can’t contain spaces."
                    : known.contains(name) ? nil : "Unknown placeholder {\(name)}."
                found.append(PromptPlaceholder(range: NSRange(location: index, length: end-index+1), name: name, problem: problem))
                index = end+1
            } else {
                let nested = end < string.length && string.character(at: end) == open
                found.append(PromptPlaceholder(range: NSRange(location: index, length: end-index), name: "",
                    problem: nested ? "Close the placeholder before starting another one." : "Close the placeholder with }."))
                index = end
            }
        }
        return found
    }
}
