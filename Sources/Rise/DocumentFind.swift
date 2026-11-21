import Foundation
import RiseChromium

/// Chromium's own find, for a PDF it draws itself, where Rise's in-page finder sees no text. One
/// search at a time per page, as the engine keeps only one; the model's passage is one too.
@MainActor final class DocumentFinder {
    private(set) var query = ""
    private(set) var matches: PageFind.Matches?
    /// Whether the model's passage holds the find, rather than a search.
    private(set) var showsPassage = false
    private var waiting: CheckedContinuation<PageFind.Matches, Never>?
    private var later: ((PageFind.Matches) -> Void)?
    private var generation = 0
    /// How long a search may take before it answers with what it has, the rest following later.
    static let patience: Duration = .milliseconds(1500)

    var isActive: Bool { !query.isEmpty }

    func find(_ query: String, direction: PageFind.Direction, in view: RCBrowserView,
              later: ((PageFind.Matches) -> Void)? = nil) async -> PageFind.Matches {
        guard !query.isEmpty else { stop(selectingMatch: false, in: view); return PageFind.Matches(count: 0, index: -1) }
        if direction == .refresh, query == self.query, !showsPassage, let matches { return matches }
        let same = query == self.query
        // The engine steps through the same text and starts over for new text, so starting over on
        // the same text, as a reloaded page or a reopened bar does, takes ending the search first.
        if same && (direction == .restart || direction == .refresh || showsPassage) { view.stopFinding(selectingMatch: false) }
        if !same || direction == .restart || direction == .refresh || showsPassage { matches = nil }
        answer()
        self.query = query; showsPassage = false; self.later = later
        generation += 1
        let generation = generation
        let forward = direction != .previous && direction != .skipPrevious
        return await withCheckedContinuation { continuation in
            waiting = continuation
            view.find(query, forward: forward) { [weak self] count, active, final in
                guard let self, self.generation == generation else { return }
                // An early update may count matches before choosing one; the first is chosen next.
                let matches = PageFind.Matches(count: count, index: count == 0 ? -1 : max(active, 1)-1)
                self.matches = matches
                if self.waiting == nil { self.later?(matches) }
                // A partial count of none may yet find some further on.
                else if final || (count > 0 && active > 0) { self.answer() }
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.patience)
                guard let self, self.generation == generation else { return }
                self.answer()
            }
        }
    }

    /// Finds the model's quote and shows it as the current match. A quote across a line break or a
    /// page, or with a word the PDF hyphenated, may not match whole, so its opening words stand in.
    func highlight(_ quote: String, in view: RCBrowserView) async -> Bool {
        let words = Self.passageWords(quote)
        guard !words.isEmpty else { return false }
        var tries = [words.prefix(40).joined(separator: " ")]
        for count in [12, 6, 3] where words.count > count { tries.append(words.prefix(count).joined(separator: " ")) }
        for text in tries {
            if (await find(text, direction: .restart, in: view).count ?? 0) > 0 { showsPassage = true; return true }
        }
        stop(selectingMatch: false, in: view)
        return false
    }
    /// The quote's words, without a page marker it took from the text the model read.
    nonisolated static func passageWords(_ quote: String) -> [String] {
        let unmarked = quote.replacingOccurrences(of: #"\[Page \d+ of \d+\]"#, with: " ", options: .regularExpression)
        return unmarked.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    func stop(selectingMatch select: Bool, in view: RCBrowserView) {
        guard isActive || waiting != nil else { return }
        generation += 1
        answer()
        query = ""; matches = nil; showsPassage = false; later = nil
        view.stopFinding(selectingMatch: select)
    }
    func stopPassage(in view: RCBrowserView) {
        if showsPassage { stop(selectingMatch: false, in: view) }
    }

    private func answer() {
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(returning: matches ?? PageFind.Matches(count: nil, index: -1))
    }

    /// The PDF's pages as the model reads them, each under its number, with the line breaks
    /// PDFium gives as `\r\n` made plain and its control characters left out.
    nonisolated static func documentText(_ pages: [String]) -> String {
        pages.enumerated().map { index, text in
            let plain = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            let shown = String(String.UnicodeScalarView(plain.unicodeScalars.filter {
                $0 == "\n" || $0 == "\t" || !CharacterSet.controlCharacters.contains($0)
            })).trimmingCharacters(in: .whitespacesAndNewlines)
            return "[Page \(index+1) of \(pages.count)]\n\(shown)"
        }.joined(separator: "\n\n")
    }
}

/// Answers a callback's continuation once: with its value, or, if it doesn't come in time, nil.
@MainActor private final class TimedReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    init(_ continuation: CheckedContinuation<Value?, Never>) { self.continuation = continuation }
    func send(_ value: Value?) { continuation?.resume(returning: value); continuation = nil }
}

@MainActor extension ChromiumPage: DocumentPage {
    var showsDocument: Bool { browserView.showsPDF }
    /// A PDF opened a moment ago may not have loaded: a search waits for it, as typing does.
    func findInDocument(_ query: String, direction: PageFind.Direction, later: ((PageFind.Matches) -> Void)?) async -> PageFind.Matches {
        if !query.isEmpty, !(await documentLoaded(within: .seconds(10))) { return PageFind.Matches(count: nil, index: -1) }
        return await documentFinder.find(query, direction: direction, in: browserView, later: later)
    }
    func highlightInDocument(_ quote: String) async -> Bool {
        guard await documentLoaded(within: .seconds(10)) else { return false }
        return await documentFinder.highlight(quote, in: browserView)
    }
    func clearDocumentFind(selectingCurrent: Bool) { documentFinder.stop(selectingMatch: selectingCurrent, in: browserView) }
    func clearDocumentPassage() { documentFinder.stopPassage(in: browserView) }
    /// Waits for the PDF to load, as long as a large one takes, but not forever.
    func documentText() async -> String? {
        guard await documentLoaded(within: .seconds(20)) else { return nil }
        let view = browserView
        let pages: [String]? = await withCheckedContinuation { continuation in
            let reply = TimedReply<[String]>(continuation)
            view.pdfPageTexts { reply.send($0) }
            Task { try? await Task.sleep(for: .seconds(20)); reply.send(nil) }
        }
        return pages.map(DocumentFinder.documentText)
    }
    var documentSelection: String { browserView.pdfSelectedText }

    /// Whether the PDF has loaded, waiting up to `limit` for it: until its viewer starts there's
    /// nothing to wait on, so it asks again.
    func documentLoaded(within limit: Duration) async -> Bool {
        let view = browserView, deadline = ContinuousClock.now+limit
        while view.showsPDF {
            let loaded: Bool? = await withCheckedContinuation { continuation in
                let reply = TimedReply<Bool>(continuation)
                view.whenPDFLoaded { reply.send($0) }
                Task { try? await Task.sleep(until: deadline); reply.send(nil) }
            }
            if loaded == true { return true }
            if loaded == nil || ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }
}
