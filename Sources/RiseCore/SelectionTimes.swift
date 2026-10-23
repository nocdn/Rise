import Foundation

/// A time written in another zone, found in selected text: when it starts, when it ends if it's a
/// range, the zone it was written in and the words it was read from.
public struct SelectionTime: Equatable {
    public let start: Date
    public let end: Date?
    public let zone: TimeZone
    public let written: String
}

/// Times in selected text, in the person's own zone, for the right-click menu to head with: "10am PST"
/// selected reads "18:00 · in 3 hours", and "11pm PST" "Tomorrow at 07:00 · in 15 hours"; the iPhone's
/// selection menu offers the same. The system's date detector finds dates and times, ranges and words such as "tomorrow"; what it misses, this reads itself: zones it doesn't know,
/// "noon" and "midnight", and an hour written without am or pm, which is a 24-hour one.
public enum SelectionTimes {
    static let maximumLength = 400, maximumTimes = 3
    /// An undated time further back than this today is tomorrow's.
    static let longGone: TimeInterval = 12*3600

    /// Zones people write that the system's list of abbreviations lacks.
    static let extraZones: [String: String] = [
        "PT": "America/Los_Angeles", "MT": "America/Denver", "CT": "America/Chicago", "ET": "America/New_York",
        "AKT": "America/Anchorage", "HT": "Pacific/Honolulu",
        "AEST": "Australia/Sydney", "AEDT": "Australia/Sydney", "AET": "Australia/Sydney",
        "ACST": "Australia/Adelaide", "ACDT": "Australia/Adelaide", "AWST": "Australia/Perth",
        "NZT": "Pacific/Auckland", "SAST": "Africa/Johannesburg", "WIB": "Asia/Jakarta",
        "CEST": "Europe/Paris", "CET": "Europe/Paris", "UTC": "UTC", "Z": "UTC",
        "PACIFIC": "America/Los_Angeles", "MOUNTAIN": "America/Denver", "CENTRAL": "America/Chicago", "EASTERN": "America/New_York",
    ]

    /// The times in `text` that are in a zone other than `local`'s at the time, read as of `now`.
    public static func find(in text: String, now: Date = Date(), local: TimeZone = .current) -> [SelectionTime] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        // "noon" and "midnight" as times the detector reads; midnight is the one the day ends with.
        let normal = text.replacingOccurrences(of: #"(?i)\bnoon\b"#, with: "12:00pm", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bmidnight\b"#, with: "11:59:59pm", options: .regularExpression)
        let source = normal as NSString
        var found: [SelectionTime] = []
        for match in detector.matches(in: normal, range: NSRange(location: 0, length: source.length)) {
            guard let detected = match.date else { continue }
            let words = source.substring(with: match.range)
            guard let clock = Clock(words) else { continue }
            // The zone it was written in: as the detector read it, or written just after it.
            let after = source.substring(from: NSMaxRange(match.range))
            guard let zone = match.timeZone ?? zone(at: after) ?? zone(at: words) else { continue }
            // The wall time as written, from the zone the detector read it in.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = match.timeZone ?? .current
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: detected)
            if let hour = clock.hour { parts.hour = hour; parts.minute = clock.minute }
            if clock.midnight { parts.hour = 23; parts.minute = 59 }
            var there = Calendar(identifier: .gregorian); there.timeZone = zone
            parts.second = 0; parts.timeZone = zone
            func instant(_ parts: DateComponents) -> Date? { there.date(from: parts).map { clock.midnight ? $0.addingTimeInterval(60) : $0 } }
            var start: Date?
            if Clock.hasDate(words) { start = instant(parts) }
            else {
                // Without a date, today's where it was written, as the writer would mean it; unless
                // that's long gone, when it's the next one.
                for offset in [0, 1] where start.map({ $0 < now.addingTimeInterval(-SelectionTimes.longGone) }) ?? true {
                    guard let day = there.date(byAdding: .day, value: offset, to: now) else { continue }
                    let date = there.dateComponents([.year, .month, .day], from: day)
                    var candidate = parts; candidate.year = date.year; candidate.month = date.month; candidate.day = date.day
                    start = instant(candidate) ?? start
                }
            }
            guard let start else { continue }
            let end = match.duration > 0 ? start.addingTimeInterval(match.duration) : nil
            // Written in the person's own zone: nothing to tell them. Another zone, even at the same
            // offset as theirs just then, still gets its day and how far off it is.
            guard !same(zone, local, at: start) else { continue }
            let written = words.replacingOccurrences(of: "11:59:59pm", with: "midnight").trimmingCharacters(in: .whitespaces)
            let time = SelectionTime(start: start, end: end, zone: zone, written: written)
            if !found.contains(where: { $0.start == time.start && $0.end == time.end }) { found.append(time) }
            if found.count == maximumTimes { break }
        }
        return found
    }

    /// Whether two zones are the same place's: one zone, or one keeping the same time all year.
    static func same(_ zone: TimeZone, _ local: TimeZone, at date: Date) -> Bool {
        if zone.identifier == local.identifier { return true }
        // A fixed offset (as "GMT+1") is the person's own only where theirs never changes.
        let year = (0..<12).map { date.addingTimeInterval(Double($0)*30*86400) }
        return year.allSatisfy { zone.secondsFromGMT(for: $0) == local.secondsFromGMT(for: $0) }
    }

    /// A zone written at the start of `text`: an offset from UTC or GMT, a city's zone such as
    /// "Europe/Berlin", or an abbreviation or name such as "PST" or "Pacific", in brackets or not.
    static func zone(at text: String) -> TimeZone? {
        let text = text as NSString
        func first(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { return nil }
            return text.substring(with: match.range(at: 1))
        }
        if let offset = first(#"^\s*\(?\s*((?:UTC|GMT)\s*[+\-−–]\s*\d{1,2}(?::?\d{2})?)"#) {
            let digits = offset.dropFirst(3).trimmingCharacters(in: .whitespaces)
            let negative = digits.hasPrefix("-") || digits.hasPrefix("−") || digits.hasPrefix("–")
            let number = digits.dropFirst().replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            let hours = Int(number.count > 2 ? String(number.prefix(number.count-2)) : number) ?? 0
            let minutes = number.count > 2 ? Int(number.suffix(2)) ?? 0 : 0
            guard hours <= 14, minutes < 60 else { return nil }
            return TimeZone(secondsFromGMT: (negative ? -1 : 1)*(hours*3600+minutes*60))
        }
        if let city = first(#"^\s*\(?\s*([A-Z][A-Za-z_]+/[A-Za-z_]+(?:/[A-Za-z_]+)?)"#) { return TimeZone(identifier: city) }
        guard let word = first(#"^\s*\(?\s*([A-Z]{1,5}|Pacific|Mountain|Central|Eastern)\b"#)?.uppercased() else { return nil }
        if let name = TimeZone.abbreviationDictionary[word] ?? extraZones[word] { return TimeZone(identifier: name) }
        return nil
    }

    /// How a time reads to the person: the time in their own zone, which they know, so unnamed; its day
    /// as they'd say it unless it's today; how far off it is; a range from its start to its end; and,
    /// of several, what each was written as.
    public static func label(_ time: SelectionTime, of count: Int = 1, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = local; calendar.locale = locale
        let clock = DateFormatter(); clock.locale = locale; clock.timeZone = local; clock.setLocalizedDateFormatFromTemplate("jmm")
        func day(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
            switch days {
            case 0: return ""
            case 1: return "Tomorrow"
            case -1: return "Yesterday"
            case 2...6:
                let weekday = DateFormatter(); weekday.locale = locale; weekday.timeZone = local; weekday.setLocalizedDateFormatFromTemplate("EEEE")
                return weekday.string(from: date)
            default:
                let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
                let dated = DateFormatter(); dated.locale = locale; dated.timeZone = local
                dated.setLocalizedDateFormatFromTemplate(sameYear ? "EEEdMMM" : "EEEdMMMy")
                return dated.string(from: date)
            }
        }
        func at(_ date: Date, joined: String) -> String {
            let day = day(date), time = clock.string(from: date)
            return day.isEmpty ? time : day + joined + time
        }
        var text: String
        if let end = time.end {
            text = calendar.isDate(time.start, inSameDayAs: end)
                ? "\(at(time.start, joined: ", ")) – \(clock.string(from: end))"
                : "\(at(time.start, joined: " ")) – \(at(end, joined: " "))"
        } else {
            text = at(time.start, joined: " at ")
        }
        if let end = time.end, time.start <= now, now < end { text += " · happening now" }
        else if let away = away(from: now, to: time.start) { text += " · \(away)" }
        return count > 1 ? "\(time.written) → \(text)" : text
    }

    /// The time to paste somewhere, which mustn't go stale: "07:00", or "Sat 24 Oct at 07:00" on another
    /// day, and a range from its start to its end.
    public static func copied(_ time: SelectionTime, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = local
        func text(_ date: Date, day: Bool) -> String {
            let format = DateFormatter(); format.locale = locale; format.timeZone = local
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            format.setLocalizedDateFormatFromTemplate(day ? (sameYear ? "EEEdMMMjmm" : "EEEdMMMyjmm") : "jmm")
            return format.string(from: date)
        }
        let start = text(time.start, day: !calendar.isDate(time.start, inSameDayAs: now))
        guard let end = time.end else { return start }
        return "\(start) – \(text(end, day: !calendar.isDate(end, inSameDayAs: time.start)))"
    }

    /// "in 3 hours", "45 min ago", "in 2 days": round enough to read at a glance.
    static func away(from now: Date, to date: Date) -> String? {
        let minutes = Int((date.timeIntervalSince(now)/60).rounded())
        let size = abs(minutes)
        let amount: String
        switch size {
        case 0: return "now"
        case 1..<60: amount = "\(size) min"
        case 60..<120: amount = size % 60 == 0 ? "1 hour" : "1 hr \(size % 60) min"
        case 120..<(48*60): amount = "\(Int((Double(size)/60).rounded())) hours"
        default: amount = "\(Int((Double(size)/1440).rounded())) days"
        }
        return minutes > 0 ? "in \(amount)" : "\(amount) ago"
    }

    /// The time of day as written in a detected date: present at all, and its hour on a 24-hour
    /// clock when it's written without am or pm.
    struct Clock {
        let hour: Int?, minute: Int, midnight: Bool
        init?(_ words: String) {
            let text = words as NSString
            midnight = words.contains("11:59:59pm")
            func groups(_ pattern: String) -> [String]? {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: words, range: NSRange(location: 0, length: text.length)) else { return nil }
                return (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : text.substring(with: match.range(at: $0)) }
            }
            // Written with am or pm: the detector reads it right.
            if groups(#"\b\d{1,2}(?::\d{2})?\s*(?:a\.?\s?m\b\.?|p\.?\s?m\b\.?)"#) != nil { hour = nil; minute = 0; return }
            // "14:30", "9:30", "T17:00" or "1700 UTC": a 24-hour clock.
            if let parts = groups(#"(?:^|[^\d:])(\d{1,2}):(\d{2})(?!\d)"#) ?? groups(#"\b([01]\d|2[0-3])([0-5]\d)\b(?=\s*(?:UTC|GMT|Z|[A-Z]{2,5})\b)"#),
               let hour = Int(parts[1]), let minute = Int(parts[2]), hour < 24, minute < 60 {
                self.hour = hour; self.minute = minute; return
            }
            return nil
        }
        /// Whether the words name a day: a month, a weekday, a date in numbers, or a word such as tomorrow.
        static func hasDate(_ words: String) -> Bool {
            let pattern = #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\b|\b(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*\b|\b(today|tonight|tomorrow|yesterday)\b|\b\d{1,4}[/\-.]\d{1,2}[/\-.]\d{1,4}\b|\b\d{1,2}/\d{1,2}\b|\b\d{1,2}(st|nd|rd|th)\b"#
            return words.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
