import Foundation

/// Arithmetic on amounts of money, lengths of time and pay, with conversions anywhere in it:
/// "56 usd to gbp + 15 gbp", "2x(15 usd to gbp)", "(£84 + 15%) / 3", "2h 30m + 45m in minutes",
/// "(9am to 5:30pm - 30 min) x 5 at £15/hr", "£50k a year to hourly", "£600 / 40 hours". Plain
/// numbers alone are left to the search engine's calculator.
enum QuantityExpression {
    struct Value {
        enum Kind: Equatable {
            case number, money(String), duration, percent
            /// Money for each period: "£15 an hour", "£50k a year".
            case rate(String, Period)
            /// Time for each period: "37.5 hours a week".
            case durationRate(Period)
        }
        var amount: Double
        var kind: Kind
        /// Currencies to show the result in, the first being its own: "to gbp and eur".
        var currencies: [String] = []
        /// How to write a duration: "hours", "h:mm", or as hours and minutes when nil.
        var durationFormat: String? = nil
        /// The working week a rate's conversion assumed, to say so: "37.5-hour week".
        var assumption: String? = nil
        /// A length in months or years, taken at their average: only good for paying over it, as in
        /// "£9.99 a month for a year", never to be shown as a length of its own.
        var averaged = false
    }

    /// The periods pay is written for. Pay converts between them over a working year: 52 weeks of
    /// 5 days, and the person's region's usual hours a week.
    enum Period: String {
        case minute, hour, day, week, month, year

        init?(_ word: String) {
            switch word {
            case "minute", "min", "minutely": self = .minute
            case "hour", "hr", "h", "hourly": self = .hour
            case "day", "daily": self = .day
            case "week", "wk", "weekly": self = .week
            case "month", "mo", "mth", "monthly": self = .month
            case "year", "yr", "annum", "yearly", "annually", "annual", "salary", "annual salary", "pa", "p/a": self = .year
            default: return nil
            }
        }

        var seconds: Double {
            switch self {
            case .minute: 60
            case .hour: 3600
            case .day: 86400
            case .week: 604_800
            case .month: 2_629_800
            case .year: 31_557_600
            }
        }

        func perYear(hoursPerWeek: Double) -> Double {
            switch self {
            case .year: 1
            case .month: 12
            case .week: 52
            case .day: 260
            case .hour: 52*hoursPerWeek
            case .minute: 52*hoursPerWeek*60
            }
        }

        var word: String { self == .hour ? "an hour" : "a " + rawValue }

        /// What going from this period to `other` takes for granted, if anything.
        func assumption(to other: Period, hoursPerWeek: Double) -> String? {
            guard self != other else { return nil }
            let short: Set<Period> = [.minute, .hour]
            if short.contains(self) != short.contains(other) {
                return AddressCalculation.number(hoursPerWeek, digits: 1) + "-hour week"
            }
            if self == .day || other == .day { return "5-day week" }
            return nil
        }
    }

    static let periodWords = #"hour|hr|h|minute|min|day|week|wk|month|mo|mth|year|yr|annum"#
    static let periodAdverbs = #"hourly|daily|weekly|monthly|yearly|annually|annual salary|annual|salary|pa|p/a"#

    /// A full-time week where the person lives: 37.5 hours in Britain and Ireland, 40 elsewhere.
    static func usualHoursPerWeek(_ locale: Locale) -> Double {
        ["GB", "IE"].contains(locale.region?.identifier ?? "") ? 37.5 : 40
    }

    static func evaluate(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        var text = query
        // "how many seconds in a day", "minutes in 3 hours"
        if let match = AddressCalculation.groups(#"^(?:how many |number of )?(seconds|minutes|hours|days|weeks)(?: are)?(?: there)? in (?:one |1 )?(.+)$"#, in: text) {
            text = match[2] + " in " + match[1]
        }
        // "half of £84", "double 56 usd", "a third of (£90 + £30)"
        let factors: [String: String] = ["half": "0.5", "a half": "0.5", "double": "2", "twice": "2", "triple": "3", "treble": "3",
                                         "a third": "(1/3)", "third": "(1/3)", "a quarter": "0.25", "quarter": "0.25",
                                         "two thirds": "(2/3)", "three quarters": "0.75"]
        if let match = AddressCalculation.groups(#"^(half|a half|double|twice|triple|treble|a third|third|a quarter|quarter|two thirds|three quarters) (?:of )?(.+)$"#, in: text),
           let factor = factors[match[1]] {
            text = factor + " x (" + match[2] + ")"
        }
        var hoursPerWeek = usualHoursPerWeek(context.locale)
        // "£50k a year to hourly at 40 hours a week"
        if let match = AddressCalculation.groups(#"^(.+?) (?:at|on|with|assuming|working|based on) (\d{1,2}(?:\.\d+)?) ?(?:hours?|hrs?|h)(?: (?:a|per|each) | ?/ ?)(?:week|wk)(.*)$"#, in: text),
           let hours = Double(match[2]), hours > 0 {
            text = match[1] + match[3]; hoursPerWeek = hours
        }
        var parser = Parser(text: text, context: context)
        parser.hoursPerWeek = hoursPerWeek
        guard let value = parser.expression(), parser.cursor.isAtEnd, parser.usedMoney || parser.usedDuration else { return nil }
        return parser.answer(value, steps: parser.operations+parser.conversions, query: query).map { AddressCalculation($0) }
    }

    /// A clock range's length carried on through `rest`'s steps: " minus 30 min x 5 in hours",
    /// " x 5 at £15 an hour".
    static func continueDuration(_ seconds: Double, with rest: String, unit: String, context: AddressCalculation.Context? = nil) -> String? {
        var value = Value(amount: seconds, kind: .duration)
        if !unit.isEmpty { value.durationFormat = unit }
        guard !rest.isEmpty else { return durationText(value) }
        var parser = Parser(text: rest, context: context)
        if let context { parser.hoursPerWeek = usualHoursPerWeek(context.locale) }
        guard let result = parser.chain(from: value), parser.cursor.isAtEnd else { return nil }
        if result.kind == .duration { return durationText(result) }
        return parser.answer(result, steps: 1, query: rest)
    }

    /// A bracketed length of time at `cursor`, as a date's step uses: "now + (2 x 45 min)".
    static func durationSeconds(_ cursor: inout Cursor) -> Double? {
        var parser = Parser(text: cursor.rest, context: nil)
        guard let value = parser.primary(), value.kind == .duration else { return nil }
        cursor = parser.cursor
        return value.amount
    }

    static func durationText(_ value: Value) -> String? {
        let seconds = value.amount
        guard seconds.isFinite, abs(seconds) < 1e12 else { return nil }
        let rounded = Int(seconds.rounded())
        let sign = rounded < 0 ? "-" : ""
        let total = abs(rounded)
        switch value.durationFormat {
        case "seconds", "secs", "s": return AddressCalculation.number(seconds, digits: 2, grouping: true)+" seconds"
        case "minutes", "mins", "min", "m": return AddressCalculation.number(seconds/60, digits: 2, grouping: true)+" minutes"
        case "hours", "hrs", "hr", "h": return AddressCalculation.number(seconds/3600, digits: 2, grouping: true)+" hours"
        case "days", "d": return AddressCalculation.number(seconds/86400, digits: 2, grouping: true)+" days"
        case "weeks", "w": return AddressCalculation.number(seconds/604800, digits: 2, grouping: true)+" weeks"
        case "h:mm", "hh:mm":
            return sign+String(format: value.durationFormat == "h:mm" ? "%d:%02d" : "%02d:%02d", total/3600, total/60%60)
        case "h:mm:ss", "hh:mm:ss":
            return sign+String(format: value.durationFormat == "h:mm:ss" ? "%d:%02d:%02d" : "%02d:%02d:%02d", total/3600, total/60%60, total%60)
        case "days and hours":
            return sign+CalendarCalculation.elapsed(total, days: true)
        default: return CalendarCalculation.elapsed(rounded)
        }
    }

    // MARK: - Money

    static let symbols: [(String, String)] = [
        ("us$", "USD"), ("a$", "AUD"), ("au$", "AUD"), ("c$", "CAD"), ("ca$", "CAD"), ("hk$", "HKD"), ("nz$", "NZD"),
        ("s$", "SGD"), ("r$", "BRL"), ("mx$", "MXN"), ("$", "USD"), ("£", "GBP"), ("€", "EUR"), ("¥", "JPY"),
        ("₹", "INR"), ("₩", "KRW"), ("₽", "RUB"), ("₺", "TRY"), ("₪", "ILS"), ("฿", "THB"), ("₫", "VND"),
        ("₴", "UAH"), ("₱", "PHP"), ("₦", "NGN"), ("zł", "PLN"), ("kč", "CZK")
    ]

    static let words: [String: String] = {
        var table: [String: String] = [:]
        func add(_ code: String, _ names: String) {
            for name in names.split(separator: ",") { table[name.trimmingCharacters(in: .whitespaces)] = code }
        }
        add("USD", "dollar, dollars, buck, bucks, us dollar, us dollars, american dollar, american dollars, usd")
        add("GBP", "pound, pounds, quid, sterling, pounds sterling, british pound, british pounds, gbp")
        add("EUR", "euro, euros, eur")
        add("JPY", "yen, japanese yen")
        add("CNY", "yuan, renminbi, rmb, chinese yuan")
        add("PLN", "zloty, zlotys, zlotych, zlote, złoty, złotych, złote, polish zloty, polish zlotys")
        add("CHF", "franc, francs, swiss franc, swiss francs")
        add("INR", "rupee, rupees, indian rupee, indian rupees")
        add("KRW", "won, korean won")
        add("RUB", "ruble, rubles, rouble, roubles")
        add("TRY", "lira, turkish lira")
        add("BRL", "real, reais, brazilian real, brazilian reais")
        add("ZAR", "rand, south african rand")
        add("MXN", "peso, pesos, mexican peso, mexican pesos")
        add("CAD", "canadian dollar, canadian dollars")
        add("AUD", "australian dollar, australian dollars, aussie dollar, aussie dollars")
        add("NZD", "new zealand dollar, new zealand dollars, kiwi dollar, kiwi dollars")
        add("HKD", "hong kong dollar, hong kong dollars")
        add("SGD", "singapore dollar, singapore dollars")
        add("SEK", "krona, kronor, swedish krona, swedish kronor")
        add("NOK", "norwegian krone, norwegian kroner")
        add("DKK", "danish krone, danish kroner")
        add("HUF", "forint, forints")
        add("CZK", "koruna, korun, czech koruna, czech crowns")
        add("ILS", "shekel, shekels")
        add("AED", "dirham, dirhams")
        add("SAR", "riyal, riyals")
        add("MYR", "ringgit")
        add("THB", "baht")
        add("VND", "dong")
        add("UAH", "hryvnia, hryvnias")
        add("RON", "leu, lei")
        add("BGN", "lev, leva")
        add("IDR", "rupiah")
        add("NGN", "naira")
        for code in Locale.commonISOCurrencyCodes where code.count == 3 { table[code.lowercased()] = table[code.lowercased()] ?? code }
        return table
    }()

    private static let commonMention: String = {
        let codes = "usd|gbp|eur|jpy|cny|pln|chf|inr|krw|brl|zar|mxn|cad|aud|nzd|hkd|sgd|sek|nok|dkk|huf|czk|ils|aed|sar|myr|thb|vnd|uah|ron|bgn|idr|ngn|php|twd|rub"
        let names = words.keys.filter { $0.count > 3 || !Locale.commonISOCurrencyCodes.contains($0.uppercased()) }
            .sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return "(?:" + symbolPattern + #")|\b(?:"# + codes + "|" + names + #")\b"#
    }()

    /// Hundredths of a currency, written after the number: "50p", "99 cents".
    static let minorUnits: [String: String] = ["p": "GBP", "pence": "GBP", "penny": "GBP", "cents": "USD", "cent": "USD", "¢": "USD"]

    static let symbolPattern = symbols.map { NSRegularExpression.escapedPattern(for: $0.0) }.joined(separator: "|")
    static let wordPattern = words.keys.sorted { $0.count > $1.count }.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

    static func currency(_ written: String) -> String? {
        let text = written.trimmingCharacters(in: .whitespaces)
        return symbols.first { $0.0 == text }?.1 ?? words[text]
    }

    // MARK: - Reading

    struct Parser {
        var cursor: Cursor
        let context: AddressCalculation.Context?
        var usedMoney = false, usedDuration = false
        var operations = 0, conversions = 0
        var hoursPerWeek = 40.0
        private var depth = 0

        init(text: String, context: AddressCalculation.Context?) {
            cursor = Cursor(text)
            self.context = context
        }

        /// The finished value, written out, or nil when it isn't worth an answer of its own.
        func answer(_ value: Value, steps: Int, query: String) -> String? {
            switch value.kind {
            case .money(let code), .rate(let code, _):
                var value = value
                // An amount alone is worth showing in the person's own currency, when it's plainly money:
                // "50 eur", "$50", not "5 cup" or "10 try", which are also currency codes.
                if steps == 0 {
                    guard let context, AddressCalculation.groups(QuantityExpression.commonMention, in: query) != nil else { return nil }
                    let primary = context.primaryCurrency()
                    guard primary != code, let converted = convert(value, to: primary) else { return nil }
                    value = converted
                }
                return moneyText(value)
            case .duration:
                guard steps > 0, !value.averaged else { return nil }
                return durationText(value)
            case .number:
                guard steps > 0, value.amount.isFinite else { return nil }
                return AddressCalculation.number(value.amount, digits: 4, grouping: true)
            case .percent, .durationRate: return nil
            }
        }

        static let number = #"(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+)"#
        static let multiplier = #"(?: ?(k|thousand|mn|million|m|bn|billion|b)(?![a-z]))?"#

        mutating func expression() -> Value? {
            guard let left = sum() else { return nil }
            return chain(from: left)
        }

        /// What follows a value: conversions, and more arithmetic, read left to right.
        mutating func chain(from start: Value) -> Value? {
            var left = start
            while !cursor.isAtEnd {
                if let converted = conversion(left) { left = converted; continue }
                var copy = cursor
                if let op = copy.take(#"\s*(\+|-)\s*| (plus|minus|and|add|less|take away) "#) {
                    let symbol = op[1].isEmpty ? op[2] : op[1]
                    cursor = copy
                    guard let right = product(), let combined = combine(left, symbol, right) else { return nil }
                    left = combined; operations += 1
                    continue
                }
                if let (symbol, right) = productStep() {
                    guard let combined = combine(left, symbol, right) else { return nil }
                    left = combined; operations += 1
                    continue
                }
                break
            }
            return left
        }

        mutating func sum() -> Value? {
            guard var left = product() else { return nil }
            while true {
                var copy = cursor
                guard let op = copy.take(#"\s*(\+|-)\s*(?=[\d(.$£€¥₹₩₽₺₪฿₫₴₱₦a-z])| (plus|minus|and|add|less|take away) (?=[\d(.$£€¥₹₩₽₺₪฿₫₴₱₦a-z])"#) else { break }
                cursor = copy
                let symbol = op[1].isEmpty ? op[2] : op[1]
                guard let right = product(), let combined = combine(left, symbol, right) else { return nil }
                left = combined; operations += 1
            }
            return left
        }

        mutating func product() -> Value? {
            guard var left = unary() else { return nil }
            while let (symbol, right) = productStep() {
                guard let combined = combine(left, symbol, right) else { return nil }
                left = combined; operations += 1
            }
            return left
        }

        /// "x 3", "* 2", "/ 4", "times 3", "of £84", or a bracket straight after a number: "2(…)".
        private mutating func productStep() -> (String, Value)? {
            var copy = cursor
            let op: String
            if let match = copy.take(#"\s*(\*|/)\s*|\s*(x)\s*(?=[\d(.$£€¥₹₩₽₺₪฿₫₴₱₦])| (x|times|multiplied by|divided by|over|of|at|for|@) "#) {
                op = match.dropFirst().first { !$0.isEmpty } ?? ""
            } else if copy.peek(#" ?\("#) {
                _ = copy.take(" ")
                op = "*"
            } else { return nil }
            let saved = cursor
            cursor = copy
            guard let right = unary() else { cursor = saved; return nil }
            return (op, right)
        }

        mutating func unary() -> Value? {
            if cursor.take(#"-\s*"#) != nil {
                guard var value = unary() else { return nil }
                value.amount = -value.amount
                return value
            }
            guard var value = primary() else { return nil }
            if value.kind == .number, cursor.take(#"\s*%| ?(?:percent|pct)(?![a-z])"#) != nil { value.kind = .percent }
            return value
        }

        mutating func primary() -> Value? {
            if cursor.peek(#"\("#) {
                guard let inner = bracketed() else { return nil }
                var nested = Parser(text: inner, context: context)
                nested.depth = depth+1
                nested.hoursPerWeek = hoursPerWeek
                if depth < 6, let value = nested.expression(), nested.cursor.isAtEnd {
                    usedMoney = usedMoney || nested.usedMoney; usedDuration = usedDuration || nested.usedDuration
                    operations += nested.operations; conversions += nested.conversions
                    cursor.skip(inner.count+2)
                    return value
                }
                // A range of times in brackets is a length of time: "(9am to 5pm) x 5".
                if let seconds = CalendarCalculation(now: context?.now ?? Date(), zone: context?.zone ?? .current).rangeSeconds(inner) {
                    usedDuration = true; operations += 1
                    cursor.skip(inner.count+2)
                    return Value(amount: seconds, kind: .duration)
                }
                return nil
            }
            if var money = money() {
                usedMoney = true
                if case .money(let code) = money.kind, let period = period() { money.kind = .rate(code, period) }
                return money
            }
            // Hours and minutes: "2h 30m", "45 min". Clock-style "1:30" stays a time of day.
            if !cursor.peek(#"\d{1,3}:"#) {
                var copy = cursor
                if let span = CalendarCalculation.span(&copy), let seconds = span.fixedSeconds {
                    cursor = copy
                    usedDuration = true
                    // "37.5 hours a week"
                    if let period = period() { return Value(amount: seconds, kind: .durationRate(period)) }
                    return Value(amount: seconds, kind: .duration)
                }
                copy = cursor
                if let span = CalendarCalculation.span(&copy), span.businessDays == 0 {
                    cursor = copy
                    usedDuration = true
                    var value = Value(amount: Double(span.months)*Period.month.seconds+Double(span.days)*86400+span.seconds, kind: .duration)
                    value.averaged = true
                    return value
                }
            }
            // "2x(…)": an x straight after a number multiplies.
            if let match = cursor.take(Self.number + #"(?![\d:])(?![a-wyz])(?!x[a-z])"#), let value = Double(match[1].replacingOccurrences(of: ",", with: "")) {
                return Value(amount: value, kind: .number)
            }
            return nil
        }

        /// "an hour", "/hr", "per year", " a month", "annually", "salary": what an amount is for.
        private mutating func period() -> Period? {
            var copy = cursor
            guard let match = copy.take(#"(?: ?/ ?| per | an? | each )("# + QuantityExpression.periodWords + #")(?![a-z])| ("# + QuantityExpression.periodAdverbs + #")(?![a-z/])"#),
                  let period = Period(match[1].isEmpty ? match[2] : match[1]) else { return nil }
            cursor = copy
            return period
        }

        /// The text inside the bracket at the cursor, up to the one closing it.
        private func bracketed() -> String? {
            var level = 0
            for (offset, character) in cursor.rest.enumerated() {
                if character == "(" { level += 1 }
                if character == ")" {
                    level -= 1
                    if level == 0 { return String(cursor.rest.dropFirst().prefix(offset-1)) }
                }
            }
            return nil
        }

        /// "$56", "56 usd", "£2.5k", "56 000 usd", "1.5 million euros", "50p".
        private mutating func money() -> Value? {
            var copy = cursor
            if let match = copy.take("(" + QuantityExpression.symbolPattern + #") ?"# + Self.number + Self.multiplier + "(?: (" + QuantityExpression.wordPattern + #"))?(?![a-z\d])"#),
               let code = QuantityExpression.currency(match[1]), let amount = Self.amount(match[2], match[3]) {
                cursor = copy
                return Value(amount: amount, kind: .money(match[4].isEmpty ? code : QuantityExpression.currency(match[4]) ?? code))
            }
            copy = cursor
            let spaced = #"(\d{1,3}(?: \d{3})+(?:\.\d+)?)"#
            if let match = copy.take("(?:" + spaced + "|" + Self.number + ")" + Self.multiplier + " ?(" + QuantityExpression.symbolPattern + "|" + QuantityExpression.wordPattern + #")(?![a-z\d])"#),
               let code = QuantityExpression.currency(match[4]),
               let amount = Self.amount(match[1].isEmpty ? match[2] : match[1].replacingOccurrences(of: " ", with: ""), match[3]) {
                cursor = copy
                return Value(amount: amount, kind: .money(code))
            }
            copy = cursor
            if let match = copy.take(Self.number + #" ?(p|pence|penny|cents?|¢)(?![a-z\d])"#),
               let code = QuantityExpression.minorUnits[match[2]], let amount = Double(match[1].replacingOccurrences(of: ",", with: "")) {
                cursor = copy
                return Value(amount: amount/100, kind: .money(code))
            }
            return nil
        }

        private static func amount(_ digits: String, _ multiplier: String) -> Double? {
            guard let value = Double(digits.replacingOccurrences(of: ",", with: "")) else { return nil }
            switch multiplier {
            case "k", "thousand": return value*1e3
            case "m", "mn", "million": return value*1e6
            case "b", "bn", "billion": return value*1e9
            default: return value
            }
        }

        /// "to gbp", "in euros and yen", "in hours", "to h:mm".
        private mutating func conversion(_ value: Value) -> Value? {
            var copy = cursor
            // Pay for another period: "to monthly", "per hour", "as an annual salary", "/day".
            if case .rate(let code, let from) = value.kind,
               let match = copy.take(#"(?: (?:then )?(?:to|in|into|as)(?: the)?)?(?: (?:an?|per|each) | ?/ ?| )(?:("# + QuantityExpression.periodWords + ")|(" + QuantityExpression.periodAdverbs + #"))(?: (?:rate|wage|pay|salary|income|earnings))?(?![a-z/])"#),
               let to = Period(match[1].isEmpty ? match[2] : match[1]) {
                var converted = value
                converted.amount = value.amount*from.perYear(hoursPerWeek: hoursPerWeek)/to.perYear(hoursPerWeek: hoursPerWeek)
                converted.kind = .rate(code, to)
                converted.assumption = from.assumption(to: to, hoursPerWeek: hoursPerWeek) ?? value.assumption
                cursor = copy; conversions += 1
                return converted
            }
            copy = cursor
            guard copy.take(#" (?:then )?(?:to|in|into|as)(?: the)? |, (?:then )?(?:to|in|into|as) "#) != nil else { return nil }
            switch value.kind {
            case .money, .number, .rate:
                let target = "(" + QuantityExpression.symbolPattern + "|" + QuantityExpression.wordPattern + ")"
                guard let match = copy.take(target + "((?:(?:,? and |, | & | / )" + target + ")*)" + #"(?![a-z\d])"#),
                      let first = QuantityExpression.currency(match[1]) else { return nil }
                var codes = [first]
                var rest = Cursor(match[2])
                while let next = rest.take(#"(?:,? and |, | & | / )("# + QuantityExpression.symbolPattern + "|" + QuantityExpression.wordPattern + ")"),
                      let code = QuantityExpression.currency(next[1]) { codes.append(code) }
                guard value.kind != .number, var converted = convert(value, to: first) else { return nil }
                converted.currencies = codes
                cursor = copy; conversions += 1; usedMoney = true
                return converted
            case .duration:
                guard !value.averaged, let match = copy.take(#"(hours,? minutes,? and seconds|hours,? minutes and seconds|hours and minutes|hours minutes|minutes and seconds|days and hours|h:mm:ss|hh:mm:ss|h:mm|hh:mm|hms|seconds|secs|minutes|mins|hours|hrs|days|weeks)(?![a-z:])"#) else { return nil }
                var converted = value
                switch match[1] {
                case "hours and minutes", "hours minutes": converted.durationFormat = nil
                case "minutes and seconds", "hms", "hours, minutes and seconds", "hours minutes and seconds", "hours, minutes, and seconds": converted.durationFormat = nil
                default: converted.durationFormat = match[1]
                }
                cursor = copy; conversions += 1
                return converted
            case .percent, .durationRate: return nil
            }
        }

        func convert(_ value: Value, to code: String) -> Value? {
            let from: String
            switch value.kind {
            case .money(let own), .rate(let own, _): from = own
            default: return nil
            }
            if from == code { return value }
            guard let rates = context?.rates(), let amount = rates.convert(value.amount, from: from, to: code) else { return nil }
            var converted = value
            converted.amount = amount
            if case .rate(_, let period) = value.kind { converted.kind = .rate(code, period) } else { converted.kind = .money(code) }
            return converted
        }

        private func combine(_ left: Value, _ op: String, _ right: Value) -> Value? {
            // Months and years only multiply pay: "£50k a year for 6 months".
            if left.averaged || right.averaged {
                let pay = { (value: Value) -> Bool in if case .rate = value.kind { return true } else { return false } }
                guard ["*", "x", "times", "multiplied by", "at", "@", "for"].contains(op), pay(left) || pay(right) else { return nil }
            }
            var result = left
            result.durationFormat = left.durationFormat ?? right.durationFormat
            switch op {
            case "+", "plus", "and", "add", "-", "minus", "less", "take away":
                let sign: Double = ["+", "plus", "and", "add"].contains(op) ? 1 : -1
                switch (left.kind, right.kind) {
                case (.percent, _): return nil
                case (_, .percent):
                    result.amount = left.amount*(1+sign*right.amount/100)
                case (.number, .number), (.duration, .duration):
                    result.amount = left.amount+sign*right.amount
                case (.money, .money):
                    guard case .money(let code) = left.kind, let other = convert(right, to: code) else { return nil }
                    result.amount = left.amount+sign*other.amount
                case (.money, .number), (.rate, .number):
                    result.amount = left.amount+sign*right.amount
                case (.number, .money), (.number, .rate):
                    result = right; result.amount = left.amount+sign*right.amount
                case (.rate(let code, let period), .rate):
                    guard let other = convert(right, to: code), let same = per(other, period) else { return nil }
                    result.amount = left.amount+sign*same.amount
                default: return nil
                }
            case "at", "@", "for":
                // "40 hours at £15 an hour", "3 at £4.50", "£15 an hour for 37.5 hours (a week)"
                switch (left.kind, right.kind) {
                case (.duration, .rate), (.rate, .duration), (.rate, .durationRate), (.durationRate, .rate): return combine(left, "*", right)
                case (.number, .money) where op != "for": return combine(left, "*", right)
                default: return nil
                }
            case "*", "x", "times", "multiplied by", "of":
                switch (left.kind, right.kind) {
                case (.percent, .percent): return nil
                case (.percent, _): result = right; result.amount = left.amount/100*right.amount
                case (_, .percent): result.amount = left.amount*right.amount/100
                // Pay for a length of time is money: "£15/hr x 37.5 hours"; for some time each week, pay each week.
                case (.rate(let code, let period), .duration), (.duration, .rate(let code, let period)):
                    let seconds = left.kind == .duration ? left.amount : right.amount
                    let pay = left.kind == .duration ? right.amount : left.amount
                    result = Value(amount: pay*seconds/period.seconds, kind: .money(code))
                case (.rate(let code, let period), .durationRate(let each)), (.durationRate(let each), .rate(let code, let period)):
                    let seconds = left.kind == .durationRate(each) ? left.amount : right.amount
                    let pay = left.kind == .durationRate(each) ? right.amount : left.amount
                    result = Value(amount: pay*seconds/period.seconds, kind: .rate(code, each))
                // A count of periods: "£5 a month x 12", "£15/hr x 40".
                case (.rate(let code, _), .number): result = Value(amount: left.amount*right.amount, kind: .money(code))
                case (.number, .rate(let code, _)): result = Value(amount: left.amount*right.amount, kind: .money(code))
                case (.number, _): result = right; result.amount = left.amount*right.amount
                case (_, .number): result.amount = left.amount*right.amount
                default: return nil
                }
                guard op != "of" || left.kind == .percent else { return nil }
            case "/", "divided by", "over":
                guard right.amount != 0 else { return nil }
                switch (left.kind, right.kind) {
                case (_, .number): result.amount = left.amount/right.amount
                case (_, .percent): result.amount = left.amount/(right.amount/100)
                case (.duration, .duration): result = Value(amount: left.amount/right.amount, kind: .number)
                case (.money(let code), .money):
                    guard let other = convert(right, to: code) else { return nil }
                    result = Value(amount: left.amount/other.amount, kind: .number)
                // Money over time is pay: "£600 / 40 hours" is £15 an hour; "£2,000 / 4 weeks", £500 a week.
                case (.money(let code), .duration):
                    let period: Period = right.amount.truncatingRemainder(dividingBy: Period.week.seconds) == 0 ? .week
                        : right.amount.truncatingRemainder(dividingBy: Period.day.seconds) == 0 ? .day : .hour
                    result = Value(amount: left.amount/right.amount*period.seconds, kind: .rate(code, period))
                // Money over pay is how long it takes: "£600 / £15 an hour" is 40 hours.
                case (.money(let code), .rate(_, let period)):
                    guard let other = convert(right, to: code), other.amount != 0 else { return nil }
                    result = Value(amount: left.amount/other.amount*period.seconds, kind: .duration)
                case (.rate(let code, let period), .rate):
                    guard let other = convert(right, to: code), let same = per(other, period), same.amount != 0 else { return nil }
                    result = Value(amount: left.amount/same.amount, kind: .number)
                default: return nil
                }
            default: return nil
            }
            guard result.amount.isFinite else { return nil }
            return result
        }

        /// Pay for `period` instead, over a working year.
        private func per(_ value: Value, _ period: Period) -> Value? {
            guard case .rate(let code, let from) = value.kind else { return nil }
            var moved = value
            moved.amount = value.amount*from.perYear(hoursPerWeek: hoursPerWeek)/period.perYear(hoursPerWeek: hoursPerWeek)
            moved.kind = .rate(code, period)
            return moved
        }

        /// Money, or pay with the period it's for, in each currency asked for.
        func moneyText(_ value: Value) -> String? {
            let code: String, suffix: String
            switch value.kind {
            case .money(let own): code = own; suffix = ""
            case .rate(let own, let period): code = own; suffix = " " + period.word
            default: return nil
            }
            guard value.amount.isFinite, let context else { return nil }
            let codes = value.currencies.isEmpty ? [code] : value.currencies
            let texts = codes.compactMap { target -> String? in
                guard let converted = convert(value, to: target) else { return nil }
                return CurrencyAmounts.format(converted.amount, in: target, locale: context.locale) + suffix
            }
            guard texts.count == codes.count else { return nil }
            return (texts + [value.assumption].compactMap { $0 }).joined(separator: " · ")
        }
    }
}
