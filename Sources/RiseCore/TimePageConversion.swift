import Foundation

extension SelectionTimes {
    /// ISO/RFC 3339 and PostgreSQL timestamptz output. A missing zone is deliberately not UTC.
    struct Timestamp {
        let range: NSRange
        let time: SelectionTime?
        static let expression = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:\d{8}[Tt]\d{6}[Zz]|\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}(?::\d{2}(?:[.,]\d{1,9})?)?(?:\h*(?:[Zz]|[+\-][\d:]+|UTC(?:\h*[+\-][\d:]+)?|GMT(?:\h*[+\-][\d:]+)?|[A-Z][A-Za-z_]+/[A-Za-z_+\-0-9]+(?:/[A-Za-z_+\-0-9]+)?))?)(?![\p{L}\p{N}_])"#)
        private static let components = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})[Tt ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?\h*([Zz]|[+\-]\d{2}(?::?\d{2})?|UTC(?:\h*[+\-][\d:]+)?|GMT(?:\h*[+\-][\d:]+)?|[A-Z][A-Za-z_]+/[A-Za-z_+\-0-9]+(?:/[A-Za-z_+\-0-9]+)?)$"#)
        static func matches(in text: String) -> [Timestamp] {
            let source = text as NSString
            return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
                let written = source.substring(with: match.range)
                let canonical = written.replacingOccurrences(of: #"(?i)^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$"#, with: "$1-$2-$3T$4:$5:$6Z", options: .regularExpression)
                let value = canonical as NSString
                func read() -> SelectionTime? {
                    guard let m = components.firstMatch(in: canonical, range: NSRange(location: 0, length: value.length)) else { return nil }
                    func group(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : value.substring(with: m.range(at: i)) }
                    let numbers = (1...6).map { Int(group($0)) ?? 0 }
                    let token = group(8), digits = token.dropFirst().filter(\.isNumber)
                    let hours = Int(digits.prefix(2)) ?? 0, minutes = digits.count == 4 ? Int(digits.suffix(2)) ?? 0 : 0
                    let named = token.first?.isLetter == true
                    guard numbers[0] > 0, (1...12).contains(numbers[1]), (1...31).contains(numbers[2]),
                          numbers[3] < 24, numbers[4] < 60, numbers[5] < 60,
                          named || minutes < 60 && hours*60+minutes <= 14*60,
                          let zone = named ? SelectionTimes.zone(at: token.uppercased() == "Z" ? "UTC" : token)
                            : TimeZone(secondsFromGMT: (token.first == "-" ? -1 : 1)*(hours*3600+minutes*60)) else { return nil }
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                    let parts = DateComponents(timeZone: zone, year: numbers[0], month: numbers[1], day: numbers[2],
                                               hour: numbers[3], minute: numbers[4], second: numbers[5])
                    guard let whole = calendar.date(from: parts) else { return nil }
                    let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
                    guard [actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second] == numbers.map(Optional.some) else { return nil }
                    let fraction = Double("0."+group(7)) ?? 0
                    return SelectionTime(start: whole.addingTimeInterval(fraction), end: nil, zone: zone, written: written)
                }
                return Timestamp(range: match.range, time: read())
            }
        }
    }

    /// Permanent page text includes its local zone and preserves a timestamp's explicit date.
    public static func onPage(_ time: SelectionTime, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> String {
        let dated = Clock.hasDate(time.written) || Timestamp.expression.firstMatch(in: time.written, range: NSRange(location: 0, length: time.written.utf16.count)) != nil
        let seconds = time.written.range(of: #"\d{1,2}:\d{2}:\d{2}|\d{8}[Tt]\d{6}[Zz]"#, options: .regularExpression) != nil
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = local
        let format = DateFormatter(); format.locale = locale; format.timeZone = local
        func text(_ date: Date) -> String {
            let includeDate = dated || !calendar.isDate(date, inSameDayAs: now)
            format.setLocalizedDateFormatFromTemplate((includeDate ? "dMMMy" : "") + (seconds ? "jmmss" : "jmm"))
            let value = format.string(from: date)
            let style: TimeZone.NameStyle = local.isDaylightSavingTime(for: date) ? .shortDaylightSaving : .shortStandard
            return value + " " + (local.localizedName(for: style, locale: locale) ?? local.abbreviation(for: date) ?? local.identifier)
        }
        return text(time.start) + (time.end.map { " – " + text($0) } ?? "")
    }
}

/// Local times on the page, in place of those in other zones.
@MainActor public final class TimePageConversion {
    public typealias Evaluate = PageTextConversion.Evaluate
    public typealias Edit = PageTextConversion.Edit
    private let conversion: PageTextConversion
    public var isActive: Bool { conversion.isActive }
    public var count: Int { conversion.count }
    public var onChange: (() -> Void)? {
        get { conversion.onChange }
        set { conversion.onChange = newValue }
    }
    public init(evaluate: @escaping Evaluate) { conversion = PageTextConversion(global: "riseTimes", evaluate: evaluate) }
    public func waitUntilReady() async { await conversion.waitUntilReady() }

    public nonisolated static func edits(in text: String, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> [Edit] {
        guard text.range(of: #"(?i)\d:\d{2}|\d\h*[ap]\.?m\b|noon|midnight|\b\d{4}\h+(?:UTC|GMT|[A-Z]{2,5})\b|\d{8}t\d{6}z"#, options: .regularExpression) != nil else { return [] }
        return SelectionTimes.matches(in: text, now: now, local: local).compactMap { match in
            guard !match.time.isZoneOnly else { return nil }
            let replacement = SelectionTimes.onPage(match.time, now: now, local: local, locale: locale)
            guard replacement != (text as NSString).substring(with: match.range) else { return nil }
            return Edit(start: match.range.location, end: NSMaxRange(match.range), text: replacement)
        }
    }

    @discardableResult public func set(_ on: Bool, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) async throws -> Int {
        try await conversion.set(on) { Self.edits(in: $0, now: now, local: local, locale: locale) }
    }

    public static let noticeDuration: TimeInterval = 1.25
    public static let restoredMessage = "Original times restored"
    public static func message(_ count: Int) -> String {
        count == 0 ? "No other times to replace" : "Replaced \(count) \(count == 1 ? "time" : "times") with local time"
    }

    public static var script: String { PageTextConversion.script(global: "riseTimes") }
}
