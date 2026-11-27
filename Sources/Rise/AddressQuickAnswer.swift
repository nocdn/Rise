import CoreServices
import Foundation

enum AddressQuickAnswer: Hashable, Sendable {
    case definition(String)
    case synonyms(String)
    case age(String)

    init?(_ query: String) {
        let text = query.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "?!"))
        let patterns: [(String, String, (String) -> Self)] = [
            ("define ", "", Self.definition), ("definition of ", "", Self.definition),
            ("meaning of ", "", Self.definition), ("", " meaning in english", Self.definition),
            ("", " meaning", Self.definition), ("", " definition", Self.definition),
            ("synonym for ", "", Self.synonyms), ("synonyms for ", "", Self.synonyms),
            ("synonym of ", "", Self.synonyms), ("synonyms of ", "", Self.synonyms),
            ("", " synonym", Self.synonyms), ("", " synonyms", Self.synonyms),
            ("how old is ", "", Self.age), ("", " age", Self.age)
        ]
        for (prefix, suffix, makeAnswer) in patterns {
            guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { continue }
            var subject = String(text.dropFirst(prefix.count).dropLast(suffix.count))
            if suffix == " age", subject.hasSuffix("'s") || subject.hasSuffix("’s") { subject.removeLast(2) }
            subject = subject.trimmingCharacters(in: .whitespaces)
            let answer = makeAnswer(subject)
            let wordLimit: Int
            if case .age = answer { wordLimit = 6 } else { wordLimit = 4 }
            let words = subject.split(separator: " ")
            guard !words.isEmpty, words.count <= wordLimit, subject.count <= 80,
                  subject.allSatisfy({ $0.isLetter || " -’'.".contains($0) }) else { return nil }
            self = answer
            return
        }
        return nil
    }

    static func definition(for term: String) -> String? {
        func lookup(_ word: String) -> String? {
            let text = word as CFString
            guard let raw = DCSCopyTextDefinition(nil, text, CFRange(location: 0, length: CFStringGetLength(text)))?.takeRetainedValue() else { return nil }
            return definitionText(raw as String, for: word)
        }
        if let found = lookup(term) { return found }
        // The Mac's dictionary is American: "colour" finds "unicolor", which is turned away, and
        // "color" is the word meant.
        guard !term.contains(" ") else { return nil }
        for (british, american) in [("our", "or"), ("ise", "ize"), ("yse", "yze"), ("tre", "ter")] {
            guard let range = term.range(of: british, options: .backwards) else { continue }
            if let found = lookup(term.replacingCharacters(in: range, with: american)) { return found }
        }
        return nil
    }

    /// Word classes, as entries name them: "noun", "modal verb", "possessive determiner".
    private static let wordClass = #"(?:(?:possessive|interrogative|relative|personal|reflexive|demonstrative|modal|auxiliary|phrasal|plural|proper|mass|cardinal|ordinal) )?(?:noun|verb|adjective|adverb|pronoun|preposition|conjunction|determiner|predeterminer|interjection|exclamation|article|abbreviation|symbol|prefix|suffix|combining form|contraction|number)(?=[ ,]|$)"#
    /// Labels on a sense rather than part of it: "informal exclamation", "noun British English".
    private static let label = #"(?:or )?(?:informal|formal|dated|archaic|literary|humorous|derogatory|offensive|vulgar slang|slang|non-standard|nonstandard|technical|historical|trademark|British English|US English|North American|(?:chiefly|mainly) (?:British English|North American|US))(?=[ ,])"#
    /// A subject a sense belongs to, after its class: "noun Biology an organelle…".
    private static let subject = #"[A-Z][a-z]+ (?=[a-z(])"#

    /// The first sense of a Dictionary Services entry, as plain text:
    /// "child | CHīld | noun (plural children | ˈCHildr(ə)n |) a young human being below the age of
    /// puberty…: she'd been playing…". The headword comes first, its pronunciation between bars,
    /// then its class, forms and labels, in brackets that can hold bars and brackets of their own,
    /// and then the sense, up to its examples. With `term`, an entry for another word, as
    /// "unicolor" for "colour", is turned away; one for the word's root, as "child" for
    /// "children", or that lists it among its forms, as "go" for "went", is kept.
    static func definitionText(_ entry: String, for term: String? = nil) -> String? {
        let text = entry.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // The pronunciation's bars, not those of a form's in brackets before it:
        // "mouse noun (plural mice | mīs |) | mous | 1 a small rodent…".
        var depth = 0, bars: [String.Index] = []
        for index in text.indices where bars.count < 2 {
            switch text[index] {
            case "(", "[": depth += 1
            case ")", "]": depth = max(0, depth-1)
            case "|" where depth == 0: bars.append(index)
            default: break
            }
        }
        guard bars.count == 2 else { return nil }
        let open = bars[0]
        var rest = text[text.index(after: bars[1])...], classified = false
        while true {
            rest = rest.drop { $0 == " " || $0 == "," }
            guard let first = rest.first else { return nil }
            if first == "(" || first == "[" {
                guard let end = closing(rest) else { return nil }
                rest = rest[end...]; continue
            }
            // A second pronunciation: "| həˈlō, heˈlō |".
            if first == "|", let end = rest.dropFirst().firstIndex(of: "|") {
                rest = rest[rest.index(after: end)...]; continue
            }
            if first.isNumber, let space = rest.firstIndex(of: " "), rest[..<space].allSatisfy(\.isNumber) {
                rest = rest[space...]; continue
            }
            if let match = rest.range(of: wordClass, options: [.regularExpression, .anchored]) {
                rest = rest[match.upperBound...]; classified = true; continue
            }
            if let match = rest.range(of: label, options: [.regularExpression, .anchored])
                ?? (classified ? rest.range(of: subject, options: [.regularExpression, .anchored]) : nil) {
                rest = rest[match.upperBound...]; continue
            }
            break
        }
        if let term = term?.lowercased(), !matches(term, head: String(text[..<open]), header: String(text[..<rest.startIndex])) { return nil }
        // The sense ends where its examples or the next sense begin, or at the end of its sentence.
        var sense = rest.prefix { !":•|".contains($0) }
        if let stop = sense.range(of: #"\. (?!\d)"#, options: .regularExpression),
           sense[..<stop.lowerBound].range(of: #"\b(?:e\.g|i\.e|etc|esp|U\.S|St|Mr|Mrs|Dr|vs)$"#, options: .regularExpression) == nil {
            sense = sense[..<stop.lowerBound]
        }
        let answer = sense.trimmingCharacters(in: CharacterSet(charactersIn: " ;,."))
        guard let initial = answer.first, initial.isLetter else { return nil }
        return initial.uppercased() + String(answer.dropFirst())
    }

    /// Past the bracket `text` starts with, counting the brackets inside it.
    private static func closing(_ text: Substring) -> Substring.Index? {
        var depth = 0
        for index in text.indices {
            switch text[index] {
            case "(", "[": depth += 1
            case ")", "]":
                depth -= 1
                if depth == 0 { return text.index(after: index) }
            default: break
            }
        }
        return nil
    }

    /// Whether an entry is for `term`: its headword, the word's root ("analyze" for "analyses"),
    /// or a word listing it among its forms ("go", whose past is "went").
    private static func matches(_ term: String, head: String, header: String) -> Bool {
        let head = head.replacingOccurrences(of: "·", with: "").lowercased()
        if head.contains(term) { return true }
        let headword = head.split(separator: " ").first.map(String.init) ?? ""
        let shared = zip(term, headword).prefix { $0 == $1 }.count
        if shared >= min(headword.count, max(3, headword.count-2)) { return true }
        // Among its forms, though not as a part of another word: "-colour".
        let escaped = NSRegularExpression.escapedPattern(for: term)
        return header.lowercased().range(of: #"(?<![\w-])"# + escaped + #"(?!\w)"#, options: .regularExpression) != nil
    }

    private struct Search: Decodable {
        struct Item: Decodable { let id: String; let label: String }
        let search: [Item]
    }

    static func age(of name: String) async throws -> String? {
        let data = try await wikidata(["action": "wbsearchentities", "search": name, "language": "en", "limit": "12"])
        let items = try JSONDecoder().decode(Search.self, from: data).search
        let ids = items.filter { $0.label.lowercased() == name }.map(\.id)
        guard !ids.isEmpty, !Task.isCancelled else { return nil }
        let details = try await wikidata(["action": "wbgetentities", "ids": ids.joined(separator: "|"),
                                          "props": "claims|sitelinks", "sitefilter": "enwiki"])
        return try ageAnswer(in: details)
    }

    private static let session = URLSession(configuration: .ephemeral)

    private static func wikidata(_ parameters: [String: String]) async throws -> Data {
        var url = URLComponents()
        url.scheme = "https"; url.host = "www.wikidata.org"; url.path = "/w/api.php"
        url.queryItems = parameters.merging(["format": "json", "maxlag": "5"]) { first, _ in first }
            .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let address = url.url else { throw URLError(.badURL) }
        var request = URLRequest(url: address, timeoutInterval: 3)
        request.setValue("Rise (https://github.com/nocdn/Rise) Address Quick Answers", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    static func ageAnswer(in data: Data, today: Date = .now) throws -> String? {
        typealias Object = [String: Any]
        guard let response = try JSONSerialization.jsonObject(with: data) as? Object,
              let entities = response["entities"] as? [String: Object] else { return nil }

        func statements(_ property: String, in claims: Object) -> [Object] {
            (claims[property] as? [Object] ?? []).filter { ($0["rank"] as? String) != "deprecated" }
        }
        func value(_ statement: Object) -> Object? {
            let snak = statement["mainsnak"] as? Object
            return (snak?["datavalue"] as? Object)?["value"] as? Object
        }
        let people = entities.values.compactMap { entity -> Object? in
            guard (entity["sitelinks"] as? Object)?["enwiki"] != nil, let claims = entity["claims"] as? Object,
                  statements("P31", in: claims).contains(where: { value($0)?["id"] as? String == "Q5" }) else { return nil }
            return claims
        }
        guard people.count == 1, let person = people.first, statements("P570", in: person).isEmpty else { return nil }
        let birthDates = statements("P569", in: person)
        let preferred = birthDates.filter { $0["rank"] as? String == "preferred" }
        let dates = preferred.isEmpty ? birthDates : preferred
        let times = dates.compactMap { statement -> String? in
            guard let date = value(statement), date["precision"] as? Int == 11,
                  (date["calendarmodel"] as? String)?.hasSuffix("/Q1985727") == true else { return nil }
            return date["time"] as? String
        }
        guard let time = times.first, times.count == dates.count, Set(times).count == 1,
              dates.contains(where: { ($0["references"] as? [Object])?.isEmpty == false }) else { return nil }
        return age(born: time, today: today).map { "\($0) years old" }
    }

    private static func age(born time: String, today: Date) -> Int? {
        guard time.range(of: #"^\+\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil else { return nil }
        let parts = time.dropFirst().prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let birthday = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: birthday), calendar.dateComponents([.year, .month, .day], from: date) == birthday,
              date <= today, let age = calendar.dateComponents([.year], from: date, to: today).year, (0...125).contains(age) else { return nil }
        return age
    }
}
