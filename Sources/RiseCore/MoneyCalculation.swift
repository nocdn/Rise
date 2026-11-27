import Foundation

/// Everyday sums written as words: tips and splitting a bill, discounts, VAT, and percentage change.
/// Amounts may name a currency and end in a conversion: "15% tip on $84 split 3 ways in gbp".
enum MoneyCalculation {
    private struct Amount {
        var value: Double
        var code: String?
        /// The symbol written before the number, to write results the same way: "£".
        var symbol: String
    }

    private static let number = #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?|\.\d+"#
    private static var amount: String {
        "((?:" + QuantityExpression.symbolPattern + ")? ?(?:" + number + ")(?: ?(?:k|m|bn))?(?: ?(?:" + QuantityExpression.symbolPattern + "|" + QuantityExpression.wordPattern + ")(?![a-z]))?)"
    }
    private static let percent = #"(\d{1,3}(?:\.\d+)?) ?(?:%|percent|per cent)"#
    private static let count = #"(\d{1,4}|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#
    private static let split = #"(?: (?:then )?(?:split|divided|shared)(?: (?:between|among|by|into|in))? "# + count + #"(?: ways?| people| persons| of us)?| (?:between|among|for) "# + count + #" (?:people|persons|of us))?"#
    private static var conversion: String {
        "(?: (?:to|in|into|as) (" + QuantityExpression.symbolPattern + "|" + QuantityExpression.wordPattern + "))?"
    }

    static func evaluate(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        tip(query, context) ?? split(query, context) ?? discount(query, context) ?? tax(query, context) ?? changeBy(query, context) ?? percentChange(query, context)
    }

    // MARK: - Tips and splitting

    private static func tip(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        let forms: [(String, Int, Int)] = [
            ("^" + percent + " tip (?:on|for|of) " + amount, 1, 2),
            ("^tip (?:of )?" + percent + " (?:on|for) " + amount, 1, 2),
            ("^tip (?:on|for) " + amount + " (?:at |of )?" + percent, 2, 1),
            ("^" + amount + " (?:\\+|plus|with|and|add) " + percent + " tip", 2, 1),
            ("^" + amount + " tip " + percent, 2, 1)
        ]
        for (form, percentGroup, amountGroup) in forms {
            guard let match = AddressCalculation.groups(form + split + conversion + "$", in: query),
                  let rate = Double(match[percentGroup]), let bill = parse(match[amountGroup]) else { continue }
            let people = people(match[3].isEmpty ? match[4] : match[3])
            let target = match[5]
            let tip = bill.value*rate/100
            if let people {
                guard people > 0, let each = write((bill.value+tip)/Double(people), bill, target, context) else { return nil }
                return AddressCalculation(each + " each, including tip")
            }
            guard let tipText = write(tip, bill, target, context), let total = write(bill.value+tip, bill, target, context) else { return nil }
            return AddressCalculation("\(tipText) tip · \(total) total")
        }
        return nil
    }

    private static func split(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        guard let match = AddressCalculation.groups("^(?:split )?" + amount + #" (?:(?:split|divided|shared|between|among|by|into|/)(?: (?:between|among|by|into|in))? )?"# + count + #"(?: ways?| people| persons| of us)?"# + conversion + "$", in: query),
              query.hasPrefix("split") || query.contains(" split") || query.contains(" divided") || query.contains(" shared") || query.contains(" ways") || query.contains(" people") || query.contains(" persons") || query.contains(" of us") || query.contains(" between "),
              let bill = parse(match[1]), let people = people(match[2]), people > 0,
              let each = write(bill.value/Double(people), bill, match[3], context) else { return nil }
        return AddressCalculation(each + " each")
    }

    // MARK: - Discounts and tax

    private static func discount(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        var match = AddressCalculation.groups("^" + percent + " off (?:of )?" + amount + conversion + "$", in: query)
        if let found = match { match = [found[0], found[1], found[2], found[3]] }
        else if let found = AddressCalculation.groups("^" + amount + " (?:with |at |less |minus |after |after a |with a )?" + percent + " (?:off|discount)" + conversion + "$", in: query) {
            match = [found[0], found[2], found[1], found[3]]
        }
        guard let match, let rate = Double(match[1]), rate <= 100, let price = parse(match[2]) else { return nil }
        let saving = price.value*rate/100
        guard let paid = write(price.value-saving, price, match[3], context), let saved = write(saving, price, match[3], context) else { return nil }
        return AddressCalculation("\(paid) · save \(saved)")
    }

    /// "84 + 20% vat" adds it; "100.80 minus 20% vat" and "remove 20% vat from 100.80" take it back out.
    private static func tax(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        let name = #"(vat|tax|gst|sales tax|mwst|tva|iva)"#
        var adds = true
        var parts: (rate: String, amount: String, name: String, target: String)?
        if let match = AddressCalculation.groups("^" + amount + " (?:\\+|plus|add|with|inc|incl|including) " + percent + " " + name + conversion + "$", in: query) {
            parts = (match[2], match[1], match[3], match[4])
        } else if let match = AddressCalculation.groups("^" + percent + " " + name + " (?:on|for|of) " + amount + conversion + "$", in: query) {
            parts = (match[1], match[3], match[2], match[4])
        } else if let match = AddressCalculation.groups("^" + amount + " (?:-|minus|less|without|ex|excl|excluding|before|remove|net of) " + percent + " " + name + conversion + "$", in: query) {
            parts = (match[2], match[1], match[3], match[4]); adds = false
        } else if let match = AddressCalculation.groups("^(?:remove|take off|minus|subtract|deduct|strip|take out) " + percent + " " + name + " (?:from )?" + amount + conversion + "$", in: query) {
            parts = (match[1], match[3], match[2], match[4]); adds = false
        }
        guard let parts, let rate = Double(parts.rate), let price = parse(parts.amount) else { return nil }
        let label = parts.name.count <= 4 ? parts.name.uppercased() : parts.name
        let net = adds ? price.value : price.value/(1+rate/100)
        let duty = net*rate/100
        guard let shown = write(adds ? net+duty : net, price, parts.target, context), let dutyText = write(duty, price, parts.target, context) else { return nil }
        return AddressCalculation("\(shown) · \(dutyText) \(label)")
    }

    // MARK: - Percentages

    /// "increase £50 by 10%", "reduce 80 by 25%", "raise 32,000 by 3.5%".
    private static func changeBy(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        guard let match = AddressCalculation.groups(#"^(increase|raise|grow|decrease|reduce|lower|cut|drop) "# + amount + " by " + percent + conversion + "$", in: query),
              let rate = Double(match[3]), let start = parse(match[2]) else { return nil }
        let sign: Double = ["increase", "raise", "grow"].contains(match[1]) ? 1 : -1
        guard let result = write(start.value*(1+sign*rate/100), start, match[4], context),
              let change = write(start.value*rate/100, start, match[4], context) else { return nil }
        return AddressCalculation("\(result) · \(sign > 0 ? "+" : "-")\(change)")
    }

    private static func percentChange(_ query: String, _ context: AddressCalculation.Context) -> AddressCalculation? {
        // Amounts of money compare as their numbers, once in one currency: "£80 to $120 percent change".
        let value = "(-?" + amount.dropFirst().dropLast() + ")"
        func numbers(_ texts: [String]) -> [Double]? {
            let parsed = texts.compactMap { text -> Amount? in
                guard var amount = parse(text.hasPrefix("-") ? String(text.dropFirst()) : text) else { return nil }
                if text.hasPrefix("-") { amount.value = -amount.value }
                return amount
            }
            guard parsed.count == texts.count else { return nil }
            let code = parsed.first { $0.code != nil }?.code
            let values = parsed.compactMap { amount -> Double? in
                guard let code, let own = amount.code, own != code else { return amount.value }
                return context.rates()?.convert(amount.value, from: own, to: code)
            }
            return values.count == parsed.count ? values : nil
        }
        if let match = AddressCalculation.groups("^(?:percent(?:age)?|%) (?:change|increase|decrease|difference|growth)(?: (?:from|between))? " + value + " (?:to|and) " + value + "$|^(?:change|increase|decrease|growth)(?: in percent| percent)? from " + value + " to " + value + "$|^" + value + " to " + value + " (?:percent(?:age)?|%) (?:change|increase|decrease)$", in: query) {
            guard let numbers = numbers(match.dropFirst().filter { !$0.isEmpty }), numbers.count == 2, numbers[0] != 0 else { return nil }
            let change = (numbers[1]-numbers[0])/abs(numbers[0])*100
            if abs(change) < 0.0005 { return AddressCalculation("No change") }
            return AddressCalculation("\(AddressCalculation.number(abs(change), digits: 2))% \(change > 0 ? "increase" : "decrease")")
        }
        if let match = AddressCalculation.groups("^" + value + " (?:is )?what (?:percent|%|percentage) of " + value + "$|^what (?:percent|%|percentage) of " + value + " is " + value + "$|^what (?:percent|%|percentage) is " + value + " of " + value + "$", in: query) {
            guard let numbers = numbers(match.dropFirst().filter { !$0.isEmpty }), numbers.count == 2 else { return nil }
            let (part, whole) = query.hasPrefix("what percent of") || query.hasPrefix("what % of") || query.hasPrefix("what percentage of") ? (numbers[1], numbers[0]) : (numbers[0], numbers[1])
            guard whole != 0 else { return nil }
            return AddressCalculation(AddressCalculation.number(part/whole*100, digits: 2) + "%")
        }
        return nil
    }

    // MARK: - Amounts

    private static func parse(_ text: String) -> Amount? {
        guard let match = AddressCalculation.groups("^(" + QuantityExpression.symbolPattern + ")? ?(" + number + ")(?: ?(k|m|bn))?(?: ?(" + QuantityExpression.symbolPattern + "|" + QuantityExpression.wordPattern + "))?$", in: text),
              var value = Double(match[2].replacingOccurrences(of: ",", with: "")) else { return nil }
        value *= match[3] == "k" ? 1e3 : match[3] == "m" ? 1e6 : match[3] == "bn" ? 1e9 : 1
        let code = QuantityExpression.currency(match[4]) ?? QuantityExpression.currency(match[1])
        return Amount(value: value, code: code, symbol: match[1])
    }

    private static func people(_ text: String) -> Int? {
        guard !text.isEmpty else { return nil }
        return Int(text) ?? ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12][text]
    }

    /// An amount as written: with the symbol typed before it, in a named currency as people read it,
    /// or converted when asked.
    private static func write(_ value: Double, _ like: Amount, _ target: String, _ context: AddressCalculation.Context) -> String? {
        if !target.isEmpty {
            guard let to = QuantityExpression.currency(target), let from = like.code,
                  let converted = from == to ? value : context.rates()?.convert(value, from: from, to: to) else { return nil }
            return CurrencyAmounts.format(converted, in: to, locale: context.locale)
        }
        if like.symbol.isEmpty, let code = like.code { return CurrencyAmounts.format(value, in: code, locale: context.locale) }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        formatter.usesGroupingSeparator = true; formatter.groupingSeparator = ","; formatter.groupingSize = 3
        return like.symbol + (formatter.string(from: NSNumber(value: value)) ?? "")
    }
}
