import Foundation

/// Dates, clock times, zones and the spans between them. A phrase is read as a starting moment —
/// "now", "christmas", "next friday 9am pst", "1767225600", "in 3 hours" — and a chain of steps in
/// any order: zone conversions, arithmetic, and output formats. Only the final moment is written out.
struct CalendarCalculation {
    typealias Place = CalculationZones.Place

    let now: Date
    let zone: TimeZone
    let twelveHour: Bool
    let monthFirst: Bool
    /// Exchange rates and the like, for a range of hours paid for: "9am to 5pm x 5 at £15/hr".
    private(set) var context: AddressCalculation.Context?

    init(_ context: AddressCalculation.Context) {
        self.init(now: context.now, zone: context.zone, twelveHour: context.twelveHour, monthFirst: context.monthFirst)
        self.context = context
    }

    init(now: Date, zone: TimeZone, twelveHour: Bool = false, monthFirst: Bool = false) {
        self.now = now; self.zone = zone; self.twelveHour = twelveHour; self.monthFirst = monthFirst
    }

    // MARK: - Values

    enum Output { case human, date, unix, unixMilliseconds, iso, weekday, weekNumber, dayOfYear }
    /// Which occurrence a date without a year, or a weekday, means: "until christmas" looks ahead,
    /// "since christmas" back.
    enum Preference { case upcoming, future, past }

    struct Moment {
        var date: Date
        var zone: TimeZone
        var label: String? = nil
        var hasTime: Bool
        var hasSeconds = false
        /// The day a clock time was written for, in the zone it was written in. A result on the day
        /// either side is written as a clock time with "next day", rather than in full.
        var anchor: DateComponents? = nil
        var anchorIsToday = false
        var output: Output = .human
        var places: [Place] = []
        var mentionsZone = false
        /// Worked out from words or steps, so worth showing on its own: "next friday", not "2026-11-27".
        var isDerived = false
        var twelveHour: Bool? = nil
    }

    /// A length of time, in the calendar's own units where they vary: a month, a day across a clock change.
    struct Span: Equatable {
        var months = 0, days = 0, businessDays = 0
        var seconds: Double = 0
        var terms = 0

        var hasCalendarPart: Bool { months != 0 || days != 0 || businessDays != 0 }
        var negated: Span { Span(months: -months, days: -days, businessDays: -businessDays, seconds: -seconds, terms: terms) }
        /// Seconds for a span of fixed length, days counting 24 hours.
        var fixedSeconds: Double? { months == 0 && businessDays == 0 ? Double(days)*86400+seconds : nil }

        enum Unit { case millisecond, second, minute, hour, day, week, fortnight, month, year, decade, businessDay }

        static func unit(_ word: String) -> Unit? {
            switch word {
            case "ms", "msec", "msecs", "millis", "millisecond", "milliseconds": .millisecond
            case "s", "sec", "secs", "second", "seconds": .second
            case "m", "min", "mins", "minute", "minutes": .minute
            case "h", "hr", "hrs", "hour", "hours": .hour
            case "d", "day", "days": .day
            case "w", "wk", "wks", "week", "weeks": .week
            case "fortnight", "fortnights": .fortnight
            case "mo", "mos", "month", "months": .month
            case "y", "yr", "yrs", "year", "years": .year
            case "decade", "decades": .decade
            default: word.hasPrefix("business") || word.hasPrefix("working") || word.hasPrefix("weekday") ? .businessDay : nil
            }
        }

        mutating func add(_ value: Double, _ unit: Unit) -> Bool {
            guard value.isFinite, abs(value) <= 10_000_000 else { return false }
            switch unit {
            case .millisecond: seconds += value/1000
            case .second: seconds += value
            case .minute: seconds += value*60
            case .hour: seconds += value*3600
            case .day, .week, .fortnight:
                let total = value*(unit == .day ? 1 : unit == .week ? 7 : 14)
                let whole = total.rounded(.towardZero)
                guard abs(whole) <= 4_000_000 else { return false }
                days += Int(whole); seconds += (total-whole)*86400
            case .month, .year, .decade:
                let total = value*(unit == .month ? 1 : unit == .year ? 12 : 120)
                guard total == total.rounded(), abs(total) <= 120_000 else { return false }
                months += Int(total)
            case .businessDay:
                guard value == value.rounded() else { return false }
                businessDays += Int(value)
            }
            return true
        }
    }

    // MARK: - Patterns

    static let clockPattern = #"noon|midday|midnight|(?:[01]?\d|2[0-3])(?:[:.][0-5]\d(?::[0-5]\d)?)? ?[ap]m|(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?"#
    /// A number, or a number's word, which a space parts from its unit: "2h", "2 hours", "an hour".
    static let amountPattern = #"(\d+(?:\.\d+)?|\.\d+) ?|(half an?|a couple of|couple of|an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|sixty|ninety|hundred) "#
    static let unitPattern = #"business days?|working days?|weekdays?|milliseconds?|millis|msecs?|ms|seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|wks?|fortnights?|months?|mos?|years?|yrs?|decades?|s|m|h|d|w|y"#
    private static let amountWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "ninety": 90, "hundred": 100, "half a": 0.5, "half an": 0.5, "a couple of": 2, "couple of": 2
    ]
    static let weekdayPattern = #"monday|mon|tuesday|tues|tue|wednesday|weds|wed|thursday|thurs|thur|thu|friday|fri|saturday|sat|sunday|sun"#
    static let monthPattern = #"january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sept|sep|october|oct|november|nov|december|dec"#
    static let holidayPattern = #"christmas eve|christmas(?: day)?|xmas(?: day| eve)?|boxing day|new year'?s eve|nye|new year'?s(?: day)?|new year|halloween|valentine'?s(?: day)?|st\.? patrick'?s(?: day)?|st\.? paddy'?s(?: day)?|april fools'?(?: day)?|independence day|(?:the )?(?:4th|fourth) of july|bonfire night|guy fawkes(?: night| day)?|easter(?: sunday)?|good friday|easter monday|pancake day|shrove tuesday|ash wednesday|thanksgiving(?: day)?|black friday|cyber monday|father'?s day|memorial day|labou?r day|leap day"#
    private static let connector = #"(?:then )?(?:to|in|as|into)|then|,"#
    /// Where a step's words end: at the next step, or the end.
    private static let stepEnd = #"(?= (?:then )?(?:to|in|as|into) | then |, | (?:on|at) |\s(?:plus|minus|add|subtract|less|\+|-) ?(?:\d|an? |half|\.|\()|$)"#
    private static let formats = #"unix(?: epoch)?(?: time| timestamp)?(?: in)? (?:ms|millis|milliseconds)|(?:epoch|posix) (?:ms|millis|milliseconds)|ms|milliseconds|(?:unix|epoch|posix)(?: epoch)?(?: time| timestamp| seconds| secs)?|timestamp|iso(?: ?8601)?(?: format| date| time| string)?|rfc ?3339|human(?:[- ]readable)?(?: date| time| format)?|readable(?: date| time)?|date(?: and time)?|datetime|day of (?:the )?week|weekday|(?:iso )?week(?: number)?|day of (?:the )?year|12[- ]?h(?:our)?(?: time| clock| format)?|am/pm|24[- ]?h(?:our)?(?: time| clock| format)?|military(?: time)?"#

    // MARK: - Questions

    func evaluate(_ query: String) -> String? {
        let questions: [(String) -> String?] = [currentTime, zoneDifference, todayQuestion, countdown, range, age, weekdayOf,
                                                weekDates, clockRange, expression, namedFormat]
        for question in questions {
            if let answer = question(query) { return answer }
        }
        return nil
    }

    /// "time in tokyo", "tokyo time", "what time is it in new york", "current time".
    private func currentTime(_ query: String) -> String? {
        let asks = #"(?:what time is it|what's the time|whats the time|what is the time|the time|current time|time now|time right now|local time|current local time|time)"#
        // "date in tokyo", "what day is it in sydney": today there.
        if let match = AddressCalculation.groups(#"^(?:(?:the |current |today'?s )?date|what(?:'s| is) the date|what day is it|which day is it|what day) (?:now |today )?(?:in|at|for) (.+?)(?: now| today)?$"#, in: query) {
            guard let place = CalculationZones.place(match[1], local: zone) else { return nil }
            return weekdayText(now, place.zone)
        }
        var placeName: String?
        if let match = AddressCalculation.groups("^" + asks + #"(?: now| right now)?(?: (?:in|at|for) (.+?))?(?: now| right now)?$"#, in: query) {
            guard !match[1].isEmpty || query != "time" else { return nil }
            placeName = match[1].isEmpty ? nil : match[1]
        } else if let match = AddressCalculation.groups(#"^(?:current |local )?(.+?) (?:local )?time(?: now| right now)?$"#, in: query) {
            placeName = match[1]
        } else { return nil }
        var moment = Moment(date: now, zone: zone, hasTime: true)
        moment.anchor = calendar(zone).dateComponents([.year, .month, .day], from: now)
        moment.anchorIsToday = true
        if let placeName {
            guard let place = CalculationZones.place(placeName, local: zone) else { return nil }
            moment.zone = place.zone; moment.label = place.label; moment.mentionsZone = true
        }
        return format(moment)
    }

    /// "time difference between london and tokyo", "tokyo time difference", "how far ahead is tokyo".
    private func zoneDifference(_ query: String) -> String? {
        let words = #"(?:time difference|time zone difference|timezone difference|time diff|difference in time|hours? difference|time gap)"#
        let pair: String
        if let match = AddressCalculation.groups("^" + words + #"(?: between| from| for| with| in| to)? (.+)$"#, in: query) { pair = match[1] }
        else if let match = AddressCalculation.groups("^(.+) " + words + "$", in: query) { pair = match[1] }
        else if let match = AddressCalculation.groups(#"^how (?:many hours|far) (?:ahead|behind) is (.+?)(?: (?:of|from|than) (.+))?$"#, in: query) {
            pair = match[2].isEmpty ? match[1] : match[1]+" and "+match[2]
        } else { return nil }
        var places: [Place]?
        for separator in [" and ", " to ", " vs ", " versus ", " from ", " & ", " - ", ", "] {
            for (left, right) in splits(pair, around: separator) {
                if let first = CalculationZones.place(left, local: zone), let second = CalculationZones.place(right, local: zone) {
                    places = [first, second]; break
                }
            }
            if places != nil { break }
        }
        if places == nil, let single = CalculationZones.place(pair, local: zone) {
            places = [single, Place(zone: zone, label: nil, name: CalculationZones.localName(zone))]
        }
        guard let places else { return nil }
        let difference = places[0].zone.secondsFromGMT(for: now)-places[1].zone.secondsFromGMT(for: now)
        guard difference != 0 else { return "Same time in \(places[0].name) and \(places[1].name)" }
        let (ahead, behind) = difference > 0 ? (places[0], places[1]) : (places[1], places[0])
        return "\(ahead.name) is \(Self.hoursText(abs(difference))) ahead of \(behind.name)"
    }

    /// Today's date, week number, day of the year, and leap years.
    private func todayQuestion(_ query: String) -> String? {
        let cal = calendar(zone)
        let dayAsk = #"^(?:(?:today|tomorrow|yesterday)'?s date|(?:today|tomorrow|yesterday) date|date (?:today|tomorrow|yesterday)|the date(?: today| tomorrow| yesterday)?|current date|date now|todays date|tomorrows date|yesterdays date|what day is it(?: today)?|which day is it(?: today)?|what day (?:is|was) (?:today|tomorrow|yesterday)|what's today|whats today|what is today|today is what day|what's the date(?: today| tomorrow)?|what is the date(?: today| tomorrow)?)$"#
        if AddressCalculation.groups(dayAsk, in: query) != nil {
            let offset = query.contains("tomorrow") ? 1 : query.contains("yesterday") ? -1 : 0
            guard let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)) else { return nil }
            return weekdayText(day, zone)
        }
        if AddressCalculation.groups(#"^(?:what week is (?:it|this)|which week is it|(?:the |current |this )?(?:iso |calendar )?week number(?: today| now| is it)?|(?:current|iso|calendar) week|what(?:'s| is) the week(?: number)?|what week of the year is it|week of (?:the )?year)$"#, in: query) != nil {
            var iso = Calendar(identifier: .iso8601); iso.timeZone = zone
            return "Week \(iso.component(.weekOfYear, from: now))"
        }
        if AddressCalculation.groups(#"^(?:current |the )?(?:unix|epoch|posix)(?: epoch)?(?: time| timestamp| seconds)?(?: now| right now)?$|^(?:current |unix )?timestamp(?: now)?$"#, in: query) != nil {
            return "\(Int64(now.timeIntervalSince1970.rounded(.down))) Unix seconds"
        }
        if AddressCalculation.groups(#"^(?:what )?day of (?:the )?year(?: is it| is today| today)?$|^what day of the year is it$"#, in: query) != nil {
            return dayOfYearText(now, zone)
        }
        if let match = AddressCalculation.groups(#"^(?:is )?(\d{4}) (?:a )?leap year$|^leap year (\d{4})$|^is (?:it|this year) a leap year$|^(next|last|previous) leap year$|^when is the next leap year$"#, in: query) {
            let thisYear = cal.component(.year, from: now)
            if !match[3].isEmpty || query.hasPrefix("when") {
                var year = thisYear+(match[3] == "next" || query.hasPrefix("when") ? 1 : -1)
                while !Self.isLeap(year) { year += match[3] == "next" || query.hasPrefix("when") ? 1 : -1 }
                return "\(year)"
            }
            let year = Int(match[1]) ?? Int(match[2]) ?? thisYear
            return Self.isLeap(year) ? "\(year) is a leap year" : "\(year) isn't a leap year"
        }
        // "days in february" (the coming one, and the next leap year's), "days in 2028", "days this month"
        if let match = AddressCalculation.groups(#"^(?:how many )?days (?:are )?(?:there )?(?:in|this) (?:the month of |a |the )?(?:(this|next|last) )?(month|year|"# + Self.monthPattern + #")(?:,? (\d{4}))?(?: have| has)?$|^(?:how many )?days (?:are )?(?:there )?in (\d{4})$|^(?:how many )?days (?:does|in) (?:(this|next|last) )?(month|year|"# + Self.monthPattern + #")(?:,? (\d{4}))? (?:have|has)$"#, in: query) {
            let which = match[1].isEmpty ? match[5] : match[1]
            let period = match[2].isEmpty ? match[6] : match[2]
            let year = Int(match[3]) ?? Int(match[4]) ?? Int(match[7])
            let current = cal.dateComponents([.year, .month], from: now)
            guard let thisYear = current.year, let thisMonth = current.month else { return nil }
            let shift = which == "next" ? 1 : which == "last" ? -1 : 0
            func days(_ year: Int, _ month: Int) -> Int? {
                cal.date(from: DateComponents(year: year, month: month, day: 1)).flatMap { cal.range(of: .day, in: .month, for: $0)?.count }
            }
            if period.isEmpty || period == "year" {
                let year = year ?? thisYear+shift
                return Self.quantity(Self.isLeap(year) ? 366 : 365, "day")
            }
            if period == "month" {
                let total = thisYear*12+thisMonth-1+shift
                return days(total/12, total%12+1).map { Self.quantity($0, "day") }
            }
            guard let month = Self.monthNumber(period) else { return nil }
            // Without a year: this year's month until it's over, then next year's.
            let resolved = year ?? (month >= thisMonth ? thisYear : thisYear+1)
            guard let count = days(resolved, month) else { return nil }
            if month == 2, year == nil {
                var leap = resolved
                while !Self.isLeap(leap) { leap += 1 }
                if leap != resolved { return Self.quantity(count, "day") + " · 29 in \(leap)" }
            }
            return Self.quantity(count, "day")
        }
        if let match = AddressCalculation.groups(#"^(?:how many )?days (?:are )?(?:left|remaining) (?:in|of|until the end of) (?:the |this )?(year|month|week|\d{4})$"#, in: query) {
            let today = cal.startOfDay(for: now)
            let end: Date?
            switch match[1] {
            case "month": end = cal.dateInterval(of: .month, for: today).flatMap { cal.date(byAdding: .day, value: -1, to: $0.end) }
            case "week": end = endOfISOWeek(today, cal)
            case "year": end = cal.dateInterval(of: .year, for: today).flatMap { cal.date(byAdding: .day, value: -1, to: $0.end) }
            default:
                guard let year = Int(match[1]), year == cal.component(.year, from: now) else { return nil }
                end = cal.date(from: DateComponents(year: year, month: 12, day: 31))
            }
            guard let end, let days = cal.dateComponents([.day], from: today, to: end).day else { return nil }
            return Self.quantity(days, "day")
        }
        return nil
    }

    /// "days until christmas", "how long until 5pm", "hours since 9am", "weeks until 2027-06-01".
    private func countdown(_ query: String) -> String? {
        let unit: String, direction: String, target: String
        if let match = AddressCalculation.groups(#"^(?:how many |number of |the number of )?(seconds|minutes|hours|days|weeks|months|years|business days|working days|weekdays|sleeps|nights)(?: left| remaining| is it| are there| are left| has it been| have passed| to go)? (until|till|til|to|before|since|after) (?:the )?(.+)$"#, in: query) {
            (unit, direction, target) = (match[1], match[2], match[3])
        } else if let match = AddressCalculation.groups(#"^(?:how long|time|time left|time remaining|how much time|countdown|how long is it|how long has it been|how much longer)(?: is it| is there| is left| left| remains| has it been)? (until|till|til|to|before|since) (?:the )?(.+)$"#, in: query) {
            (unit, direction, target) = ("", match[1], match[2])
        } else if let match = AddressCalculation.groups(#"^how long ago (?:was|is|did) (.+)$"#, in: query) {
            (unit, direction, target) = ("", "since", match[1])
        } else { return nil }
        let looksBack = direction == "since" || direction == "after"
        guard let moment = moment(target, prefer: looksBack ? .past : .future) else { return nil }
        // To a day, count days; to a time, hours and minutes.
        let start = Moment(date: now, zone: zone, hasTime: moment.hasTime)
        let text = spanText(from: start, to: moment, unit: unit)
        let forward = moment.date >= now
        guard let text else { return nil }
        if text == "0 days" || text == "0 sleeps" || text == "0 nights" { return "Today" }
        if looksBack { return forward ? "in " + text : text }
        return forward ? text : text + " ago"
    }

    /// "days between 2026-01-01 and christmas", "from monday to friday", "christmas to new year".
    private func range(_ query: String) -> String? {
        var unit = "", body = query, separators = [" and "]
        if let match = AddressCalculation.groups(#"^(?:(?:how many )?(seconds|minutes|hours|days|weeks|months|years|business days|working days|weekdays|nights|time|duration|elapsed time|difference|how long|the difference)(?: is it| are there)? )?(between|from) (.+)$"#, in: query) {
            unit = match[1]
            body = match[3]
            separators = match[2] == "between" ? [" and ", " & "] : [" to ", " until ", " till ", " - "]
            if ["time", "duration", "elapsed time", "difference", "how long", "the difference"].contains(unit) { unit = "" }
        } else {
            separators = [" to ", " until ", " - "]
            // "christmas - today in hours"
            if let match = AddressCalculation.groups(#"^(.+) (?:in|to|as) (seconds|minutes|hours|days|weeks|months|years|business days|working days|weekdays)$"#, in: query) {
                body = match[1]; unit = match[2]
            }
        }
        for separator in separators {
            for (left, right) in splits(body, around: separator) {
                guard let first = moment(left), var second = moment(right),
                      // Clock times alone are a working day's range, read with am/pm sense below.
                      !(isBareClock(left) && isBareClock(right)) else { continue }
                // A day that comes round again is the next one after the first: "between 1 jan and
                // christmas" is the Christmas after that January, "friday to monday" three days. A day
                // that doesn't, as in "christmas - today", stays put.
                if first.date > second.date, moment(right, prefer: .past)?.date != moment(right, prefer: .future)?.date,
                   let later = CalendarCalculation(now: first.date, zone: zone, twelveHour: twelveHour, monthFirst: monthFirst).moment(right),
                   later.date >= first.date { second = later }
                let ordered = first.date <= second.date ? (first, second) : (second, first)
                return spanText(from: ordered.0, to: ordered.1, unit: unit)
            }
        }
        return nil
    }

    /// "age born 1990-05-12", "how old is someone born 12 may 1990", "born in 1990".
    private func age(_ query: String) -> String? {
        guard let match = AddressCalculation.groups(#"^(?:age|how old(?: am i| is someone| is a person| are you| would i be| is he| is she| are they| is one)?)(?: (?:if|when|of someone|of a person|for someone|of somebody))?(?: (?:i was|you were|someone was|they were|he was|she was|they're|i'm))? born(?: on| in)? (.+)$|^(?:age|how old)(?: for| of| on| from)? (.+)$|^born(?: on| in)? (.+?)(?: (?:age|how old(?: am i| is that| would i be)?))?$|^(.+?) (?:birthday|birth date|date of birth|dob) (?:age|how old)$"#, in: query),
              let written = match.dropFirst().first(where: { !$0.isEmpty }) else { return nil }
        let cal = calendar(zone)
        let today = cal.startOfDay(for: now)
        if let year = Int(written), (1000...9999).contains(year) {
            let current = cal.component(.year, from: now)
            guard year < current else { return nil }
            return "\(current-year-1) or \(current-year) years old"
        }
        guard let birth = moment(written, prefer: .past), birth.date <= now else { return nil }
        let parts = cal.dateComponents([.year, .month, .day], from: cal.startOfDay(for: birth.date), to: today)
        if let years = parts.year, years >= 1 { return Self.quantity(years, "year")+" old" }
        if let months = parts.month, months >= 1 { return Self.quantity(months, "month")+" old" }
        return Self.quantity(parts.day ?? 0, "day")+" old"
    }

    /// "what day is christmas", "day of week 2027-01-01", "1990-05-12 weekday".
    private func weekdayOf(_ query: String) -> String? {
        guard let match = AddressCalculation.groups(#"^(?:what|which) day(?: of the week)? (?:is|was|will be|does|did|falls on|is it on|will) (.+?)(?: (?:on|fall on|land on|fall|be))?$|^(?:day of (?:the )?week|weekday)(?: (?:for|of|on|is))? (.+)$|^(.+?) (?:day of (?:the )?week|weekday)$"#, in: query),
              let written = match.dropFirst().first(where: { !$0.isEmpty }),
              !["it", "it today", "today", "tomorrow", "yesterday"].contains(written),
              let moment = moment(written) else { return nil }
        return weekdayText(moment.date, moment.zone)
    }

    /// "christmas week number", "2026-12-25 day of year": a format named after a moment, without "to".
    private func namedFormat(_ query: String) -> String? {
        guard let match = AddressCalculation.groups(#"^(.+?) (?:to |in |as )?(?:the )?((?:iso |calendar )?week(?: number)?|day of (?:the )?year|unix(?: time| timestamp)?|iso(?: 8601)?)$"#, in: query),
              var moment = moment(match[1]) else { return nil }
        moment.output = match[2].contains("week") ? .weekNumber : match[2].contains("year") ? .dayOfYear : match[2].hasPrefix("unix") ? .unix : .iso
        return format(moment)
    }

    /// "week 48 2026", "calendar week 48", "iso week 12 of 2027": the week's Monday to Sunday.
    private func weekDates(_ query: String) -> String? {
        guard let match = AddressCalculation.groups(#"^(?:(iso |calendar )?week(?: number)?|kw|cw) (\d{1,2})(?:,? (?:of |in )?(\d{4}))?$"#, in: query),
              let week = Int(match[2]), (1...53).contains(week),
              !match[1].isEmpty || !match[3].isEmpty || query.hasPrefix("kw") || query.hasPrefix("cw") || query.hasPrefix("week number") else { return nil }
        var iso = Calendar(identifier: .iso8601); iso.timeZone = zone
        let year = Int(match[3]) ?? iso.component(.yearForWeekOfYear, from: now)
        guard let monday = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year)),
              iso.component(.weekOfYear, from: monday) == week,
              let sunday = iso.date(byAdding: .day, value: 6, to: monday) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone
        formatter.dateFormat = "EEE d MMM"
        let first = formatter.string(from: monday)
        formatter.dateFormat = "EEE d MMM yyyy"
        return "\(first) – \(formatter.string(from: sunday))"
    }

    /// "3:45 pm to 7:10 pm", "from 9am to 5:30pm minus 30 min", "9am-5pm x 5": how long between two
    /// clock times, past midnight when the second is earlier.
    private func clockRange(_ query: String) -> String? {
        let clock = Self.clockPattern + #"|(?:[01]?\d|2[0-3])"#
        guard let match = AddressCalculation.groups(#"^(?:(elapsed time|time|how long|duration|hours|how many hours|minutes|how many minutes|seconds)(?: is it)? )?(?:(from|between) )?("# + clock + #")(?: (?:to|until|till)|( and)| ?-) ?("# + clock + #")(.*)$"#, in: query),
              match[4].isEmpty || match[2] == "between",
              let (seconds, wraps) = clockRangeSeconds(match[3], match[5]) else { return nil }
        let nextDay = wraps ? " · next day" : ""
        let unit = match[1].contains("hours") ? "hours" : match[1].contains("minutes") ? "minutes" : match[1] == "seconds" ? "seconds" : ""
        guard let text = QuantityExpression.continueDuration(seconds, with: match[6], unit: unit, context: context) else { return nil }
        return text + (match[6].isEmpty ? nextDay : "")
    }

    /// How long a range lasts, for arithmetic on it: "9am to 5pm", "between monday and friday".
    func rangeSeconds(_ text: String) -> Double? {
        let clock = Self.clockPattern + #"|(?:[01]?\d|2[0-3])"#
        if let match = AddressCalculation.groups(#"^(?:from |between )?("# + clock + #")(?: (?:to|until|till|and)| ?-) ?("# + clock + #")$"#, in: text),
           let range = clockRangeSeconds(match[1], match[2]) { return range.seconds }
        var body = text
        if let match = AddressCalculation.groups(#"^(?:between|from) (.+)$"#, in: text) { body = match[1] }
        for separator in [" to ", " until ", " and ", " - "] {
            for (left, right) in splits(body, around: separator) {
                if let first = moment(left), let second = moment(right) { return abs(second.date.timeIntervalSince(first.date)) }
            }
        }
        return nil
    }

    /// From one clock time to the next, past midnight when the second is earlier. One written without
    /// am or pm takes the half of the day that makes the range shorter: "11:30 to 1 pm".
    private func clockRangeSeconds(_ firstText: String, _ secondText: String) -> (seconds: Double, nextDay: Bool)? {
        guard let first = Self.clockSeconds(firstText), let second = Self.clockSeconds(secondText),
              [firstText, secondText].contains(where: { $0.contains(":") || Self.isMarkedClock($0) }) else { return nil }
        var start = first.seconds, end = second.seconds
        let firstMarked = Self.isMarkedClock(firstText), secondMarked = Self.isMarkedClock(secondText)
        if firstMarked != secondMarked, (end-start+86400)%86400 >= 43200 {
            if !firstMarked, start < 43200 { start += 43200 }
            if !secondMarked, end < 43200 { end += 43200 }
        }
        return (Double((end-start+86400)%86400), end < start)
    }

    /// A moment and its steps: "christmas 9am pst to tokyo", "today to unix + 4 days", "next friday".
    private func expression(_ query: String) -> String? {
        var asked = false
        var found: Moment?
        // "when is easter", "christmas 2027 date": the date, even of a day named outright.
        if let match = AddressCalculation.groups(#"^(?:when is|when's|whens|when was|what date is|what date was|date of|the date of)(?: the)? (.+)$|^(.+) date$"#, in: query) {
            found = moment(match[1].isEmpty ? match[2] : match[1])
            asked = found != nil
        }
        guard var moment = found ?? moment(query) else { return nil }
        if !asked && !moment.isDerived {
            // A clock time in another place, alone, is that time here.
            guard moment.mentionsZone, moment.places.isEmpty, moment.anchor != nil,
                  moment.zone.secondsFromGMT(for: moment.date) != zone.secondsFromGMT(for: moment.date) else { return nil }
            moment.places = [Place(zone: zone, label: nil, name: CalculationZones.localName(zone))]
            moment.zone = zone; moment.label = nil
        }
        return format(moment)
    }

    // MARK: - Reading moments

    /// The moment `text` names, with its steps, read whole.
    func moment(_ text: String, prefer: Preference = .upcoming) -> Moment? {
        // "3 days after christmas", "2 hours before 9am", "45 days from today", "4 days from now to unix"
        for word in [" from ", " after ", " before ", " past ", " since "] {
            for (left, right) in splits(text, around: word) {
                var spanCursor = Cursor(left)
                guard let span = Self.span(&spanCursor), spanCursor.isAtEnd,
                      var base = moment(right, prefer: prefer),
                      let moved = applying(word == " before " ? span.negated : span, to: base) else { continue }
                base = moved
                base.isDerived = true
                return base
            }
        }
        var cursor = Cursor(text)
        var start: Moment
        // "in 3 hours", "3 days ago", "half an hour ago"
        var ahead = cursor, ago = cursor
        if ahead.take("in ") != nil, let span = Self.span(&ahead), let moved = relative(span) {
            start = moved; cursor = ahead
        } else if let span = Self.span(&ago), ago.take(" ago") != nil {
            guard let moved = relative(span.negated) else { return nil }
            start = moved; cursor = ago
        } else {
            guard let base = base(&cursor, prefer: prefer) else { return nil }
            start = base
        }
        guard steps(&cursor, &start), cursor.isAtEnd else { return nil }
        return start
    }

    /// Now moved by `span`, written as a date when the span is whole days.
    private func relative(_ span: Span) -> Moment? {
        var base = Moment(date: now, zone: zone, hasTime: true)
        base.anchor = calendar(zone).dateComponents([.year, .month, .day], from: now)
        base.anchorIsToday = true
        guard var moved = applying(span, to: base) else { return nil }
        if span.seconds == 0 { moved.hasTime = false }
        moved.isDerived = true
        return moved
    }

    private func base(_ c: inout Cursor, prefer: Preference) -> Moment? {
        let cal = calendar(zone)
        // Unix timestamps: "unix 1767225600", "@1767225600", "1767225600 to date", "1767225600000"
        if let match = c.take(#"(?:(?:unix|posix|epoch)(?: timestamp| time| epoch| seconds)?|timestamp) (-?\d{1,13})(?!\d)|@(-?\d{1,13})(?!\d)|(-?\d{9,13})(?: (?:unix|epoch|posix)(?: time| timestamp| seconds)?)?(?![\d.])|(-?\d{1,8})(?= (?:to|as|in) (?:a )?date\b)"#),
           let digits = match.dropFirst().first(where: { !$0.isEmpty }), let value = Double(digits) {
            let milliseconds = digits.filter(\.isNumber).count >= 12
            let seconds = milliseconds ? value/1000 : value
            var moment = Moment(date: Date(timeIntervalSince1970: seconds), zone: CalculationZones.utc, label: "UTC", hasTime: true,
                                hasSeconds: seconds.truncatingRemainder(dividingBy: 60) != 0)
            moment.mentionsZone = true
            // "unix 1767225600" asks for a date; a bare number needs a step to be one.
            moment.isDerived = match[3].isEmpty || match[0] != match[3]
            return moment
        }
        // ISO 8601: "2026-01-01t09:30:00z", "2026-01-01t09:30+02:00"
        if let match = c.take(#"(\d{4})-(\d{2})-(\d{2})t(\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?(z|[+-]\d{2}(?::?\d{2})?)?(?![\da-z])"#),
           let year = Int(match[1]), let month = Int(match[2]), let day = Int(match[3]),
           let hour = Int(match[4]), let minute = Int(match[5]), hour < 24, minute < 60 {
            let second = Int(match[6]) ?? 0
            let day = DateComponents(year: year, month: month, day: day)
            guard Self.valid(day) else { return nil }
            var place: Place?
            if !match[7].isEmpty {
                let offset = match[7] == "z" ? "utc" : "utc" + match[7]
                place = CalculationZones.place(offset, local: zone)
                guard place != nil else { return nil }
            }
            var moment = clockMoment(day: day, seconds: hour*3600+minute*60+second, hasSeconds: !match[6].isEmpty, place: place, prefer: .upcoming)
            moment?.anchor = nil
            return moment
        }
        if c.take(#"(?:right )?now(?![a-z])"#) != nil {
            var moment = Moment(date: now, zone: zone, hasTime: true)
            moment.anchor = cal.dateComponents([.year, .month, .day], from: now)
            moment.anchorIsToday = true
            return moment
        }
        // A day, then perhaps a clock time and the place it's in: "tomorrow at 9", "christmas 9am pst"
        if let day = dayBase(&c, prefer: prefer) {
            var copy = c
            if let match = copy.take(#" (?:at |@ ?)?("# + Self.clockPattern + #")(?![a-z\d])| (?:at|@) ?((?:[01]?\d|2[0-3]))(?![a-z\d:])"#),
               let clock = Self.clockSeconds(match[1].isEmpty ? match[2] : match[1]) {
                c = copy
                let place = sourcePlace(&c)
                guard let components = day.resolve(place?.zone ?? zone) else { return nil }
                var moment = clockMoment(day: components, seconds: clock.seconds, hasSeconds: clock.hasSeconds, place: place, prefer: .upcoming)
                if day.derived { moment?.isDerived = true }
                return moment
            }
            guard let components = day.resolve(zone), let date = cal.date(from: components) else { return nil }
            var moment = Moment(date: date, zone: zone, hasTime: false)
            moment.isDerived = day.derived
            return moment
        }
        // A clock time first: "9am", "9am london", "5pm tomorrow", "9 utc", "9am pst on friday"
        var copy = c
        let clock: (seconds: Int, hasSeconds: Bool)
        var needsPlace = false
        if let match = copy.take("(" + Self.clockPattern + #")(?![a-z\d])"#), let parsed = Self.clockSeconds(match[1]) {
            clock = parsed
        } else if let match = copy.take(#"((?:[01]?\d|2[0-3]))(?= )"#), let parsed = Self.clockSeconds(match[1]) {
            clock = parsed; needsPlace = true
        } else { return nil }
        var place = sourcePlace(&copy)
        var day: DayReference?
        var dayCopy = copy
        if dayCopy.take(" (?:on |this )?") != nil, let found = dayBase(&dayCopy, prefer: prefer) {
            day = found; copy = dayCopy
            if place == nil { place = sourcePlace(&copy) }
        }
        guard !needsPlace || place != nil || day != nil else { return nil }
        c = copy
        let components = day.flatMap { $0.resolve(place?.zone ?? zone) }
        guard day == nil || components != nil else { return nil }
        var moment = clockMoment(day: components, seconds: clock.seconds, hasSeconds: clock.hasSeconds, place: place, prefer: day == nil ? prefer : .upcoming)
        if day?.derived == true { moment?.isDerived = true }
        return moment
    }

    /// "in tokyo", "pst", "new york time": the place a clock time was written in, up to the next step.
    private func sourcePlace(_ c: inout Cursor) -> Place? {
        var copy = c
        guard let match = copy.take(#" (?:from |in (?=.+ (?:then )?(?:to|into|as) ))?(?!(?:then|to|in|as|into|plus|minus|add|subtract|on|at|and|x|times) )(.+?)"# + Self.stepEnd),
              let place = CalculationZones.place(match[1], local: zone) else { return nil }
        c = copy
        return place
    }

    /// A day written in words or digits. Days relative to today are worked out in the zone they're
    /// read in: "tomorrow 9am tokyo" is tomorrow in Tokyo.
    struct DayReference {
        let resolve: (TimeZone) -> DateComponents?
        let derived: Bool
    }

    private func dayBase(_ c: inout Cursor, prefer: Preference) -> DayReference? {
        let now = self.now
        func relative(_ offset: Int) -> DayReference {
            DayReference(resolve: { zone in
                var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
                return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: now)).map { cal.dateComponents([.year, .month, .day], from: $0) }
            }, derived: abs(offset) >= 2)
        }
        if c.take(#"(?:the )?day after tomorrow|overmorrow"#) != nil { return relative(2) }
        if c.take(#"(?:the )?day before yesterday"#) != nil { return relative(-2) }
        if let match = c.take(#"(today|tonight|tomorrow|tmrw|tmr|yesterday)(?![a-z])"#) {
            return relative(match[1] == "yesterday" ? -1 : match[1].hasPrefix("t") && match[1] != "today" && match[1] != "tonight" ? 1 : 0)
        }
        // "last day of february", "first monday of december", "last working day of the month",
        // "second tuesday of next month", "first day of the year"
        if let match = c.take(#"(?:the )?(first|1st|second|2nd|third|3rd|fourth|4th|fifth|5th|last|final|penultimate) (day|weekday|working day|business day|"# + Self.weekdayPattern + #") (?:of|in) (?:the )?(?:(this|next|last|coming) )?(month|year|"# + Self.monthPattern + #")(?![a-z])(?:,? (\d{4})(?!\d))?"#) {
            let ordinals = ["first": 1, "1st": 1, "second": 2, "2nd": 2, "third": 3, "3rd": 3, "fourth": 4, "4th": 4, "fifth": 5, "5th": 5,
                            "last": -1, "final": -1, "penultimate": -2]
            guard let n = ordinals[match[1]] else { return nil }
            let kind = match[2], which = match[3], period = match[4], year = Int(match[5])
            let weekday = Self.weekdayNumber(kind)
            let shift = which == "next" || which == "coming" ? 1 : which == "last" ? -1 : 0
            return DayReference(resolve: { zone in
                var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
                let today = cal.dateComponents([.year, .month], from: now)
                guard let thisYear = today.year, let thisMonth = today.month else { return nil }
                func pick(_ year: Int, _ month: Int?) -> DateComponents? {
                    Self.nthDay(n, weekday: kind == "day" ? nil : weekday ?? 0, month: month, year: year)
                }
                switch period {
                case "month":
                    let total = thisYear*12+thisMonth-1+shift
                    return pick(year ?? total/12, total%12+1)
                case "year": return pick(year ?? thisYear+shift, nil)
                default:
                    guard let month = Self.monthNumber(period) else { return nil }
                    return self.occurrence(of: { pick($0, month) }, year: year, which: which == "coming" ? "next" : which, prefer: prefer, in: zone)
                }
            }, derived: true)
        }
        // "the weekend": the coming Saturday, or today on one.
        if c.take(#"(?:the |this |next )?weekend(?![a-z])"#) != nil {
            return DayReference(resolve: { zone in
                var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
                let today = cal.startOfDay(for: now)
                let offset = (7-cal.component(.weekday, from: today))%7
                return cal.date(byAdding: .day, value: offset, to: today).map { cal.dateComponents([.year, .month, .day], from: $0) }
            }, derived: false)
        }
        // "next friday", "friday", "last monday", "this sunday", "friday next week"
        if let match = c.take(#"(?:(next|this|last|coming|past|previous) )?("# + Self.weekdayPattern + #")(?: (next|last|this) week)?(?![a-z])"#),
           let target = Self.weekdayNumber(match[2]) {
            let which = match[1], week = match[3]
            return DayReference(resolve: { zone in
                var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
                let today = cal.startOfDay(for: now)
                let current = cal.component(.weekday, from: today)
                let mondayIndex = { (weekday: Int) in (weekday+5)%7 }
                var offset: Int
                if !week.isEmpty || which == "this" {
                    offset = mondayIndex(target)-mondayIndex(current) + (week == "next" ? 7 : week == "last" ? -7 : 0)
                } else if which == "last" || which == "past" || which == "previous" || (which.isEmpty && prefer == .past) {
                    offset = -((current-target+7)%7); if offset == 0 { offset = -7 }
                } else {
                    offset = (target-current+7)%7; if offset == 0 { offset = 7 }
                }
                return cal.date(byAdding: .day, value: offset, to: today).map { cal.dateComponents([.year, .month, .day], from: $0) }
            }, derived: !which.isEmpty || !week.isEmpty)
        }
        // "christmas", "next easter", "thanksgiving 2027"
        if let match = c.take(#"(?:(next|last|this) )?("# + Self.holidayPattern + #")(?:,? (\d{4}))?(?![a-z\d])"#) {
            let which = match[1], name = match[2], year = Int(match[3])
            return DayReference(resolve: { zone in
                self.occurrence(of: { Self.holiday(name, year: $0) }, year: year, which: which, prefer: prefer, in: zone)
            }, derived: !which.isEmpty)
        }
        // "25 dec", "25th of december 2026", "dec 25", "december 25th, 2026"
        if let match = c.take(#"(\d{1,2})(?:st|nd|rd|th)?(?: of)? ("# + Self.monthPattern + #")(?![a-z])(?:,? (\d{4})(?!\d))?|("# + Self.monthPattern + #") (\d{1,2})(?:st|nd|rd|th)?(?![\d:.])(?:,? (\d{4})(?!\d))?"#) {
            let day = Int(match[1]) ?? Int(match[5]) ?? 0
            let month = Self.monthNumber(match[2].isEmpty ? match[4] : match[2])
            let year = Int(match[3]) ?? Int(match[6])
            guard (1...31).contains(day), let month else { return nil }
            return DayReference(resolve: { zone in
                self.occurrence(of: { year in DateComponents(year: year, month: month, day: day) }, year: year, which: "", prefer: prefer, in: zone)
            }, derived: false)
        }
        // "2026-11-27", "2026/11/27"
        if let match = c.take(#"(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?![\d:])"#) {
            let day = DateComponents(year: Int(match[1]), month: Int(match[2]), day: Int(match[3]))
            guard Self.valid(day) else { return nil }
            return DayReference(resolve: { _ in day }, derived: false)
        }
        // "27/11/2026", "11/27/2026", "27.11.2026": the larger number is the day, else the person's order.
        if let match = c.take(#"(\d{1,2})([/.])(\d{1,2})[/.](\d{4})(?![\d:])"#),
           let first = Int(match[1]), let second = Int(match[3]), let year = Int(match[4]) {
            let monthFirst = first > 12 ? false : second > 12 ? true : match[2] == "." ? false : self.monthFirst
            let day = DateComponents(year: year, month: monthFirst ? first : second, day: monthFirst ? second : first)
            guard Self.valid(day) else { return nil }
            return DayReference(resolve: { _ in day }, derived: false)
        }
        // "end of the month", "start of next week", "end of year"
        if let match = c.take(#"(start|beginning|end) of (?:the )?(?:(this|next|last) )?(week|month|year|quarter)(?![a-z])"#) {
            let atEnd = match[1] == "end", shift = match[2] == "next" ? 1 : match[2] == "last" ? -1 : 0, period = match[3]
            return DayReference(resolve: { zone in
                var cal = Calendar(identifier: .iso8601); cal.timeZone = zone
                let component: Calendar.Component = period == "week" ? .weekOfYear : period == "month" ? .month : period == "year" ? .year : .quarter
                let unit: Calendar.Component = period == "quarter" ? .month : component
                guard let moved = cal.date(byAdding: unit, value: shift*(period == "quarter" ? 3 : 1), to: now),
                      let interval = cal.dateInterval(of: component, for: moved),
                      let day = atEnd ? cal.date(byAdding: .day, value: -1, to: interval.end) : interval.start else { return nil }
                return cal.dateComponents([.year, .month, .day], from: day)
            }, derived: true)
        }
        return nil
    }

    /// The day `make` names in `year`, or, without one, the occurrence `which` and `prefer` point to.
    private func occurrence(of make: (Int) -> DateComponents?, year: Int?, which: String, prefer: Preference, in zone: TimeZone) -> DateComponents? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        if let year { return make(year).flatMap { Self.valid($0) ? $0 : nil } }
        let today = cal.dateComponents([.year, .month, .day], from: now)
        guard let thisYear = today.year, let todayDate = cal.date(from: today) else { return nil }
        let backwards = which == "last" || (which.isEmpty && prefer == .past)
        let strictly = which == "next" || which == "last"
        for step in 0...8 {
            let candidateYear = thisYear+(backwards ? -step : step)
            guard let candidate = make(candidateYear), Self.valid(candidate), let date = cal.date(from: candidate) else { continue }
            if which == "this" { return candidate }
            if backwards ? (strictly ? date < todayDate : date <= todayDate) : (strictly ? date > todayDate : date >= todayDate) { return candidate }
        }
        return nil
    }

    private func clockMoment(day: DateComponents?, seconds: Int, hasSeconds: Bool, place: Place?, prefer: Preference) -> Moment? {
        let source = place?.zone ?? zone
        let cal = calendar(source)
        func make(_ dayStart: Date) -> Date? {
            let time = DateComponents(hour: seconds/3600, minute: seconds/60%60, second: seconds%60)
            // A wall time skipped or repeated by a clock change has no single answer.
            guard let date = cal.nextDate(after: dayStart.addingTimeInterval(-1), matching: time, matchingPolicy: .strict, repeatedTimePolicy: .first),
                  cal.isDate(date, inSameDayAs: dayStart),
                  cal.nextDate(after: dayStart.addingTimeInterval(-1), matching: time, matchingPolicy: .strict, repeatedTimePolicy: .last) == date else { return nil }
            return date
        }
        var dayStart: Date
        if let day { guard let start = cal.date(from: day) else { return nil }; dayStart = start }
        else { dayStart = cal.startOfDay(for: now) }
        guard var date = make(dayStart) else { return nil }
        // "until 9am" when it's past 9 means tomorrow's; "since 5pm" before 5 means yesterday's.
        if day == nil, prefer == .future, date < now, let next = cal.date(byAdding: .day, value: 1, to: dayStart), let moved = make(next) {
            dayStart = next; date = moved
        } else if day == nil, prefer == .past, date > now, let previous = cal.date(byAdding: .day, value: -1, to: dayStart), let moved = make(previous) {
            dayStart = previous; date = moved
        }
        var moment = Moment(date: date, zone: source, label: place?.label, hasTime: true, hasSeconds: hasSeconds)
        moment.anchor = cal.dateComponents([.year, .month, .day], from: date)
        moment.anchorIsToday = day == nil
        moment.mentionsZone = place != nil
        return moment
    }

    // MARK: - Steps

    /// Conversions, arithmetic and formats after a moment, in the order written.
    private func steps(_ c: inout Cursor, _ moment: inout Moment) -> Bool {
        while !c.isAtEnd {
            if let match = c.take(" (?:" + Self.connector + ") (?:a |an |the )?(" + Self.formats + ")(?![a-z])") {
                let format = match[1]
                switch true {
                case format.hasPrefix("12") || format == "am/pm": moment.twelveHour = true
                case format.hasPrefix("24") || format.hasPrefix("military"): moment.twelveHour = false
                case format.contains("ms") || format.contains("milli"): moment.output = .unixMilliseconds
                case format.hasPrefix("unix") || format.hasPrefix("epoch") || format.hasPrefix("posix") || format == "timestamp": moment.output = .unix
                case format.hasPrefix("iso week") || format.hasPrefix("week"): moment.output = .weekNumber
                case format.hasPrefix("iso") || format.hasPrefix("rfc"): moment.output = .iso
                case format.contains("day of the week") || format.contains("day of week") || format == "weekday": moment.output = .weekday
                case format.contains("year"): moment.output = .dayOfYear
                default: moment.output = .date
                }
                moment.anchor = moment.output == .human ? moment.anchor : nil
                moment.isDerived = true
                continue
            }
            var copy = c
            if let match = copy.take(" (?:" + Self.connector + ") (.+?)" + Self.stepEnd) {
                let names = match[1].components(separatedBy: " and ").flatMap { $0.components(separatedBy: ", ") }
                    .flatMap { $0.components(separatedBy: " & ") }
                let places = names.compactMap { CalculationZones.place($0, local: zone) }
                if !places.isEmpty, places.count == names.count {
                    c = copy
                    moment.places = places; moment.zone = places[0].zone; moment.label = places[0].label
                    moment.hasTime = true; moment.mentionsZone = true; moment.isDerived = true
                    if moment.output != .human && moment.output != .date { moment.output = .human }
                    continue
                }
            }
            copy = c
            if let match = copy.take(#"\s*(?:then |and )?(plus|\+|add|minus|-|subtract|less|take away|take)\s*"#) {
                var span: Span?
                if copy.peek(#"\("#), let seconds = QuantityExpression.durationSeconds(&copy) { span = Span(seconds: seconds, terms: 1) }
                else { span = Self.span(&copy) }
                if let span, let moved = applying(["minus", "-", "subtract", "less", "take away", "take"].contains(match[1]) ? span.negated : span, to: moment) {
                    c = copy
                    moment = moved
                    continue
                }
            }
            return false
        }
        return true
    }

    /// Reads "2 hours 30 minutes", "1h30", "a week and a half", "1:30" (hours and minutes).
    static func span(_ c: inout Cursor) -> Span? {
        var total = Span()
        var last: Span.Unit?
        while true {
            let gap = total.terms == 0 ? "" : #"(?:,? and |, | |)"#
            var copy = c
            if let match = copy.take(gap + "(?:" + amountPattern + ")(" + unitPattern + #")(?![a-z])"#),
               let unit = Span.unit(match[3]),
               // "2 hours a week" is a rate, not a week more; "an hour and a half" and "2 days, an hour" add.
               total.terms == 0 || match[2].isEmpty || match[0].hasPrefix(" and ") || match[0].hasPrefix(", ") {
                c = copy
                guard let value = Double(match[1]) ?? amountWords[match[2]], total.add(value, unit) else { return nil }
                total.terms += 1; last = unit
                continue
            }
            if let unit = last, c.take(" and a half") != nil {
                guard total.add(0.5, unit) else { return nil }
                continue
            }
            if last == .hour, let match = c.take(#" ?([0-5]?\d)(?![\d:.a-z])"#), let minutes = Double(match[1]) {
                total.seconds += minutes*60; last = .minute
                continue
            }
            if total.terms == 0, let match = c.take(#"(\d{1,3}):([0-5]\d)(?::([0-5]\d))?(?![\d:])"#),
               let hours = Double(match[1]), let minutes = Double(match[2]) {
                total.seconds = hours*3600+minutes*60+(Double(match[3]) ?? 0); total.terms = 1
                return total
            }
            break
        }
        return total.terms > 0 ? total : nil
    }

    private func applying(_ span: Span, to moment: Moment) -> Moment? {
        let cal = calendar(moment.zone)
        var date = moment.date
        if span.months != 0 { guard let moved = cal.date(byAdding: .month, value: span.months, to: date) else { return nil }; date = moved }
        if span.days != 0 { guard let moved = cal.date(byAdding: .day, value: span.days, to: date) else { return nil }; date = moved }
        if span.businessDays != 0 {
            guard abs(span.businessDays) <= 10_000 else { return nil }
            var left = abs(span.businessDays)
            while left > 0 {
                guard let day = cal.date(byAdding: .day, value: span.businessDays < 0 ? -1 : 1, to: date) else { return nil }
                date = day
                if !cal.isDateInWeekend(day) { left -= 1 }
            }
        }
        date = date.addingTimeInterval(span.seconds)
        guard (1...9999).contains(cal.component(.year, from: date)), cal.component(.era, from: date) == 1 else { return nil }
        var next = moment
        next.date = date
        next.isDerived = true
        if span.seconds != 0 {
            next.hasTime = true
            if span.seconds.truncatingRemainder(dividingBy: 60) != 0 { next.hasSeconds = true }
        }
        if span.hasCalendarPart { next.anchor = nil }
        return next
    }

    // MARK: - Writing

    private func format(_ moment: Moment) -> String {
        let twelve = moment.twelveHour ?? twelveHour
        switch moment.output {
        case .unix: return "\(Int64(moment.date.timeIntervalSince1970.rounded(.down))) Unix seconds"
        case .unixMilliseconds: return "\(Int64((moment.date.timeIntervalSince1970*1000).rounded(.down))) Unix ms"
        case .iso:
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = moment.zone
            formatter.formatOptions = moment.hasTime ? [.withInternetDateTime] : [.withFullDate]
            return formatter.string(from: moment.date)
        case .weekday: return weekdayText(moment.date, moment.zone)
        case .weekNumber:
            var iso = Calendar(identifier: .iso8601); iso.timeZone = moment.zone
            return "Week \(iso.component(.weekOfYear, from: moment.date))"
        case .dayOfYear: return dayOfYearText(moment.date, moment.zone)
        case .human, .date: break
        }
        func label(_ zone: TimeZone, _ written: String?) -> String {
            moment.mentionsZone ? " "+(written ?? CalculationZones.label(zone, at: moment.date)) : ""
        }
        if moment.places.count > 1 {
            return moment.places.map { place in
                clockText(moment.date, place.zone, seconds: moment.hasSeconds, twelveHour: twelve)+label(place.zone, place.label)
                    + (dayMarker(moment, in: place.zone, short: true) ?? "")
            }.joined(separator: " · ")
        }
        guard moment.hasTime else { return dateText(moment.date, moment.zone) }
        let clock = clockText(moment.date, moment.zone, seconds: moment.hasSeconds, twelveHour: twelve)+label(moment.zone, moment.label)
        if moment.output == .human, moment.anchor != nil {
            let marker = dayMarker(moment, in: moment.zone, short: false)
            if marker != nil { return clock + (marker ?? "") }
        }
        return dateText(moment.date, moment.zone)+", "+clock
    }

    /// "" on the anchor's day, " · next day" or " · tomorrow" either side of it, nil further off.
    private func dayMarker(_ moment: Moment, in zone: TimeZone, short: Bool) -> String? {
        guard let anchor = moment.anchor else { return short ? "" : nil }
        let result = calendar(zone).dateComponents([.year, .month, .day], from: moment.date)
        let utc = calendar(CalculationZones.utc)
        guard let first = utc.date(from: anchor), let last = utc.date(from: result),
              let days = utc.dateComponents([.day], from: first, to: last).day else { return nil }
        switch days {
        case 0: return ""
        case 1: return short ? " (+1)" : moment.anchorIsToday && moment.places.isEmpty && !moment.mentionsZone ? " · tomorrow" : " · next day"
        case -1: return short ? " (-1)" : moment.anchorIsToday && moment.places.isEmpty && !moment.mentionsZone ? " · yesterday" : " · previous day"
        default: return short ? " (\(days > 0 ? "+" : "")\(days))" : nil
        }
    }

    private func dateText(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar(zone); formatter.timeZone = zone
        formatter.dateFormat = "EEE, d MMM yyyy"
        return formatter.string(from: date)
    }

    private func weekdayText(_ date: Date, _ zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar(zone); formatter.timeZone = zone
        formatter.dateFormat = "EEEE, d MMM yyyy"
        return formatter.string(from: date)
    }

    private func dayOfYearText(_ date: Date, _ zone: TimeZone) -> String {
        let cal = calendar(zone)
        let day = cal.ordinality(of: .day, in: .year, for: date) ?? 0
        let days = cal.range(of: .day, in: .year, for: date)?.count ?? 365
        return "Day \(day) of \(days)"
    }

    private func clockText(_ date: Date, _ zone: TimeZone, seconds: Bool, twelveHour: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone
        formatter.dateFormat = twelveHour ? (seconds ? "h:mm:ss a" : "h:mm a") : (seconds ? "HH:mm:ss" : "HH:mm")
        return twelveHour ? formatter.string(from: date).lowercased() : formatter.string(from: date)
    }

    /// The span from `start` to `end` in `unit`, or in the clearest units when none is asked for.
    private func spanText(from start: Moment, to end: Moment, unit: String) -> String? {
        let cal = calendar(zone)
        let (first, last) = start.date <= end.date ? (start, end) : (end, start)
        let seconds = last.date.timeIntervalSince(first.date)
        let dayFirst = cal.startOfDay(for: first.date), dayLast = cal.startOfDay(for: last.date)
        let days = cal.dateComponents([.day], from: dayFirst, to: dayLast).day ?? 0
        switch unit {
        case "seconds": return AddressCalculation.number(seconds.rounded(), digits: 0, grouping: true)+" seconds"
        case "minutes": return AddressCalculation.number(seconds/60, digits: 1, grouping: true)+" minutes"
        case "hours": return AddressCalculation.number(seconds/3600, digits: 2, grouping: true)+" hours"
        case "days", "sleeps", "nights": return Self.quantity(days, unit == "days" ? "day" : unit == "sleeps" ? "sleep" : "night")
        case "weeks":
            return [Self.quantity(days/7, "week"), days%7 == 0 ? nil : Self.quantity(days%7, "day")].compactMap { $0 }.joined(separator: " ")
        case "months", "years":
            let parts = cal.dateComponents(unit == "years" ? [.year, .month, .day] : [.month, .day], from: dayFirst, to: dayLast)
            return Self.calendarText(parts, keepFirst: true)
        case "business days", "working days", "weekdays":
            guard days <= 400_000 else { return nil }
            var count = 0, day = dayFirst
            for _ in 0..<days {
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { return nil }
                day = next
                if !cal.isDateInWeekend(day) { count += 1 }
            }
            return Self.quantity(count, "business day")
        default:
            if first.hasTime || last.hasTime {
                return Self.elapsed(Int(seconds.rounded()), days: true)
            }
            if days < 60 { return Self.quantity(days, "day") }
            return Self.calendarText(cal.dateComponents([.year, .month, .day], from: dayFirst, to: dayLast), keepFirst: false)
        }
    }

    private func isBareClock(_ text: String) -> Bool {
        AddressCalculation.groups("^(?:" + Self.clockPattern + ")$", in: text) != nil
    }

    private func endOfISOWeek(_ date: Date, _ cal: Calendar) -> Date? {
        var iso = Calendar(identifier: .iso8601); iso.timeZone = cal.timeZone
        return iso.dateInterval(of: .weekOfYear, for: date).flatMap { iso.date(byAdding: .day, value: -1, to: $0.end) }
    }

    private func calendar(_ timeZone: TimeZone) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = timeZone
        return result
    }

    // MARK: - Words

    static func clockSeconds(_ text: String) -> (seconds: Int, hasSeconds: Bool)? {
        switch text {
        case "noon", "midday": return (43200, false)
        case "midnight": return (0, false)
        default: break
        }
        guard let match = AddressCalculation.groups(#"^(\d{1,2})(?:[:.]([0-5]\d)(?::([0-5]\d))?)? ?([ap]m)?$"#, in: text),
              let hour = Int(match[1]) else { return nil }
        let minutes = Int(match[2]) ?? 0, seconds = Int(match[3]) ?? 0
        if match[4].isEmpty {
            guard hour < 24, !text.contains(".") else { return nil }
            return (hour*3600+minutes*60+seconds, !match[3].isEmpty)
        }
        guard (1...12).contains(hour) else { return nil }
        return ((hour%12+(match[4] == "pm" ? 12 : 0))*3600+minutes*60+seconds, !match[3].isEmpty)
    }

    private static func isMarkedClock(_ text: String) -> Bool {
        text.hasSuffix("m") || text == "noon" || text == "midday" || text == "midnight"
    }

    private static func weekdayNumber(_ name: String) -> Int? {
        ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7][String(name.prefix(3))]
    }

    private static func monthNumber(_ name: String) -> Int? {
        ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12][String(name.prefix(3))]
    }

    static func valid(_ day: DateComponents) -> Bool {
        guard let year = day.year, let month = day.month, let date = day.day, (1...9999).contains(year), (1...12).contains(month) else { return false }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = CalculationZones.utc
        guard let made = cal.date(from: day) else { return false }
        return cal.component(.day, from: made) == date && cal.component(.month, from: made) == month
    }

    static func isLeap(_ year: Int) -> Bool { year%4 == 0 && (year%100 != 0 || year%400 == 0) }

    /// The `n`th day of `month` (or of the year, without one), counting from the end when `n` is
    /// negative: any day when `weekday` is nil, that weekday (1 is Sunday) when given, or a working
    /// day, Monday to Friday, when it's 0.
    static func nthDay(_ n: Int, weekday: Int?, month: Int?, year: Int) -> DateComponents? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = CalculationZones.utc
        guard let first = cal.date(from: DateComponents(year: year, month: month ?? 1, day: 1)),
              let days = cal.range(of: .day, in: month == nil ? .year : .month, for: first)?.count else { return nil }
        let matching = (0..<days).compactMap { offset -> Date? in
            guard let day = cal.date(byAdding: .day, value: offset, to: first) else { return nil }
            let current = cal.component(.weekday, from: day)
            switch weekday {
            case nil: return day
            case 0?: return (2...6).contains(current) ? day : nil
            case let wanted?: return current == wanted ? day : nil
            }
        }
        let index = n > 0 ? n-1 : matching.count+n
        guard matching.indices.contains(index) else { return nil }
        return cal.dateComponents([.year, .month, .day], from: matching[index])
    }

    /// A holiday's day in `year`. Easter follows the Gregorian computus; the US holidays, their rules.
    static func holiday(_ name: String, year: Int) -> DateComponents? {
        let fixed: [(String, Int, Int)] = [
            ("christmas eve", 12, 24), ("xmas eve", 12, 24), ("christmas", 12, 25), ("xmas", 12, 25), ("boxing", 12, 26),
            ("new year's eve", 12, 31), ("new years eve", 12, 31), ("nye", 12, 31), ("new year", 1, 1), ("halloween", 10, 31),
            ("valentine", 2, 14), ("st patrick", 3, 17), ("st paddy", 3, 17), ("st. patrick", 3, 17), ("st. paddy", 3, 17),
            ("april fools", 4, 1), ("independence", 7, 4), ("4th of july", 7, 4), ("fourth of july", 7, 4),
            ("the 4th of july", 7, 4), ("the fourth of july", 7, 4), ("bonfire", 11, 5), ("guy fawkes", 11, 5)
        ]
        if let (_, month, day) = fixed.first(where: { name.hasPrefix($0.0) }) { return DateComponents(year: year, month: month, day: day) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = CalculationZones.utc
        func shifted(_ base: DateComponents, by days: Int) -> DateComponents? {
            cal.date(from: base).flatMap { cal.date(byAdding: .day, value: days, to: $0) }.map { cal.dateComponents([.year, .month, .day], from: $0) }
        }
        func nth(_ n: Int, weekday: Int, month: Int) -> DateComponents? { nthDay(n, weekday: weekday, month: month, year: year) }
        let a = year%19, b = year/100, c = year%100, d = b/4, e = b%4, f = (b+8)/25, g = (b-f+1)/3
        let h = (19*a+b-d-g+15)%30, i = c/4, k = c%4, l = (32+2*e+2*i-h-k)%7, m = (a+11*h+22*l)/451
        let easter = DateComponents(year: year, month: (h+l-7*m+114)/31, day: (h+l-7*m+114)%31+1)
        switch true {
        case name.hasPrefix("easter monday"): return shifted(easter, by: 1)
        case name.hasPrefix("easter"): return easter
        case name.hasPrefix("good friday"): return shifted(easter, by: -2)
        case name.hasPrefix("pancake") || name.hasPrefix("shrove"): return shifted(easter, by: -47)
        case name.hasPrefix("ash wednesday"): return shifted(easter, by: -46)
        case name.hasPrefix("thanksgiving"): return nth(4, weekday: 5, month: 11)
        case name.hasPrefix("black friday"): return nth(4, weekday: 5, month: 11).flatMap { shifted($0, by: 1) }
        case name.hasPrefix("cyber monday"): return nth(4, weekday: 5, month: 11).flatMap { shifted($0, by: 4) }
        case name.hasPrefix("father"): return nth(3, weekday: 1, month: 6)
        case name.hasPrefix("memorial"): return nth(-1, weekday: 2, month: 5)
        case name.hasPrefix("labor") || name.hasPrefix("labour"): return nth(1, weekday: 2, month: 9)
        case name.hasPrefix("leap"): return isLeap(year) ? DateComponents(year: year, month: 2, day: 29) : nil
        default: return nil
        }
    }

    // MARK: - Writing spans

    static func quantity(_ value: Int, _ unit: String) -> String { "\(value) \(unit)\(abs(value) == 1 ? "" : "s")" }

    /// "3 hr 25 min", "2 days 4 hr", "45 sec".
    static func elapsed(_ seconds: Int, days: Bool = false) -> String {
        let sign = seconds < 0 ? "-" : ""
        let total = abs(seconds)
        var parts: [String] = []
        if days, total >= 86400 { parts.append(quantity(total/86400, "day")) }
        let hours = days ? total/3600%24 : total/3600
        if hours != 0 { parts.append("\(hours) hr") }
        if total/60%60 != 0 { parts.append("\(total/60%60) min") }
        if total%60 != 0, total < 86400 { parts.append("\(total%60) sec") }
        return parts.isEmpty ? "0 min" : sign+parts.joined(separator: " ")
    }

    /// "9 hr", "5 hr 30 min".
    static func hoursText(_ seconds: Int) -> String {
        let minutes = seconds/60
        return [minutes/60 != 0 ? "\(minutes/60) hr" : nil, minutes%60 != 0 ? "\(minutes%60) min" : nil].compactMap { $0 }.joined(separator: " ")
    }

    private static func calendarText(_ parts: DateComponents, keepFirst: Bool) -> String {
        let pieces: [(Int?, String)] = [(parts.year, "year"), (parts.month, "month"), (parts.day, "day")]
        let present = pieces.filter { $0.0 != nil }
        let written = present.enumerated().compactMap { index, piece -> String? in
            guard let value = piece.0, value != 0 || (keepFirst && index == 0) else { return nil }
            return quantity(value, piece.1)
        }
        return written.isEmpty ? "0 days" : written.joined(separator: " ")
    }
}
