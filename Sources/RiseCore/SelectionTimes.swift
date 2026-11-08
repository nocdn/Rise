import Foundation

/// A selected clock time in another zone, or a snapshot of the current time in a selected offset.
public struct SelectionTime: Equatable {
    public let start: Date
    public let end: Date?
    public let zone: TimeZone
    public let written: String
    /// A zone without a clock time describes the current time there, not an appointment.
    public let isZoneOnly: Bool

    init(start: Date, end: Date?, zone: TimeZone, written: String, isZoneOnly: Bool = false) {
        self.start = start; self.end = end; self.zone = zone; self.written = written
        self.isZoneOnly = isZoneOnly
    }
}

/// Times in selected text, in the person's own zone, for the right-click menu to head with: "10am PST"
/// selected reads "18:00 (in 3 hours)", and "11pm PST" "Tomorrow at 07:00 (in 15 hours)"; the iPhone's
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

    /// Foreign clock times and standalone numeric zones in `text`, read as of `now`.
    public static func find(in text: String, now: Date = Date(), local: TimeZone = .current, includingLocal: Bool = false) -> [SelectionTime] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength else { return [] }
        var found: [SelectionTime] = []
        for match in matches(in: text, now: now, local: local, includingLocal: includingLocal) {
            if !found.contains(where: { $0.start == match.time.start && $0.end == match.time.end && $0.isZoneOnly == match.time.isZoneOnly
                && (!$0.isZoneOnly || $0.zone == match.time.zone) }) { found.append(match.time) }
        }
        return Array(found.prefix(maximumTimes))
    }

    /// Exact UTF-16 ranges, including the written zone, for reversible page edits. Unlike the
    /// selection menu this retains repeated occurrences and every time in a passage.
    static func matches(in text: String, now: Date, local: TimeZone, includingLocal: Bool = false) -> [(range: NSRange, time: SelectionTime)] {
        guard !text.isEmpty, text.utf16.count <= 32_000,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        // "noon" and "midnight" as times the detector reads; midnight is the one the day ends with.
        let normalized = Normalized(text), normal = normalized.text
        let source = normal as NSString
        let stamps = Timestamp.matches(in: normal)
        let detectionText = NSMutableString(string: normal)
        for stamp in stamps { detectionText.replaceCharacters(in: stamp.range, with: String(repeating: " ", count: stamp.range.length)) }
        let offsets = Offset.matches(in: normal)
        var usedOffsets = Set<Int>(), found: [(range: NSRange, time: SelectionTime)] = stamps.compactMap { stamp in
            guard let time = stamp.time else { return nil }
            return (normalized.original(stamp.range), time)
        }
        for match in detector.matches(in: detectionText as String, range: NSRange(location: 0, length: source.length)) {
            guard let detected = match.date else { continue }
            let words = source.substring(with: match.range)
            // An offset's digits are not a clock time. Mask them before reading the clock.
            let clockWords = NSMutableString(string: words)
            for offset in offsets.reversed() {
                let overlap = NSIntersectionRange(match.range, offset.range)
                if overlap.length > 0 {
                    clockWords.replaceCharacters(in: NSRange(location: overlap.location-match.range.location, length: overlap.length),
                        with: String(repeating: " ", count: overlap.length))
                }
            }
            guard let clock = Clock(clockWords as String) else { continue }
            // The zone it was written in: as the detector read it, or written just after it.
            let after = source.substring(from: NSMaxRange(match.range))
            let attached = offsets.firstIndex { offset in
                if NSIntersectionRange(match.range, offset.range).length > 0 { return true }
                guard match.timeZone == nil else { return false }
                let gap = offset.range.location >= NSMaxRange(match.range)
                    ? NSRange(location: NSMaxRange(match.range), length: offset.range.location-NSMaxRange(match.range))
                    : NSRange(location: NSMaxRange(offset.range), length: match.range.location-NSMaxRange(offset.range))
                return source.substring(with: gap).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]"))).isEmpty
            }
            let zone: TimeZone
            var range = match.range
            if let attached {
                usedOffsets.insert(attached)
                guard let explicit = offsets[attached].zone else { continue }
                zone = explicit
                range = NSUnionRange(range, offsets[attached].range)
            } else {
                guard let detectedZone = match.timeZone ?? Self.zone(at: after) ?? Self.zone(at: words) else { continue }
                zone = detectedZone
                if let suffix = zoneExpression.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)),
                   Self.zone(at: (after as NSString).substring(with: suffix.range)) != nil {
                    range.length += suffix.range.length
                }
            }
            // The wall time as written, from the zone the detector read it in.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = match.timeZone ?? .current
            var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: detected)
            if let hour = clock.hour { parts.hour = hour; parts.minute = clock.minute }
            if clock.midnight { parts.hour = 23; parts.minute = 59 }
            var there = Calendar(identifier: .gregorian); there.timeZone = zone
            parts.second = clock.midnight ? 0 : clock.second; parts.timeZone = zone
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
            // Data Detectors can infer a one-hour appointment from prose such as "Starts at".
            // Only a written range belongs in the converted text.
            let hasRange = words.range(of: #"(?i)(?:\d|noon|midnight)\h*(?:[ap]\.?m\.?)?\h*(?:[-–—]|\bto\b)\h*(?:\d|noon|midnight)"#, options: .regularExpression) != nil
            let end = hasRange && match.duration > 0 ? start.addingTimeInterval(match.duration) : nil
            // Written in the person's own zone: nothing to tell them. Another zone, even at the same
            // offset as theirs just then, still gets its day and how far off it is.
            guard includingLocal || !same(zone, local, at: start) else { continue }
            // A detector sometimes includes "Starts at" or "Meet at" in its range. Preserve
            // that prose while retaining an actual weekday/date before the clock.
            let contents = source.substring(with: range)
            if Self.zone(at: contents) == nil, let start = contents.range(of: #"(?i)\b(?:today|tonight|tomorrow|yesterday|mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?|jan[a-z]*|feb[a-z]*|mar[a-z]*|apr[a-z]*|may|jun[a-z]*|jul[a-z]*|aug[a-z]*|sep[a-z]*|oct[a-z]*|nov[a-z]*|dec[a-z]*|noon|midnight)\b|\d"#, options: .regularExpression) {
                let leading = (contents[..<start.lowerBound] as NSString).length
                range.location += leading; range.length -= leading
            }
            let originalRange = normalized.original(range)
            let written = (text as NSString).substring(with: originalRange).trimmingCharacters(in: .whitespaces)
            let time = SelectionTime(start: start, end: end, zone: zone, written: written)
            if !found.contains(where: { NSIntersectionRange($0.range, originalRange).length > 0 }) { found.append((originalRange, time)) }
        }
        for (index, offset) in offsets.enumerated() where !usedOffsets.contains(index) {
            guard let zone = offset.zone, !found.contains(where: { $0.time.isZoneOnly && $0.time.zone == zone }) else { continue }
            found.append((normalized.original(offset.range), SelectionTime(start: now, end: nil, zone: zone,
                written: source.substring(with: offset.range), isZoneOnly: true)))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    private static let zoneExpression = try! NSRegularExpression(pattern: #"^\s*\(?\s*(?:[A-Z][A-Za-z_]+/[A-Za-z_+\-0-9]+(?:/[A-Za-z_+\-0-9]+)?|[A-Z]{1,5}\b|Pacific\b|Mountain\b|Central\b|Eastern\b)\)?"#)

    /// Preserve offsets into the original even where a clock word expanded for Data Detectors.
    private struct Normalized {
        let text: String
        let boundaries: [Int]
        init(_ original: String) {
            let source = original as NSString
            let words = try! NSRegularExpression(pattern: #"(?i)\b(noon|midnight)\b"#)
            var text = "", boundaries = [0], at = 0
            for match in words.matches(in: original, range: NSRange(location: 0, length: source.length)) {
                text += source.substring(with: NSRange(location: at, length: match.range.location-at))
                if at < match.range.location { boundaries += Array((at+1)...match.range.location) }
                let replacement = source.substring(with: match.range).lowercased() == "noon" ? "12:00pm" : "11:59:59pm"
                text += replacement
                boundaries += (1...replacement.utf16.count).map { match.range.location + min($0, match.range.length) }
                at = NSMaxRange(match.range)
            }
            text += source.substring(from: at)
            if at < source.length { boundaries += Array((at+1)...source.length) }
            self.text = text; self.boundaries = boundaries
        }
        func original(_ range: NSRange) -> NSRange {
            NSRange(location: boundaries[range.location], length: boundaries[NSMaxRange(range)]-boundaries[range.location])
        }
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
        if let offset = Offset.matches(in: text as String).first,
           text.substring(to: offset.range.location).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "("))).isEmpty {
            return offset.zone
        }
        if let city = first(#"^\s*\(?\s*([A-Z][A-Za-z_]+/[A-Za-z_+\-0-9]+(?:/[A-Za-z_+\-0-9]+)?)"#) { return TimeZone(identifier: city) }
        guard let word = first(#"^\s*\(?\s*([A-Z]{1,5}|Pacific|Mountain|Central|Eastern)\b"#)?.uppercased() else { return nil }
        if let name = TimeZone.abbreviationDictionary[word] ?? extraZones[word] { return TimeZone(identifier: name) }
        return nil
    }

    /// How a time reads to the person: the time in their own zone, which they know, so unnamed; its day
    /// as they'd say it unless it's today; how far off it is; a range from its start to its end; and,
    /// of several, what each was written as.
    public static func label(_ time: SelectionTime, of count: Int = 1, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> String {
        let displayZone = time.isZoneOnly ? time.zone : local
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = displayZone; calendar.locale = locale
        var here = calendar; here.timeZone = local
        // For a zone-only result, tomorrow/yesterday compares its date with today's date here.
        let referenceDay = time.isZoneOnly ? calendar.date(from: here.dateComponents([.year, .month, .day], from: now)) ?? now : now
        let clock = DateFormatter(); clock.locale = locale; clock.timeZone = displayZone; clock.setLocalizedDateFormatFromTemplate("jmm")
        func day(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: referenceDay), to: calendar.startOfDay(for: date)).day ?? 0
            switch days {
            case 0: return ""
            case 1: return "Tomorrow"
            case -1: return "Yesterday"
            case 2...6:
                let weekday = DateFormatter(); weekday.locale = locale; weekday.timeZone = displayZone; weekday.setLocalizedDateFormatFromTemplate("EEEE")
                return weekday.string(from: date)
            default:
                let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
                let dated = DateFormatter(); dated.locale = locale; dated.timeZone = displayZone
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
        if time.isZoneOnly {
            let difference = time.zone.secondsFromGMT(for: time.start)-local.secondsFromGMT(for: time.start)
            let minutes = abs(difference)/60, hours = minutes/60, remainder = minutes%60
            let amount = remainder == 0 ? "\(hours) \(hours == 1 ? "hour" : "hours")"
                : hours == 0 ? "\(remainder) min" : "\(hours) hr \(remainder) min"
            text += " there · " + (difference == 0 ? "same time as here" : amount + (difference > 0 ? " ahead" : " behind"))
        } else if let end = time.end, time.start <= now, now < end { text += " (happening now)" }
        else if let away = away(from: now, to: time.start) { text += " (\(away))" }
        return count > 1 ? "\(time.written) → \(text)" : text
    }

    /// The time to paste somewhere, which mustn't go stale: "07:00", or "Sat 24 Oct at 07:00" on another
    /// day, and a range from its start to its end.
    public static func copied(_ time: SelectionTime, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> String {
        let displayZone = time.isZoneOnly ? time.zone : local
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = displayZone
        func text(_ date: Date, day: Bool) -> String {
            let format = DateFormatter(); format.locale = locale; format.timeZone = displayZone
            let sameYear = !time.isZoneOnly && calendar.component(.year, from: date) == calendar.component(.year, from: now)
            format.setLocalizedDateFormatFromTemplate(day ? (sameYear ? "EEEdMMMjmm" : "EEEdMMMyjmm") : "jmm")
            return format.string(from: date)
        }
        if time.isZoneOnly { return text(time.start, day: true)+" "+Offset.name(time.zone.secondsFromGMT(for: time.start)) }
        let start = text(time.start, day: !calendar.isDate(time.start, inSameDayAs: now))
        guard let end = time.end else { return start }
        return "\(start) – \(text(end, day: !calendar.isDate(end, inSameDayAs: time.start)))"
    }

    /// Keep invalid numeric tokens too, so an attached malformed offset cannot fall back to UTC.
    private struct Offset {
        let range: NSRange
        let zone: TimeZone?
        private static let expression = try! NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{N}_])(?:UTC|GMT)\h*[+\-−–]\h*[\p{L}\p{N}_:.]*"#)

        static func matches(in text: String) -> [Offset] {
            let source = text as NSString
            return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
                let written = source.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let range = NSRange(location: match.range.location, length: (written as NSString).length)
                let token = written.filter { !$0.isWhitespace }
                let number = String(token.dropFirst(4)), parts = number.split(separator: ":", omittingEmptySubsequences: false)
                let hours: Int?, minutes: Int?
                if parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2 {
                    hours = Int(parts[0]); minutes = Int(parts[1])
                } else if parts.count == 1, (1...4).contains(number.count) {
                    hours = Int(number.count <= 2 ? number : String(number.dropLast(2)))
                    minutes = number.count <= 2 ? 0 : Int(number.suffix(2))
                } else { hours = nil; minutes = nil }
                let negative = token.dropFirst(3).first != "+"
                let zone: TimeZone?
                if let hours, let minutes, minutes < 60, hours*60+minutes <= 14*60 {
                    zone = TimeZone(secondsFromGMT: (negative ? -1 : 1)*(hours*3600+minutes*60))
                } else { zone = nil }
                return Offset(range: range, zone: zone)
            }
        }

        static func name(_ seconds: Int) -> String {
            String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", abs(seconds)/3600, abs(seconds)/60%60)
        }
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
        let hour: Int?, minute: Int, second: Int, midnight: Bool
        init?(_ words: String) {
            let text = words as NSString
            midnight = words.contains("11:59:59pm")
            func groups(_ pattern: String) -> [String]? {
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                      let match = regex.firstMatch(in: words, range: NSRange(location: 0, length: text.length)) else { return nil }
                return (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : text.substring(with: match.range(at: $0)) }
            }
            second = groups(#"\d{1,2}:\d{2}:(\d{2})(?!\d)"#).flatMap { Int($0[1]) } ?? 0
            guard second < 60 else { return nil }
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
