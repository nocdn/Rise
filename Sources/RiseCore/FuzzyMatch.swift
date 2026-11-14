import Foundation

/// How well a few typed letters pick out a name, as a menu narrows while it's typed into: each
/// word of what's typed must be in the name, whole or as letters in order. Whole, at the name's
/// start or a word's, counts most; letters scattered through it, least.
public enum FuzzyMatch {
    /// The score of `query` in `text`, higher for a better match, or nil if it isn't one.
    /// An empty query matches anything, at 0.
    public static func score(_ query: String, in text: String) -> Int? {
        let words = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        let name = fold(text)
        var total = 0
        for word in words {
            guard let score = score(word: word, in: name) else { return nil }
            total += score
        }
        return total
    }

    /// Lowercase and without accents, so "ico" finds "Icônes".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
    private static func startsWord(_ index: String.Index, in text: String) -> Bool {
        index == text.startIndex || !(text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber)
    }
    private static func score(word: String, in text: String) -> Int? {
        // Whole: best at the start, then at a word's start, then anywhere.
        var best: Int?
        var from = text.startIndex
        while let range = text.range(of: word, range: from..<text.endIndex) {
            let start = range.lowerBound
            let score = 100+word.count*4+(start == text.startIndex ? 60 : startsWord(start, in: text) ? 40 : 0)
            best = max(best ?? 0, score)
            from = text.index(after: start)
        }
        if let best { return best }
        // As letters in order, each a little better at a word's start or right after the last.
        var score = 0, index = text.startIndex
        var last: String.Index?
        for letter in word {
            guard let found = text[index...].firstIndex(of: letter) else { return nil }
            score += 1+(startsWord(found, in: text) ? 6 : 0)+(last.map { text.index(after: $0) == found } == true ? 4 : 0)
            last = found; index = text.index(after: found)
        }
        return score
    }

    /// `items` that match `query`, best first, in their own order where they match as well.
    public static func ranked<Item>(_ items: [Item], query: String, names: (Item) -> [String]) -> [Item] {
        let scored = items.enumerated().compactMap { offset, item -> (Int, Int, Item)? in
            // Its first name (a title) counts for more than the others (an address).
            let scores = names(item).enumerated().compactMap { index, name in score(query, in: name).map { $0-index*10 } }
            guard let score = scores.max() else { return nil }
            return (score, offset, item)
        }
        return scored.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }.map(\.2)
    }
}
