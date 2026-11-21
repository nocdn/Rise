import Foundation

/// An event read from selected text: what it is, when, and where, ready for a calendar's editor.
public struct SelectionEvent: Equatable {
    public var title: String
    public var start: Date
    /// Exclusive: for an all-day event, the start of the day after its last.
    public var end: Date
    public var isAllDay: Bool
    /// Whether an end was written, rather than an hour assumed.
    public var hasEnd: Bool
    /// The zone the times were written in, where that isn't the person's own.
    public var timeZone: TimeZone?
    public var location: String?
    /// A video call's link, such as Zoom's or Meet's.
    public var meetingURL: URL?
    /// The selection, as written.
    public var notes: String

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, hasEnd: Bool = true, timeZone: TimeZone? = nil,
                location: String? = nil, meetingURL: URL? = nil, notes: String = "") {
        self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay; self.hasEnd = hasEnd
        self.timeZone = timeZone; self.location = location; self.meetingURL = meetingURL; self.notes = notes
    }
}

/// Events in selected text, for the right-click menu's Add to Calendar and the iPhone's selection menu.
///
/// The system's date detector reads days well, in any order and language the person's locale knows,
/// with "tomorrow" and "next Friday", ranges of days, and which year a date without one means. It's
/// weaker at clocks: "13:30 - 20:30" on the line under a date, "Starts: 3 Nov 2026 13:30", and
/// "9:30" written without am or pm, which is a 24-hour time. So days come from the detector, line by
/// line, and clocks, ranges, zones, labelled fields ("Date:", "Where"), the location and the title
/// are read here.
public enum SelectionEvents {
    static let maximumLength = 3000
    /// How far a time on its own line may be from the date it belongs to.
    static let nearbyLines = 3

    /// The first event in `text`: a day, a time, or both. `pageTitle` names it when the selection doesn't.
    public static func find(in text: String, pageTitle: String? = nil, now: Date = Date(),
                            local: TimeZone = .current) -> SelectionEvent? {
        let notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty, notes.count <= maximumLength else { return nil }
        let lines = Line.split(normalized(notes))
        let reader = Reader(lines: lines, now: now, local: local)
        return reader.event(pageTitle: pageTitle, notes: notes)
    }

    /// Typographic spaces as spaces, invisible characters gone, and noon and midnight as clocks.
    static func normalized(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: scalars.append(" ")
            case 0x200B...0x200D, 0x2060, 0xFEFF, 0x00AD: continue
            case 0x2028, 0x2029, 0x0D: scalars.append("\n")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    // MARK: Lines and their labels

    enum Field: Equatable { case title, when, start, end, location, zone, other, none
        /// Lines whose times describe the event.
        var isTemporal: Bool { self == .when || self == .start || self == .end }
    }

    struct Line {
        let field: Field
        /// The line after its label.
        let value: String
        /// Whether the line was only a label, with its value below.
        let bareLabel: Bool

        static let labels: [Field: Set<String>] = [
            .title: ["title", "event", "event name", "event title", "what", "subject", "session", "meeting", "topic",
                     "name of event", "occasion", "activity", "appointment", "summary", "talk", "workshop", "class", "webinar",
                     "conference", "concert", "party", "performance", "course", "lecture", "seminar", "meetup", "hackathon",
                     "show", "film", "movie", "game", "match", "exhibition", "festival", "ceremony", "interview", "call"],
            .when: ["when", "date", "dates", "date and time", "date & time", "date/time", "day", "time", "times",
                    "event date", "event time", "event dates", "schedule", "time and date", "time & date", "datum", "fecha",
                    "date and time of event", "on", "date(s)", "time(s)"],
            .start: ["start", "starts", "start time", "start date", "starts at", "begins", "begins at", "beginning", "from",
                     "doors", "doors open", "check-in time", "arrival", "arrive", "start date and time"],
            .end: ["end", "ends", "end time", "end date", "ends at", "until", "finish", "finishes", "finish time",
                   "end date and time", "closes", "close"],
            .location: ["location", "where", "venue", "address", "place", "room", "meeting point", "location/venue",
                        "venue address", "event location", "event venue", "meeting place", "in person", "location address",
                        "where to go", "directions", "venue/location", "ort", "lugar", "lieu"],
            .zone: ["time zone", "timezone", "tz", "zone"],
        ]
        private static let label = try! NSRegularExpression(
            pattern: #"^[^\p{L}\p{N}]{0,3}(\p{L}[\p{L} &/'’()\-.]{0,32}?)\s*[:：](?!\d)\s*(.*)$"#)
        private static let bare = try! NSRegularExpression(pattern: #"^[^\p{L}\p{N}]{0,3}(\p{L}[\p{L} &/'’()\-]{0,32}?)\s*[:：]?\s*$"#)

        static func field(named name: String) -> Field? {
            let key = name.lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return labels.first { $0.value.contains(key) }?.key
        }

        /// Each line, with what its label says it holds. A label alone on its line, such as "Where",
        /// labels what follows: one line for a time, and up to a blank line or the next label for a place.
        static func split(_ text: String) -> [Line] {
            let raw = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            var lines: [Line] = [], carried: Field?, carriedLines = 0
            for line in raw {
                let source = line as NSString, whole = NSRange(location: 0, length: source.length)
                if line.isEmpty { carried = nil; lines.append(Line(field: .none, value: "", bareLabel: false)); continue }
                if let match = bare.firstMatch(in: line, range: whole), let field = field(named: source.substring(with: match.range(at: 1))) {
                    carried = field; carriedLines = 0
                    lines.append(Line(field: field, value: "", bareLabel: true)); continue
                }
                if let match = label.firstMatch(in: line, range: whole) {
                    let name = source.substring(with: match.range(at: 1)), value = source.substring(with: match.range(at: 2))
                    // "https://…" is no label, nor is "Tuesday: 10am–2pm"'s day.
                    if !value.hasPrefix("//"), field(named: name) != nil || !Dates.namesDay(name) {
                        let field = field(named: name) ?? .other
                        carried = nil
                        lines.append(Line(field: field, value: value.trimmingCharacters(in: .whitespaces), bareLabel: false)); continue
                    }
                }
                if let field = carried {
                    carriedLines += 1
                    lines.append(Line(field: field, value: line, bareLabel: false))
                    // A time is a line or two; a place goes on to its postcode and country.
                    if field != .location && carriedLines >= 2 || carriedLines >= 5 { carried = nil }
                    continue
                }
                lines.append(Line(field: .none, value: line, bareLabel: false))
            }
            return lines
        }
    }

    // MARK: Reading

    struct Day: Equatable { var year, month, day: Int }
    struct Clock: Equatable { var hour, minute: Int }

    /// A day the detector found, with the days it spans and the zone it read.
    struct DayPiece {
        let line: Int, location: Int, length: Int
        let day: Day
        /// The last day, for a range of days.
        let last: Day?
        let zone: TimeZone?
        /// Where the detector read a range with times of its own, as "Fri 6 Nov 7pm – Sun 8 Nov 5pm", its end.
        var detectedEnd: Date? = nil
    }

    /// A time of day, or a range of them, found on a line.
    struct ClockPiece {
        let line: Int, location: Int, length: Int
        let start: Clock
        let end: Clock?
        let zone: TimeZone?
        /// Whether the detector read a time here too, which keeps "John 3:16" from being one.
        let confirmed: Bool
    }

    struct Reader {
        let lines: [Line]
        let now: Date
        let local: TimeZone
        private(set) var days: [DayPiece] = []
        private(set) var clocks: [ClockPiece] = []
        private(set) var addresses: [(line: Int, text: String)] = []
        private(set) var links: [URL] = []
        private(set) var spans: [Int: [NSRange]] = [:]
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue
            | NSTextCheckingResult.CheckingType.address.rawValue | NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

        private static let venue = try! NSRegularExpression(pattern: #"(?:^|\bat\s+|\bin\s+|[,(]\s*)(\p{Lu}[\p{L}\p{N}'’&.\- ]{1,40}?),\s*$"#)

        init(lines: [Line], now: Date, local: TimeZone) {
            self.lines = lines; self.now = now; self.local = local
            for (index, line) in lines.enumerated() where !line.value.isEmpty { read(line, at: index) }
        }

        private mutating func read(_ line: Line, at index: Int) {
            let value = line.value, source = value as NSString, whole = NSRange(location: 0, length: source.length)
            let matches = detector?.matches(in: value, range: whole) ?? []
            var masked: [NSRange] = [], dated: [NSRange] = []
            for match in matches {
                switch match.resultType {
                case .link:
                    masked.append(match.range)
                    if let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") { links.append(url) }
                case .phoneNumber: masked.append(match.range)
                case .address:
                    if line.field == .none || line.field == .other {
                        // The place's name before its address: "at The Ivy, 1-5 West St", "City Dental, 22 High St".
                        var address = source.substring(with: match.range)
                        let before = source.substring(to: match.range.location) as NSString
                        if let name = Self.venue.firstMatch(in: before as String, range: NSRange(location: 0, length: before.length)) {
                            address = before.substring(with: name.range(at: 1)) + ", " + address
                        }
                        addresses.append((index, address))
                    }
                    masked.append(match.range)
                case .date:
                    dated.append(match.range)
                    spans[index, default: []].append(match.range)
                    guard line.field != .title, line.field != .location, line.field != .zone,
                          let piece = dayPiece(match, words: source.substring(with: match.range), line: index) else { continue }
                    days.append(piece)
                default: break
                }
            }
            guard line.field != .title, line.field != .location, line.field != .zone else { return }
            for piece in Times.clocks(in: value, masked: masked, dated: dated, temporal: line.field.isTemporal) {
                let confirmed = dated.contains { NSIntersectionRange($0, piece.range).length > 0 }
                let after = source.substring(from: NSMaxRange(piece.range))
                let detected = matches.first { $0.resultType == .date && NSIntersectionRange($0.range, piece.range).length > 0 }?.timeZone
                let zone = SelectionEvents.zone(at: after) ?? detected ?? piece.zone
                clocks.append(ClockPiece(line: index, location: piece.range.location, length: piece.range.length,
                                         start: piece.start, end: piece.end, zone: zone, confirmed: confirmed))
                spans[index, default: []].append(piece.range)
            }
        }

        /// The day a date the detector found names, if it names one: a month, a weekday, a date in
        /// numbers, or a word such as tomorrow, and not a bare time it put on today.
        private func dayPiece(_ match: NSTextCheckingResult, words: String, line: Int) -> DayPiece? {
            guard let date = match.date, Dates.namesDay(words) else { return nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = match.timeZone ?? local
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { return nil }
            var day = Day(year: year, month: month, day: dayNumber)
            let lower = words.lowercased()
            let hasYear = lower.range(of: #"\b(19|20)\d{2}\b|'\d{2}\b|\b\d{1,2}([/.\-])\d{1,2}\1\d{2,4}\b"#, options: .regularExpression) != nil
            let hasMonth = lower.range(of: "(?i)" + Dates.monthPattern, options: .regularExpression) != nil
            // A weekday written beside a date settles which year a date without one means:
            // "Tuesday, November 3" is 2026's. Written beside numbers alone, as "Fri 9-5", a
            // weekday that disagrees means it isn't a date at all.
            if let weekday = Dates.weekday(in: lower), lower.range(of: #"\b(today|tonight|tomorrow|yesterday|next|this|last)\b"#, options: .regularExpression) == nil {
                if Dates.weekday(of: day) != weekday {
                    guard hasMonth, !hasYear else { return nil }
                    let candidates = [day.year, day.year+1, day.year-1].map { Day(year: $0, month: day.month, day: day.day) }
                        .filter { Dates.weekday(of: $0) == weekday }
                    guard let best = candidates.min(by: { abs(Dates.date($0, in: local).timeIntervalSince(now)) < abs(Dates.date($1, in: local).timeIntervalSince(now)) })
                    else { return nil }
                    day = best
                }
            }
            // A range of days, as "November 3–5" or "Fri 6 Nov – Sun 8 Nov": all day, from one to the other.
            var last: Day?
            let hasClock = !Times.clocks(in: words, masked: [], dated: [NSRange(location: 0, length: (words as NSString).length)], temporal: true).isEmpty
            if match.duration >= 86400-1, !hasClock {
                let days = Int((match.duration/86400).rounded())
                var dayCalendar = Calendar(identifier: .gregorian); dayCalendar.timeZone = local
                if let end = dayCalendar.date(byAdding: .day, value: days, to: Dates.date(day, in: local)) {
                    let parts = dayCalendar.dateComponents([.year, .month, .day], from: end)
                    last = Day(year: parts.year!, month: parts.month!, day: parts.day!)
                }
            }
            return DayPiece(line: line, location: match.range.location, length: match.range.length, day: day, last: last, zone: match.timeZone,
                            detectedEnd: hasClock && match.duration > 0 && lower.range(of: #"[–—-]|\b(to|until|till|through|thru)\b"#, options: .regularExpression) != nil
                                ? date.addingTimeInterval(match.duration) : nil)
        }

        /// How much a line's place says about the event's time: its own label first, then an
        /// unlabelled line, then any other's.
        private func rank(_ line: Int) -> Int {
            switch lines[line].field {
            case .when, .start: return 0
            case .none: return 1
            case .other: return 2
            default: return 3
            }
        }

        func event(pageTitle: String?, notes: String) -> SelectionEvent? {
            let day = days.filter { lines[$0.line].field != .end }
                .min { (rank($0.line), $0.line, $0.location) < (rank($1.line), $1.line, $1.location) }
            let clock = chosenClock(near: day)
            guard day != nil || clock != nil else { return nil }
            // The end: the time's own range, or a line labelled as the end.
            let endLine = lines.indices.first { lines[$0].field == .end && !lines[$0].value.isEmpty }
            let endDay = endLine.flatMap { line in days.first { $0.line == line } }
            let endClock = clock?.end ?? endLine.flatMap { line in clocks.first { $0.line == line } }?.start

            var zone = clock?.zone ?? day?.zone ?? zoneField()
            if let written = zone, SelectionTimes.same(written, local, at: now) { zone = nil }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone ?? local

            var start: Date, end: Date, isAllDay = false, hasEnd = true
            if let clock {
                var first: Day
                if let day { first = day.day }
                else {
                    // A time without a day: today's, or tomorrow's once today's has been and gone.
                    let today = calendar.dateComponents([.year, .month, .day], from: now)
                    first = Day(year: today.year!, month: today.month!, day: today.day!)
                    let ends = Dates.date(first, clock.end ?? clock.start, in: calendar)
                        .addingTimeInterval(clock.end == nil ? 3600 : 0)
                    if ends < now, let next = calendar.date(byAdding: .day, value: 1, to: Dates.date(first, clock.start, in: calendar)) {
                        let parts = calendar.dateComponents([.year, .month, .day], from: next)
                        first = Day(year: parts.year!, month: parts.month!, day: parts.day!)
                    }
                }
                start = Dates.date(first, clock.start, in: calendar)
                if let endClock {
                    end = Dates.date(endDay?.day ?? first, endClock, in: calendar)
                    // "22:00 – 02:00" ends the next morning.
                    while !(start < end), let next = calendar.date(byAdding: .day, value: 1, to: end) { end = next }
                } else if let detected = day?.detectedEnd, clock.line == day?.line, detected > start {
                    end = detected
                } else if let last = day?.last ?? endDay?.day, last != first {
                    end = Dates.date(last, clock.start, in: calendar).addingTimeInterval(3600)
                } else { end = start.addingTimeInterval(3600); hasEnd = false }
            } else if let day {
                // A day without a time is all day, in whichever zone the person is in.
                var floating = Calendar(identifier: .gregorian); floating.timeZone = local
                isAllDay = true; zone = nil
                start = Dates.date(day.day, in: local)
                let last = day.last ?? endDay?.day ?? day.day
                end = floating.date(byAdding: .day, value: 1, to: Dates.date(last, in: local)) ?? start.addingTimeInterval(86400)
                if !(start < end) { end = floating.date(byAdding: .day, value: 1, to: start)! }
                hasEnd = day.last != nil || endDay != nil
            } else { return nil }
            // GMT for someone in London in winter: their own clock, so nothing to note.
            if let written = zone, written.secondsFromGMT(for: start) == local.secondsFromGMT(for: start),
               written.secondsFromGMT(for: end) == local.secondsFromGMT(for: end) { zone = nil }

            let meeting = links.first(where: Places.isMeeting)
            var location = locationField() ?? addresses.first?.text
            if location == nil, let meeting { location = meeting.absoluteString }
            let title = Titles.title(field: field(.title), lines: lines, spans: spans, pageTitle: pageTitle, location: location) ?? "New Event"
            return SelectionEvent(title: title, start: start, end: end, isAllDay: isAllDay, hasEnd: hasEnd, timeZone: zone,
                                  location: location, meetingURL: meeting, notes: notes)
        }

        /// The time the event starts at: on the day's own line, then on a line labelled with its
        /// time, then just below or above the day; and with no day, a time the detector read too.
        private func chosenClock(near day: DayPiece?) -> ClockPiece? {
            let candidates = clocks.filter { lines[$0.line].field != .end }
            guard let day else {
                return candidates.filter { $0.confirmed || lines[$0.line].field.isTemporal }
                    .min { (rank($0.line), $0.line, $0.location) < (rank($1.line), $1.line, $1.location) }
            }
            if let same = preferred(candidates.filter { $0.line == day.line }) { return same }
            if let labelled = candidates.first(where: { lines[$0.line].field.isTemporal }) {
                return preferred(candidates.filter { $0.line == labelled.line })
            }
            let below = candidates.filter { $0.line > day.line && $0.line - day.line <= nearbyLines && lines[$0.line].field != .other }
            if let next = below.first { return next }
            let above = candidates.last { $0.line < day.line && day.line - $0.line <= 2 && lines[$0.line].field == .none }
            return above.flatMap { above in candidates.first { $0.line == above.line } }
        }

        /// Of one moment written in several zones ("10:00 AM PT / 6:00 PM GMT"), the person's own; else the first.
        private func preferred(_ clocks: [ClockPiece]) -> ClockPiece? {
            clocks.first { clock in clock.zone.map { $0.secondsFromGMT(for: now) == local.secondsFromGMT(for: now) } ?? false } ?? clocks.first
        }

        private func field(_ field: Field) -> String? {
            let values = lines.filter { $0.field == field && !$0.value.isEmpty }.map(\.value)
            return values.isEmpty ? nil : values.joined(separator: ", ")
        }

        private func locationField() -> String? {
            // The first place labelled, with the lines under its label.
            guard let first = lines.firstIndex(where: { $0.field == .location && ($0.bareLabel || !$0.value.isEmpty) }) else { return nil }
            var parts: [String] = []
            for line in lines[first...] {
                guard line.field == .location else { break }
                if !line.value.isEmpty { parts.append(line.value) }
            }
            return Places.cleaned(parts.joined(separator: ", "))
        }

        private func zoneField() -> TimeZone? {
            field(.zone).flatMap { SelectionEvents.zone(at: $0) }
        }
    }

    // MARK: Zones

    /// Zones written as words, in Google Calendar's "(Greenwich Mean Time - London)" and elsewhere.
    static let namedZones: [String: String] = [
        "greenwich mean": "Europe/London", "british summer": "Europe/London", "british": "Europe/London", "uk": "Europe/London",
        "irish": "Europe/Dublin", "western european": "Europe/Lisbon", "central european": "Europe/Paris",
        "eastern european": "Europe/Athens", "eastern": "America/New_York", "central": "America/Chicago",
        "mountain": "America/Denver", "pacific": "America/Los_Angeles", "alaska": "America/Anchorage",
        "hawaii": "Pacific/Honolulu", "india": "Asia/Kolkata", "indian": "Asia/Kolkata", "japan": "Asia/Tokyo",
        "china": "Asia/Shanghai", "singapore": "Asia/Singapore", "australian eastern": "Australia/Sydney",
        "coordinated universal": "UTC", "universal": "UTC",
    ]

    /// A zone written at the start of `text`: as `SelectionTimes` reads one, or in words, such as
    /// "Pacific Time", "(Central European Summer Time)", "London time" or "(GMT) London".
    static func zone(at text: String) -> TimeZone? {
        if let zone = SelectionTimes.zone(at: text) {
            // "(GMT) London": a city after the offset is the place's, keeping its summer time.
            if let city = city(in: text), city.secondsFromGMT(for: Date()) == zone.secondsFromGMT(for: Date())
                || zone.identifier == "GMT" || zone.identifier == "UTC" { return city }
            return zone
        }
        if let city = city(in: text) { return city }
        let lower = text.lowercased()
        guard let match = lower.range(of: #"^\s*\(?\s*([a-z][a-z ]{1,40}?)\s+(?:standard |daylight |summer )?time\b"#, options: .regularExpression) else {
            return nil
        }
        var name = String(lower[match]).trimmingCharacters(in: CharacterSet(charactersIn: " ("))
        for suffix in [" time", " standard", " daylight", " summer"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        for suffix in [" standard", " daylight", " summer"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        if let identifier = namedZones[name] { return TimeZone(identifier: identifier) }
        return cityZone(name)
    }

    private static let cityPattern = try! NSRegularExpression(pattern: #"^[^\n]{0,40}?(?:\)\s*|\s[-–]\s)([A-Z][A-Za-z .]{2,30}?)\s*(?:\)|$|,|\n)"#)
    /// A city named in brackets or after a dash: "(GMT) London", "(Greenwich Mean Time - London)".
    private static func city(in text: String) -> TimeZone? {
        let source = text as NSString
        guard let match = cityPattern.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else { return nil }
        return cityZone(source.substring(with: match.range(at: 1)))
    }

    /// The zone of a city its identifier names, such as "London" or "New York".
    static func cityZone(_ name: String) -> TimeZone? {
        let key = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_").lowercased()
        guard key.count >= 3 else { return nil }
        let identifier = TimeZone.knownTimeZoneIdentifiers.first { $0.split(separator: "/").last?.lowercased() == key }
        return identifier.flatMap(TimeZone.init(identifier:))
    }

    // MARK: Labels and links

    /// How the event reads in a menu: "Tue 3 Nov, 13:30 – 20:30", "Tomorrow, 18:00", "Fri 6 – Sun 8 Nov",
    /// in the person's own zone.
    public static func label(_ event: SelectionEvent, now: Date = Date(), local: TimeZone = .current, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = local; calendar.locale = locale
        let sameYear = calendar.component(.year, from: event.start) == calendar.component(.year, from: now)
        func day(_ date: Date) -> String {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
            switch days {
            case 0: return "Today"
            case 1: return "Tomorrow"
            default:
                let format = DateFormatter(); format.locale = locale; format.timeZone = local
                format.setLocalizedDateFormatFromTemplate(sameYear ? "EEEdMMM" : "EEEdMMMy")
                return format.string(from: date)
            }
        }
        let clock = DateFormatter(); clock.locale = locale; clock.timeZone = local; clock.setLocalizedDateFormatFromTemplate("jmm")
        if event.isAllDay {
            let last = event.end.addingTimeInterval(-1)
            if calendar.isDate(event.start, inSameDayAs: last) { return day(event.start) }
            let range = DateIntervalFormatter(); range.locale = locale; range.timeZone = local
            range.dateTemplate = sameYear && calendar.component(.year, from: last) == calendar.component(.year, from: now) ? "EEEdMMM" : "EEEdMMMy"
            // Thin spaces around its dash, as the times' ranges aren't.
            return range.string(from: event.start, to: last).replacingOccurrences(of: "\u{2009}", with: " ")
        }
        let start = "\(day(event.start)), \(clock.string(from: event.start))"
        guard event.hasEnd else { return start }
        if calendar.isDate(event.start, inSameDayAs: event.end) { return "\(start) – \(clock.string(from: event.end))" }
        // Past midnight, but not into the next afternoon: the end's time alone reads as the night out.
        if event.end.timeIntervalSince(event.start) < 12*3600 { return "\(start) – \(clock.string(from: event.end))" }
        return "\(start) – \(day(event.end)), \(clock.string(from: event.end))"
    }

    /// Google Calendar's editor, filled in, in the account `base` is for (`calendar.google.com/calendar/u/1/`).
    public static func googleCalendarURL(_ event: SelectionEvent, base: URL? = nil, sourceURL: URL? = nil) -> URL {
        var parts = URLComponents(url: base ?? URL(string: "https://calendar.google.com/calendar/")!, resolvingAgainstBaseURL: false)!
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        parts.path += "r/eventedit"
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
        let dates: String
        if event.isAllDay {
            format.dateFormat = "yyyyMMdd"; format.timeZone = .current
            dates = format.string(from: event.start) + "/" + format.string(from: event.end)
        } else {
            format.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; format.timeZone = TimeZone(identifier: "UTC")
            dates = format.string(from: event.start) + "/" + format.string(from: event.end)
        }
        var details = event.notes
        if let sourceURL { details += "\n\n" + sourceURL.absoluteString }
        var items = parts.queryItems ?? []
        items += [URLQueryItem(name: "text", value: event.title), URLQueryItem(name: "dates", value: dates),
                  URLQueryItem(name: "details", value: details)]
        if let location = event.location { items.append(URLQueryItem(name: "location", value: location)) }
        if let zone = event.timeZone, !event.isAllDay { items.append(URLQueryItem(name: "ctz", value: zone.identifier)) }
        parts.queryItems = items
        // "+" reads as a space in a query.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    // MARK: Times

    struct Times {
        struct Found { let range: NSRange; let start: Clock; let end: Clock?; let zone: TimeZone? }
        struct Token {
            let range: NSRange
            let hour: Int, minute: Int
            /// 0 for am, 12 for pm.
            let meridiem: Int?
            /// Written with a colon, "h" or "hrs", or as noon or midnight: a time without question.
            let certain: Bool
            /// Written with a dot or an "h": a time beside a date, or in a time's field.
            let loose: Bool
            let bare: Bool
        }

        /// A clock: its whole, noon or midnight, the hour, a separator, minutes, and am or pm.
        private static let token = #"(\b(noon|midday|midnight)\b|(2[0-4]|[01]?\d)(?!\d)(?:\s?([:.h])\s?([0-5]\d)(?!\d))?(?::[0-5]\d)?(?:\s?(a\.\s?m\.?|p\.\s?m\.?|am\b|pm\b)|([ap])\b)?(?:\s?(?:hrs|hours|h)\b)?(?:\s?o['’]clock\b)?)"#
        static let groups = 7
        /// Not the end of a number, a price, or a date's digits.
        private static let lead = #"(?<![\p{N}:.,/$£€¥#+−\-])"#
        private static let military = try! NSRegularExpression(pattern: #"(?<![\p{N}:./-])([01]\d|2[0-3])([0-5]\d)\s?(?:hrs|hours|h)\b"#, options: .caseInsensitive)
        private static let single = try! NSRegularExpression(pattern: lead + token, options: .caseInsensitive)
        private static let range = try! NSRegularExpression(
            pattern: #"(?:\b(?:from|between)\s+)?"# + lead + token + #"\s*(?:-|–|—|~|\bto\b|\buntil\b|\btill\b|\btil\b|\bthrough\b|\bthru\b|\band\b)\s*"# + token,
            options: .caseInsensitive)

        /// Clocks and ranges of them in `text`. `masked` holds links, numbers and the like; `dated`
        /// what the detector read as dates or times; `temporal` whether the line is a time's field.
        static func clocks(in text: String, masked: [NSRange], dated: [NSRange], temporal: Bool) -> [Found] {
            let source = NSMutableString(string: text)
            for range in masked + Dates.numericDates(in: text) { source.replaceCharacters(in: range, with: String(repeating: " ", count: range.length)) }
            let text = source as String, whole = NSRange(location: 0, length: source.length)
            func inDate(_ range: NSRange) -> Bool { dated.contains { NSIntersectionRange($0, range).length > 0 } }
            func read(_ match: NSTextCheckingResult, from group: Int) -> Token? {
                func part(_ index: Int) -> String? {
                    let range = match.range(at: group+index)
                    return range.location == NSNotFound ? nil : source.substring(with: range)
                }
                let range = match.range(at: group)
                guard range.location != NSNotFound else { return nil }
                if let word = part(1)?.lowercased() {
                    return word == "midnight" ? Token(range: range, hour: 0, minute: 0, meridiem: 0, certain: true, loose: false, bare: false)
                        : Token(range: range, hour: 12, minute: 0, meridiem: 12, certain: true, loose: false, bare: false)
                }
                guard let hourText = part(2), let hour = Int(hourText) else { return nil }
                let separator = part(3), minute = part(4).flatMap(Int.init) ?? 0
                let marker = (part(5) ?? part(6))?.lowercased().filter { $0.isLetter }
                let meridiem = marker.map { $0.hasPrefix("p") ? 12 : 0 }
                let written = source.substring(with: range).lowercased()
                if meridiem != nil, hour == 0 || hour > 12 { return nil }
                if hour == 24, minute != 0 { return nil }
                // "7 o'clock" is a time; "19h" and "1900 hrs" are, beside a date.
                let oclock = written.range(of: #"o['’]clock$"#, options: .regularExpression) != nil
                let suffixed = separator == nil && written.range(of: #"\d\s?(hrs|hours|h)$"#, options: .regularExpression) != nil
                return Token(range: range, hour: hour, minute: minute, meridiem: meridiem, certain: separator == ":" || oclock,
                             loose: separator == "." || separator == "h" || suffixed,
                             bare: separator == nil && meridiem == nil && !oclock && !suffixed)
            }
            // A single clock stands on its own when it's surely one: written with a colon or am or pm,
            // or with a dot where the detector or the line's label says it's a time.
            func stands(_ token: Token) -> Bool {
                if token.meridiem != nil || token.certain && !token.loose { return true }
                if token.loose { return inDate(token.range) || temporal }
                return false
            }
            var found: [Found] = [], taken: [NSRange] = []
            func free(_ range: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, range).length > 0 } }
            for match in range.matches(in: text, range: whole) {
                guard var first = read(match, from: 1), var second = read(match, from: 1+groups) else { continue }
                // A bare number pairs with a clock: "11-1pm", "10am-2". Two bare numbers ("3–5") aren't times.
                guard stands(first) || stands(second), !(first.bare && second.bare) else { continue }
                if first.bare && first.hour > 12 || second.bare && second.hour > 12 { continue }
                let joined = source.substring(with: match.range).lowercased()
                if joined.range(of: #"\band\b"#, options: .regularExpression) != nil, !joined.hasPrefix("between") { continue }
                (first, second) = paired(first, second)
                let start = clock(first), end = clock(second)
                found.append(Found(range: match.range, start: start, end: end, zone: nil))
                taken.append(match.range)
            }
            for match in single.matches(in: text, range: whole) where free(match.range) {
                guard let token = read(match, from: 1) else { continue }
                if stands(token) { found.append(Found(range: token.range, start: clock(token), end: nil, zone: nil)); continue }
                // "at 5", "@ 8": a bare hour after "at", on a line the detector read a time on.
                if token.bare, token.hour >= 1, token.hour <= 12, inDate(token.range) {
                    let before = source.substring(to: token.range.location).lowercased()
                    if before.range(of: #"(\bat|@)\s*$"#, options: .regularExpression) != nil {
                        let evening = before.range(of: #"\b(tonight|evening)\b"#, options: .regularExpression) != nil
                        let hour = token.hour == 12 ? 12 : evening || token.hour <= 6 ? token.hour+12 : token.hour
                        found.append(Found(range: token.range, start: Clock(hour: hour, minute: 0), end: nil, zone: nil))
                    }
                }
            }
            for match in military.matches(in: text, range: whole) where free(match.range) {
                let hour = Int(source.substring(with: match.range(at: 1)))!, minute = Int(source.substring(with: match.range(at: 2)))!
                found.append(Found(range: match.range, start: Clock(hour: hour, minute: minute), end: nil, zone: nil))
            }
            return found.sorted { $0.range.location < $1.range.location }
        }

        /// A range's two ends with am or pm settled: "1:30-8:30pm" is the afternoon's, "11-1pm"
        /// the late morning's, "10am-2" ends at 2pm and "9-5" at 5pm.
        static func paired(_ first: Token, _ second: Token) -> (Token, Token) {
            func with(_ token: Token, _ meridiem: Int?) -> Token {
                Token(range: token.range, hour: token.hour, minute: token.minute, meridiem: meridiem, certain: token.certain, loose: token.loose, bare: token.bare)
            }
            var first = first, second = second
            if first.meridiem == nil, let meridiem = second.meridiem, first.hour <= 12 {
                first = with(first, meridiem)
                if minutes(clock(first)) > minutes(clock(second)) { first = with(first, meridiem == 12 ? 0 : 12) }
            } else if second.meridiem == nil, let meridiem = first.meridiem, second.hour <= 12 {
                second = with(second, meridiem)
                if minutes(clock(second)) <= minutes(clock(first)), meridiem == 0 { second = with(second, 12) }
            } else if first.meridiem == nil, second.meridiem == nil, second.hour < 12, second.hour < first.hour, first.hour < 12,
                      second.hour+12 > first.hour {
                // "9-5", "9:00-5:00": office hours, not an overnight.
                second = Token(range: second.range, hour: second.hour+12, minute: second.minute, meridiem: nil, certain: second.certain, loose: second.loose, bare: second.bare)
            }
            return (first, second)
        }

        static func clock(_ token: Token) -> Clock {
            guard let meridiem = token.meridiem else { return Clock(hour: token.hour % 24, minute: token.minute) }
            return Clock(hour: token.hour % 12 + meridiem, minute: token.minute)
        }
        static func minutes(_ clock: Clock) -> Int { clock.hour*60 + clock.minute }
    }

    // MARK: Dates

    enum Dates {
        static let monthPattern = #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)(?:\.|\b)"#
        static let weekdayPattern = #"\b(?:sun(?:day)?|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?)(?:\.|\b)"#
        private static let weekdays = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

        /// The weekday written in `text`, Sunday being 1.
        static func weekday(in text: String) -> Int? {
            guard let range = text.range(of: "(?i)" + weekdayPattern, options: .regularExpression) else { return nil }
            return weekdays.firstIndex(of: String(text[range].prefix(3)).lowercased()).map { $0+1 }
        }

        /// Whether the words name a day: a month, a weekday, a date in numbers, or a word such as tomorrow.
        static func namesDay(_ words: String) -> Bool {
            let pattern = "(?i)" + monthPattern + "|" + weekdayPattern
                + #"|\b(today|tonight|tomorrow|tmrw|yesterday)\b|\b\d{1,4}([/.\-])\d{1,2}\2\d{1,4}\b|\b\d{4}-\d{2}-\d{2}|\b\d{1,2}/\d{1,2}\b|\b\d{1,2}(st|nd|rd|th)\b"#
            return words.range(of: pattern, options: .regularExpression) != nil
        }

        static func weekday(of day: Day) -> Int {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
            return calendar.component(.weekday, from: date(day, in: TimeZone(identifier: "UTC")!))
        }

        static func date(_ day: Day, in zone: TimeZone) -> Date {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            return date(day, Clock(hour: 0, minute: 0), in: calendar)
        }

        static func date(_ day: Day, _ clock: Clock, in calendar: Calendar) -> Date {
            let parts = DateComponents(year: day.year, month: day.month, day: day.day, hour: clock.hour, minute: clock.minute)
            return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
        }

        /// Dates in numbers, years, ordinals and days beside a month, whose digits aren't clocks.
        static func numericDates(in text: String) -> [NSRange] {
            let source = text as NSString, whole = NSRange(location: 0, length: source.length)
            let patterns = [#"\b\d{1,4}([/.\-])\d{1,2}\1\d{1,4}\b"#, #"\b\d{4}-\d{2}-\d{2}(?=T|\b)"#, #"\b\d{1,2}/\d{1,2}\b"#,
                            #"\b(19|20)\d{2}\b(?!\s?(hrs|h\b|:))"#, #"\b\d{1,2}(st|nd|rd|th)\b"#,
                            #"(?i)"# + monthPattern + #"\s*\d{1,2}\b(?!\s*(:|\.\d|am|pm|a\.m|p\.m|h\d))(\s*[-–—]\s*\d{1,2}\b(?!\s*(:|\.\d|am|pm|a\.m|p\.m)))?"#,
                            #"(?i)\b\d{1,2}(\s*[-–—]\s*\d{1,2})?\s+(of\s+)?(?="# + monthPattern + ")"]
            return patterns.flatMap { pattern -> [NSRange] in
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
                return regex.matches(in: text, range: whole).map { match in
                    // A month's name stays readable; only its day's digits are masked.
                    let words = source.substring(with: match.range)
                    if let digits = words.range(of: #"\d.*$"#, options: .regularExpression), pattern.contains(monthPattern) {
                        let offset = words.distance(from: words.startIndex, to: digits.lowerBound)
                        let prefix = (String(words.prefix(offset)) as NSString).length
                        return NSRange(location: match.range.location+prefix, length: match.range.length-prefix)
                    }
                    return match.range
                }
            }
        }
    }

    // MARK: Places

    enum Places {
        static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                                   "whereby.com", "around.co", "meet.jit.si", "facetime.apple.com", "chime.aws", "gotomeeting.com",
                                   "bluejeans.com", "discord.gg", "app.gather.town", "riverside.fm", "streamyard.com", "hopin.com"]
        static func isMeeting(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return meetingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        }

        /// A place as written, without "(map)", "Get directions", or a placeholder for one.
        static func cleaned(_ text: String) -> String? {
            var place = text.replacingOccurrences(of: #"(?i)\s*[\(\[]?\b(view|show|open|see)\s+(on\s+)?(the\s+)?map\b[\)\]]?|\s*[\(\[]map[\)\]]|\s*[-–·|]?\s*get directions\b|\s*[-–·|]?\s*directions\b$"#,
                                                with: "", options: .regularExpression)
            place = place.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s*,(\s*,)+"#, with: ",", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,;·|-–—"))
            if place.isEmpty || place.range(of: #"(?i)^(tba|tbd|tbc|to be (announced|confirmed|decided)|n/?a|none)\.?$"#, options: .regularExpression) != nil { return nil }
            return place
        }
    }

    // MARK: Titles

    enum Titles {
        /// Headings that say what follows rather than what the event is.
        static let generic: Set<String> = ["event details", "details", "event information", "event info", "information", "info",
                                           "when", "where", "date", "time", "location", "venue", "schedule", "agenda", "program",
                                           "programme", "overview", "the details", "key details", "essential details", "save the date",
                                           "event", "events", "upcoming event", "upcoming events", "reminder", "your booking",
                                           "booking details", "reservation details", "ticket details", "your ticket", "your tickets",
                                           "add to calendar", "rsvp", "join us", "you're invited", "you’re invited", "invitation",
                                           "date and time", "date & time", "time and place", "meeting details", "summary",
                                           "description", "about", "about this event", "hosted by", "organizer", "organiser"]
        /// Sites and apps whose name a page's title ends with.
        static let sites: Set<String> = ["gmail", "inbox", "outlook", "mail", "proton mail", "protonmail", "fastmail", "yahoo mail",
                                         "icloud mail", "hey", "superhuman", "google calendar", "calendar", "outlook calendar",
                                         "eventbrite", "meetup", "luma", "lu.ma", "partiful", "facebook", "linkedin", "ticketmaster",
                                         "dice", "resident advisor", "ra", "zoom", "microsoft teams", "google meet", "eventbrite.com",
                                         "eventbrite.co.uk", "meetup.com", "posh", "tito", "universe", "see tickets", "skiddle",
                                         "songkick", "bandsintown", "x", "twitter", "slack", "notion", "google docs", "google chat",
                                         "messenger", "whatsapp", "discord", "calendly", "cal.com", "doodle", "opentable", "resy",
                                         "booking.com", "airbnb", "trainline", "google", "rise"]

        static func title(field: String?, lines: [Line], spans: [Int: [NSRange]], pageTitle: String?, location: String?) -> String? {
            if let field = field.map(tidy), usable(field) { return field }
            // What a sentence names: "seeing you next week at OpenAI DevDay Exchange: London", "invited to the Launch Party".
            let text = lines.map(\.value).joined(separator: "\n")
            if let match = named.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                let name = tidy((text as NSString).substring(with: match.range(at: 1)))
                if usable(name), !Dates.namesDay(name) { return name }
            }
            // A heading above the details, as "OpenAI DevDay\nTue 3 Nov, 13:30".
            for (index, line) in lines.enumerated() where !line.value.isEmpty {
                if spans[index]?.isEmpty == false || line.field.isTemporal { break }
                let value = line.value, words = value.split(separator: " ").count
                guard line.field == .none, usable(value), value != location, value.count <= 90, words <= 12,
                      !value.hasSuffix(":"), !value.hasSuffix(","),
                      value.range(of: #"[.!?]\s+\p{L}"#, options: .regularExpression) == nil,
                      !value.hasSuffix(".") || words <= 6 else { continue }
                return tidy(value)
            }
            // On a single line, what's left of it without its date, time and place: "Dinner with Sam".
            if let index = lines.indices.first(where: { spans[$0]?.isEmpty == false && lines[$0].field == .none }) {
                let rest = NSMutableString(string: lines[index].value)
                for range in merged(spans[index] ?? []).reversed() where NSMaxRange(range) <= rest.length {
                    rest.replaceCharacters(in: range, with: "\u{1}")
                }
                let pieces = (rest as String).components(separatedBy: "\u{1}").map(stripConnectors).map(tidy).filter(usable)
                if let best = pieces.first, best.count <= 80 { return best }
            }
            if let pageTitle, let page = fromPage(pageTitle) { return page }
            return location.flatMap { $0.split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } }
                .flatMap { $0.hasPrefix("http") ? nil : $0 }
        }

        private static let named = try! NSRegularExpression(pattern: #"(?:see(?:ing)? you|welcom(?:e|ing) you|join(?:ing)? us|invit(?:ed|ation)|register(?:ed)?|registration|tickets?|booked|booking|reservation|table|confirmed|rsvp(?:'d|’d)?|attend(?:ing)?|reminder)(?:\s+(?:again|soon|next week|next month|tomorrow|today|tonight|this \w+|next \w+|on \w+))?\s+(?:at|for|to|on)\s+(?:the\s+)?([\p{Lu}\p{N}][^\n.!?]{2,80}?)(?=\s*(?:[.!?\n]|$|\s+(?:is|are|was|has|have|will|starts|begins)\b|\s+on\s+|\s+at\s+\d|\s+from\s+|\s+in\s+\p{Lu}|,\s+(?:on|at|which|where|from)\b))"#, options: .caseInsensitive)

        /// Overlapping ranges as one, in order.
        static func merged(_ ranges: [NSRange]) -> [NSRange] {
            var result: [NSRange] = []
            for range in ranges.sorted(by: { $0.location < $1.location }) {
                if let last = result.last, range.location <= NSMaxRange(last) { result[result.count-1] = NSUnionRange(last, range) }
                else { result.append(range) }
            }
            return result
        }

        /// A page's title without its site, account and folder: Gmail's "Subject - me@x.com - Gmail" is the subject.
        static func fromPage(_ title: String) -> String? {
            var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
            let parts = title.components(separatedBy: CharacterSet(charactersIn: "|·•—–")).flatMap { $0.components(separatedBy: " - ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { part in
                    let lower = part.lowercased()
                    return !part.isEmpty && !sites.contains(lower) && lower.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) == nil
                        && lower.range(of: #"^(inbox|all mail|sent|starred|important|archive|drafts|spam|trash)\b"#, options: .regularExpression) == nil
                        && lower.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) == nil
                }
            guard var first = parts.first else { return nil }
            // A forwarded invitation's prefixes, and Google Calendar's "@ Tue 3 Nov…" and address.
            first = first.replacingOccurrences(of: #"(?i)^((re|fwd?|fw|aw|wg|tr|sv|vs)\s*:\s*|(updated |new |accepted|declined|tentative|canceled|cancelled)?\s*(invitation|event|reminder|accepted|declined)\s*(from google calendar)?\s*:\s*)+"#,
                                               with: "", options: .regularExpression)
            first = first.replacingOccurrences(of: #"\s+@\s+.*$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\([^()\s]+@[^()\s]+\)\s*$"#, with: "", options: .regularExpression)
            first = tidy(first)
            // A subject that's a sentence names its event as an invitation's does: "See you next week at OpenAI DevDay!"
            if let match = named.firstMatch(in: first, range: NSRange(location: 0, length: (first as NSString).length)) {
                let name = tidy((first as NSString).substring(with: match.range(at: 1)))
                if usable(name), !Dates.namesDay(name) { return name }
            }
            return usable(first) ? first : nil
        }

        static func usable(_ text: String) -> Bool {
            let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " :.!-–—·|"))
            guard lower.unicodeScalars.filter({ CharacterSet.letters.contains($0) }).count >= 2, !generic.contains(lower),
                  lower.range(of: #"^(hi|hello|hey|dear|greetings|good (morning|afternoon|evening)|thanks|thank you|cheers|best|regards)\b"#, options: .regularExpression) == nil
            else { return false }
            // Words that join a date to its event, not an event.
            return lower.range(of: #"^(on|at|from|to|until|and|the|by|for|in|starts?|ends?|doors( open)?|show|music|begins?|time|date|when|where|is|are|will be|it's|it’s|we're|we’re|updated|posted|published|edited|modified|sent|received)$"#, options: .regularExpression) == nil
        }

        /// What's left beside a date: "Dinner with Sam on" is "Dinner with Sam".
        static func stripConnectors(_ text: String) -> String {
            var text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:·|•-–—@()[]\t"))
            let connector = #"(?i)(^|\s+)(on|at|from|to|until|till|by|for|starting|starts|begins|is|are|was|were|this|next|every|each|between|and|,|-|–|—|@|·)\s*$"#
            while let range = text.range(of: connector, options: .regularExpression) {
                text.removeSubrange(range)
                text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:·|•-–—@()[]\t"))
            }
            while let range = text.range(of: #"(?i)^(on|at|from|is|starts|begins)\s+"#, options: .regularExpression) { text.removeSubrange(range) }
            return text
        }

        static func tidy(_ text: String) -> String {
            text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t,;:·|•-–—*#/\"“”"))
                // "our Autumn Mixer" is the Autumn Mixer.
                .replacingOccurrences(of: #"^(?i:our|my|your|their|his|her|this|a|an)\s+(?=\p{Lu})"#, with: "", options: .regularExpression)
        }
    }
}
