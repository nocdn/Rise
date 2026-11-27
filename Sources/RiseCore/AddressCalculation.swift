import Foundation

/// Explicit, offline answers for the address palette: dates, clock times and zones, durations, money,
/// colours, ratios and running paces. Each phrase is read as a value and a chain of steps on it, so
/// steps combine across calculators: "2x(15 usd to gbp)", "christmas 9am pst to tokyo to unix",
/// "(9am to 5:30pm - 30 min) x 5", "lighten tomato by 10% to hsl". Anything else stays a search.
public struct AddressCalculation: Equatable, Sendable {
    public struct Color: Equatable, Sendable {
        public let red: Int, green: Int, blue: Int
        public let alpha: Double

        public init(red: Int, green: Int, blue: Int, alpha: Double = 1) {
            self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
        }
    }

    public let text: String
    public let color: Color?
    /// A conversion's number alone, as copying gives it unless units are kept: "10.68" for
    /// "£10.68", "150" for "150 minutes". Nil for an answer that isn't one amount, and for dates,
    /// times and colours, whose numbers mean nothing bare.
    public internal(set) var amount: String?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    /// What an answer can depend on besides the words typed.
    struct Context {
        var now: Date
        var zone: TimeZone
        var locale: Locale
        /// Clock times read "6:00 pm" rather than "18:00": as typed, or as the person's clock shows them.
        var twelveHour: Bool
        /// "3/4/2026" is the 4th of March, as in the US, rather than the 3rd of April.
        var monthFirst: Bool
        var rates: () -> ExchangeRates?
        var primaryCurrency: () -> String
    }

    /// The answer to `input`, or nil when it isn't a calculation. Exchange rates are only looked up,
    /// and fetched when old, for a phrase that names money.
    public static func evaluate(_ input: String, now: Date = .now, timeZone: TimeZone = .current,
                                locale: Locale = .autoupdatingCurrent, rates: (() -> ExchangeRates?)? = nil,
                                primaryCurrency: String? = nil) -> Self? {
        guard input.utf8.count <= 256 else { return nil }
        let query = normalize(input)
        guard query.count >= 3, query.count <= 200 else { return nil }
        let typedTwelveHour = groups(#"\d ?(?:am|pm)\b"#, in: query) != nil
        let datePattern = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: locale) ?? ""
        let context = Context(
            now: now, zone: timeZone, locale: locale,
            twelveHour: typedTwelveHour || usesTwelveHourClock(locale),
            monthFirst: datePattern.firstIndex(of: "M").map { month in datePattern.firstIndex(of: "d").map { month < $0 } ?? false } ?? false,
            rates: rates ?? {
                ExchangeRateStore.shared.refreshIfStale()
                return ExchangeRateStore.shared.rates
            },
            primaryCurrency: { primaryCurrency ?? PrimaryCurrency.code(locale: locale) })
        if let colour = ColorCalculation.evaluate(query) { return colour }
        if var conversion = RatioCalculation.evaluate(query) ?? PaceCalculation.evaluate(query)
            ?? MoneyCalculation.evaluate(query, context) ?? QuantityExpression.evaluate(query, context) {
            conversion.amount = bareNumber(in: conversion.text)
            return conversion
        }
        return CalendarCalculation(context).evaluate(query).map { text in
            var answer = Self(text)
            answer.amount = durationAmount(in: text)
            return answer
        }
    }

    /// A length of time's number, "26" for "26 days" or "90 minutes", but not a date's, a time's
    /// or a week's, which mean nothing bare.
    static func durationAmount(in text: String) -> String? {
        guard text.first?.isNumber == true, let number = bareNumber(in: text) else { return nil }
        let units: Set<Substring> = ["sec", "secs", "second", "seconds", "min", "mins", "minute", "minutes", "hr", "hrs", "hour", "hours",
                                     "day", "days", "week", "weeks", "month", "months", "year", "years", "unix"]
        let words = text.lowercased().split { !$0.isLetter }
        return !words.isEmpty && words.allSatisfy(units.contains) ? number : nil
    }

    /// A converted amount's number alone, as it's written, without its currency or unit: "10.68"
    /// for "£10.68" or "CHF 10.68", "11.02" for "11.02 lb", "1.234,56" for "1.234,56 €". Nil where
    /// there's no number or more than one ("2 h 30 min", "€10 – €20", "5′ 11″"), and for a
    /// percentage or a clock time ("15% increase", "3 PM"), which mean nothing bare.
    public static func bareNumber(in text: String) -> String? {
        // Digits, with the separators locales group and divide them with, not run on from a letter
        // as a colour's hex is ("#FF6600").
        guard let expression = try? NSRegularExpression(pattern: #"(?<![\p{L}\d])[-−]?\d(?:[\d.,'’\x{00A0}\x{202F}\x{2009}]*\d)?"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let matches = expression.matches(in: text, range: range)
        guard matches.count == 1, let found = Range(matches[0].range, in: text) else { return nil }
        let rest = (text[..<found.lowerBound] + " " + text[found.upperBound...]).lowercased()
        guard !rest.contains(where: \.isNumber), !rest.contains("%"),
              !rest.split(whereSeparator: { !$0.isLetter }).contains(where: { ["am", "pm"].contains($0) }) else { return nil }
        return text[found].replacingOccurrences(of: "−", with: "-")
    }

    static func usesTwelveHourClock(_ locale: Locale) -> Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?.contains("a") ?? false
    }

    /// One spelling for what people type many ways: lower case, single spaces, straight quotes,
    /// "a.m." as "am", and without the question's opening words or closing mark.
    static func normalize(_ input: String) -> String {
        var text = input.lowercased()
        for (from, to) in [("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("−", "-"), ("–", "-"), ("—", "-"),
                           ("→", " to "), ("->", " to "), ("×", " x "), ("÷", " / "), ("·", " "),
                           ("a.m.", "am"), ("p.m.", "pm"), ("a.m", "am"), ("p.m", "pm")] {
            text = text.replacingOccurrences(of: from, with: to)
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // "9am pst = gmt" asks for it in GMT.
        text = text.replacingOccurrences(of: " = ", with: " in ")
        while let last = text.last, "?!=".contains(last) { text.removeLast(); text = text.trimmingCharacters(in: .whitespaces) }
        while text.first == "=" { text.removeFirst(); text = text.trimmingCharacters(in: .whitespaces) }
        for prefix in ["what's ", "whats ", "what is ", "calculate ", "calc ", "convert ", "how much is ", "please "]
        where text.hasPrefix(prefix) && text.count > prefix.count+2 {
            text.removeFirst(prefix.count)
            break
        }
        return text
    }

    private static let expressions = NSCache<NSString, NSRegularExpression>()

    /// The groups of `pattern`'s first match in `text`, "" for a group that took no part.
    static func groups(_ pattern: String, in text: String) -> [String]? {
        let key = pattern as NSString
        let expression: NSRegularExpression
        if let cached = expressions.object(forKey: key) { expression = cached }
        else {
            guard let compiled = try? NSRegularExpression(pattern: pattern) else {
                assertionFailure("Invalid calculation pattern: \(pattern)")
                return nil
            }
            expression = compiled
            expressions.setObject(compiled, forKey: key)
        }
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// "1,234.5": up to `digits` decimals, trailing zeros dropped.
    static func number(_ value: Double, digits: Int = 3, grouping: Bool = false) -> String {
        let style = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(0...digits)).grouping(grouping ? .automatic : .never)
        let text = value.formatted(style)
        return text == "-0" ? "0" : text
    }

    /// "New York", "PST": a name as written for people.
    static func titled(_ text: String) -> String {
        text.split(separator: " ").map { word in
            word.count <= 4 && word.allSatisfy(\.isLetter) && !["city", "san", "los", "las", "new", "east", "west", "rio", "sao"].contains(word)
                && CalculationZones.isAbbreviation(String(word)) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

/// A reading position in a phrase. `take` matches a pattern exactly where reading has got to and moves
/// past it; a copy keeps the old position, to go back to when a longer reading fails.
struct Cursor {
    private(set) var rest: String

    init(_ text: String) { rest = text }

    var isAtEnd: Bool { rest.isEmpty }

    mutating func take(_ pattern: String) -> [String]? {
        guard let match = AddressCalculation.groups("^(?:" + pattern + ")", in: rest), !match[0].isEmpty else { return nil }
        rest.removeFirst(match[0].count)
        return match
    }

    mutating func skip(_ count: Int) { rest.removeFirst(min(count, rest.count)) }

    func peek(_ pattern: String) -> Bool {
        AddressCalculation.groups("^(?:" + pattern + ")", in: rest) != nil
    }
}

/// Every way of reading `text` as two parts either side of `separator`, nearest the start first.
func splits(_ text: String, around separator: String) -> [(String, String)] {
    var result: [(String, String)] = []
    var searchStart = text.startIndex
    while let range = text.range(of: separator, range: searchStart..<text.endIndex) {
        let left = String(text[..<range.lowerBound]), right = String(text[range.upperBound...])
        if !left.isEmpty, !right.isEmpty { result.append((left, right)) }
        searchStart = text.index(after: range.lowerBound)
    }
    return result
}
