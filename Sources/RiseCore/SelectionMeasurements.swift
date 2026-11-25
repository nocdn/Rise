import Foundation

/// What a measurement measures.
public enum MeasurementKind: String, Sendable {
    case mass, length, temperature, speed

    /// The symbol a converted measurement heads the menu with.
    public var symbol: String {
        switch self {
        case .mass: "scalemass"
        case .length: "ruler"
        case .temperature: "thermometer.medium"
        case .speed: "gauge.with.needle"
        }
    }
}

/// A unit Rise reads in text, and writes measurements in.
public enum MeasureUnit: String, CaseIterable, Sendable {
    case millimetres, centimetres, metres, kilometres, inches, feet, yards, miles
    case grams, kilograms, tonnes, ounces, pounds, stones
    case celsius, fahrenheit, kelvin
    case kilometresPerHour, metresPerSecond, milesPerHour, knots

    public var kind: MeasurementKind {
        switch self {
        case .millimetres, .centimetres, .metres, .kilometres, .inches, .feet, .yards, .miles: .length
        case .grams, .kilograms, .tonnes, .ounces, .pounds, .stones: .mass
        case .celsius, .fahrenheit, .kelvin: .temperature
        case .kilometresPerHour, .metresPerSecond, .milesPerHour, .knots: .speed
        }
    }

    var dimension: Dimension {
        switch self {
        case .millimetres: UnitLength.millimeters
        case .centimetres: UnitLength.centimeters
        case .metres: UnitLength.meters
        case .kilometres: UnitLength.kilometers
        case .inches: UnitLength.inches
        case .feet: UnitLength.feet
        case .yards: UnitLength.yards
        case .miles: UnitLength.miles
        case .grams: UnitMass.grams
        case .kilograms: UnitMass.kilograms
        case .tonnes: UnitMass.metricTons
        case .ounces: UnitMass.ounces
        case .pounds: UnitMass.pounds
        case .stones: UnitMass.stones
        case .celsius: UnitTemperature.celsius
        case .fahrenheit: UnitTemperature.fahrenheit
        case .kelvin: UnitTemperature.kelvin
        case .kilometresPerHour: UnitSpeed.kilometersPerHour
        case .metresPerSecond: UnitSpeed.metersPerSecond
        case .milesPerHour: UnitSpeed.milesPerHour
        case .knots: UnitSpeed.knots
        }
    }

    var isMetric: Bool {
        [.millimetres, .centimetres, .metres, .kilometres, .grams, .kilograms, .tonnes, .celsius, .kelvin,
         .kilometresPerHour, .metresPerSecond].contains(self)
    }

    /// The units a measurement of `kind` can be shown in, metric first.
    static func units(of kind: MeasurementKind) -> [MeasureUnit] { allCases.filter { $0.kind == kind } }

    /// The unit `written` names, as `SelectionMeasurements` matched it.
    static func named(_ written: String) -> MeasureUnit? {
        let token = written.replacingOccurrences(of: "[ \\u00a0\\u202f]+", with: " ", options: .regularExpression)
        switch token {
        case "m": return .metres
        case "g": return .grams
        case "in", "″": return .inches
        case "′": return .feet
        case "℃": return .celsius
        case "℉": return .fahrenheit
        default: break
        }
        let name = token.lowercased().replacingOccurrences(of: "[º˚]", with: "°", options: .regularExpression)
        if name.contains("per hour") { return name.hasPrefix("mile") ? .milesPerHour : .kilometresPerHour }
        if name.contains("per second") { return .metresPerSecond }
        if name.hasPrefix("°") || name.hasPrefix("degree") {
            guard let last = name.split(whereSeparator: { $0 == " " || $0 == "°" }).last else { return nil }
            return last.hasPrefix("c") ? .celsius : last.hasPrefix("f") ? .fahrenheit : nil
        }
        switch name {
        case "km/h", "km/hr", "kmh", "kph", "kmph": return .kilometresPerHour
        case "mph": return .milesPerHour
        case "m/s": return .metresPerSecond
        case "knot", "knots", "kts": return .knots
        case "celsius", "centigrade": return .celsius
        case "fahrenheit": return .fahrenheit
        case "kelvin": return .kelvin
        case "mm": return .millimetres
        case "cm": return .centimetres
        case "km", "kms": return .kilometres
        case "inch", "inches": return .inches
        case "ft", "foot", "feet": return .feet
        case "yd", "yds", "yard", "yards": return .yards
        case "mi", "mile", "miles": return .miles
        case "kg", "kgs", "kilo", "kilos": return .kilograms
        case "oz", "ounce", "ounces": return .ounces
        case "lb", "lbs", "pound", "pounds": return .pounds
        case "stone", "stones": return .stones
        case "tonne", "tonnes": return .tonnes
        default: break
        }
        if name.hasPrefix("millimet") { return .millimetres }
        if name.hasPrefix("centimet") { return .centimetres }
        if name.hasPrefix("kilomet") { return .kilometres }
        if name.hasPrefix("met") { return .metres }
        if name.hasPrefix("kilogram") { return .kilograms }
        if name.hasPrefix("gram") { return .grams }
        return nil
    }
}

/// The units measurements are shown in: the person's choice, or their region's until they choose.
public enum PreferredUnits: String, CaseIterable, Sendable {
    /// Kilograms, kilometres and °C.
    case metric
    /// Pounds, miles and °F.
    case us
    /// Britain's: metric, but miles and mph on the road.
    case uk

    public static let key = "Rise.PreferredUnits"

    public static func current(in defaults: UserDefaults = .standard, locale: Locale = .current) -> PreferredUnits {
        defaults.string(forKey: key).flatMap(PreferredUnits.init(rawValue:)) ?? region(locale)
    }
    public static func set(_ units: PreferredUnits, in defaults: UserDefaults = .standard) { defaults.set(units.rawValue, forKey: key) }

    /// What the person's region measures in, as their Language & Region settings say.
    public static func region(_ locale: Locale) -> PreferredUnits {
        switch locale.measurementSystem {
        case .us: .us
        case .uk: .uk
        default: .metric
        }
    }

    public var title: String {
        switch self {
        case .metric: "Metric"
        case .us: "US"
        case .uk: "UK"
        }
    }

    /// What it measures in, to say beside its name.
    public var detail: String {
        switch self {
        case .metric: "Kilograms, kilometres, °C"
        case .us: "Pounds, miles, °F"
        case .uk: "Kilograms, miles, °C"
        }
    }

    /// Whether a measurement in `unit` is already one of these, with nothing to convert.
    public func uses(_ unit: MeasureUnit) -> Bool {
        switch self {
        case .metric: unit.isMetric
        case .us: [.inches, .feet, .yards, .miles, .ounces, .pounds, .fahrenheit, .milesPerHour].contains(unit)
        case .uk: unit.isMetric && unit != .kilometres && unit != .kilometresPerHour
            || [.yards, .miles, .stones, .milesPerHour].contains(unit)
        }
    }

    /// The unit `value` in `unit` reads best in: kilometres for a road's distance, centimetres
    /// for a shelf's, a height in feet and inches.
    func target(for unit: MeasureUnit, largest value: Double) -> MeasurementTarget {
        let base = Measurement(value: abs(value), unit: unit.dimension).converted(to: unit.kind.baseDimension).value
        switch unit.kind {
        case .length:
            let road = unit == .kilometres || unit == .miles
            func metric() -> MeasurementTarget {
                .unit(road || base >= 1000 ? .kilometres : base >= 1 ? .metres : base >= 0.01 ? .centimetres : .millimetres)
            }
            switch self {
            case .metric: return metric()
            case .uk: return road || base >= 1000 ? .unit(.miles) : metric()
            case .us:
                if road || base >= 1609.344 { return .unit(.miles) }
                if base >= 3.048 { return .unit(.feet) }
                return base >= 0.3048 ? .feetAndInches : .unit(.inches)
            }
        case .mass:
            if self == .us { return .unit(base >= 0.45359237 ? .pounds : .ounces) }
            return .unit(base >= 1 ? .kilograms : .grams)
        case .temperature: return .unit(self == .us ? .fahrenheit : .celsius)
        case .speed: return .unit(self == .metric ? .kilometresPerHour : .milesPerHour)
        }
    }
}

enum MeasurementTarget: Equatable { case unit(MeasureUnit), feetAndInches }

extension MeasurementKind {
    var baseDimension: Dimension {
        switch self {
        case .mass: UnitMass.kilograms
        case .length: UnitLength.meters
        case .temperature: UnitTemperature.kelvin
        case .speed: UnitSpeed.metersPerSecond
        }
    }
}

/// A measurement selected on a page: one value, a range's two or a size's sides, in the unit it was written in.
public struct SelectedMeasurement: Equatable, Sendable {
    public enum Joining: Sendable { case single, range, sides }
    public let values: [Double]
    public let unit: MeasureUnit
    public let joining: Joining
    public let written: String
    /// Whether any value was written with a fraction, so a temperature keeps one.
    let precise: Bool
}

/// A measurement converted into the person's units, with what it is in every other, for the menu.
public struct MeasurementConversion: Sendable {
    public let measurement: SelectedMeasurement
    /// "3.11 mi"
    public let converted: String
    /// How the menu heads it: the conversion, and of several, what each was written as.
    public let label: String
    /// The measurement in each other unit: "Feet", "16,404 ft".
    public let others: [(name: String, value: String)]
}

/// Weights, distances and lengths, temperatures and speeds in selected text, for the selection
/// menu to show in the person's own units, as it does an amount in their currency: "5 km"
/// selected reads "3.11 mi" to someone in the US, and "180 cm" "5 ft 11 in".
public enum SelectionMeasurements {
    static let maximumLength = 400, maximumMeasurements = 3

    /// The measurements in `text`, earliest first.
    public static func find(in text: String) -> [SelectedMeasurement] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumLength else { return [] }
        return matches(in: text).prefix(maximumMeasurements).map(\.measurement)
    }

    /// Every measurement in `text`, where it's written, earliest first.
    static func matches(in text: String) -> [(range: NSRange, measurement: SelectedMeasurement)] {
        guard text.contains(where: \.isNumber) else { return [] }
        let string = text as NSString, whole = NSRange(location: 0, length: string.length)
        var found: [(range: NSRange, measurement: SelectedMeasurement)] = []
        // "5′11″", "5 ft 11 in": a height.
        for match in heights.matches(in: text, range: whole) {
            guard let feet = Double(string.substring(with: match.range(at: 1))),
                  let inches = number(string.substring(with: match.range(at: 2))) else { continue }
            found.append((match.range, SelectedMeasurement(values: [feet+inches/12], unit: .feet, joining: .single,
                                                           written: string.substring(with: match.range), precise: true)))
        }
        for match in pattern.matches(in: text, range: whole) {
            guard !found.contains(where: { NSIntersectionRange($0.range, match.range).length > 0 }),
                  let unit = MeasureUnit.named(string.substring(with: match.range(at: 2))) else { continue }
            let numbersRange = match.range(at: 1), numbersText = string.substring(with: numbersRange)
            var numbers = numberPattern.matches(in: numbersText, range: NSRange(location: 0, length: (numbersText as NSString).length))
            guard !numbers.isEmpty else { continue }
            let joined = (numbersText as NSString).substring(from: NSMaxRange(numbers[0].range))
            var joining: SelectedMeasurement.Joining = numbers.count == 1 ? .single
                : joined.range(of: "[x×]|\\sby\\s", options: .regularExpression) != nil ? .sides : .range
            var range = match.range
            // Two of a weight are two packs of it, not a size: "2 x 500 g" is 500 g.
            if joining == .sides && unit.kind != .length || joining == .range && numbers.count > 2 {
                let last = numbers[numbers.count-1]
                numbers = [last]; joining = .single
                let start = numbersRange.location+last.range.location
                range = NSRange(location: start, length: NSMaxRange(match.range)-start)
            }
            let written = numbers.map { (numbersText as NSString).substring(with: $0.range) }
            let values = written.compactMap(number)
            guard values.count == written.count else { continue }
            found.append((range, SelectedMeasurement(values: values, unit: unit, joining: joining, written: string.substring(with: range),
                                                     precise: written.contains { $0.contains(where: { $0 == "." || $0 == "," }) })))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// What Replace on Page changes in a passage of the page: each measurement in other units, in `units`.
    public static func edits(in text: String, to units: PreferredUnits, locale: Locale = .current) -> [PageTextConversion.Edit] {
        matches(in: text).compactMap { range, measurement in
            guard !units.uses(measurement.unit) else { return nil }
            let target = units.target(for: measurement.unit, largest: measurement.values.map(abs).max() ?? 0)
            return PageTextConversion.Edit(start: range.location, end: NSMaxRange(range), text: format(measurement, in: target, locale: locale))
        }
    }

    public static let restoredMessage = "Original measurements restored"
    /// What Replace on Page did: how many measurements it rewrote into `units`.
    public static func message(_ count: Int, in units: PreferredUnits) -> String {
        count == 0 ? "No other measurements to replace"
            : "Replaced \(count) \(count == 1 ? "measurement" : "measurements") with \(units == .metric ? "metric" : units.title) units"
    }

    /// Each measurement in `text` that isn't in `units` already, converted into them; with
    /// `includingOwn`, as on a page Replace on Page has rewritten, those that are too.
    public static func conversions(in text: String, to units: PreferredUnits, includingOwn: Bool = false,
                                   locale: Locale = .current) -> [MeasurementConversion] {
        let found = find(in: text).filter { includingOwn || !units.uses($0.unit) }
        return found.compactMap { measurement in
            let target = units.target(for: measurement.unit, largest: measurement.values.map(abs).max() ?? 0)
            let converted = format(measurement, in: target, locale: locale)
            var excluded: Set<MeasureUnit> = [measurement.unit]
            if case .unit(let unit) = target { excluded.insert(unit) }
            let others = MeasureUnit.units(of: measurement.unit.kind).filter { !excluded.contains($0) }.compactMap { unit -> (name: String, value: String)? in
                let values = measurement.values.map { convert($0, from: measurement.unit, to: unit) }
                // Not a road's length in millimetres, nor a hair's in miles.
                if unit.kind != .temperature, values.contains(where: { abs($0) >= 100_000 || $0 != 0 && abs($0) < 0.01 }) { return nil }
                return (name(of: unit, locale: locale), format(measurement, in: .unit(unit), locale: locale))
            }
            let label = found.count > 1 ? "\(measurement.written) → \(converted)" : converted
            return MeasurementConversion(measurement: measurement, converted: converted, label: label, others: others)
        }
    }

    static func convert(_ value: Double, from: MeasureUnit, to: MeasureUnit) -> Double {
        Measurement(value: value, unit: from.dimension).converted(to: to.dimension).value
    }

    /// `measurement` in `target`, as the person's region writes it: "3.11 mi", "68–77°F", "30 × 20 cm".
    static func format(_ measurement: SelectedMeasurement, in target: MeasurementTarget, locale: Locale) -> String {
        let separator = measurement.joining == .sides ? " × " : "–"
        guard case .unit(let unit) = target else {
            return measurement.values.map { feetAndInches(convert($0, from: measurement.unit, to: .inches), locale: locale) }
                .joined(separator: measurement.joining == .sides ? " × " : " – ")
        }
        let values = measurement.values.map { convert($0, from: measurement.unit, to: unit) }
        let largest = values.map(abs).max() ?? 0
        let digits = switch unit.kind {
        // A temperature as precisely as it was written; a speed, as a speedometer shows it.
        case .temperature: measurement.precise ? 1 : 0
        case .speed: largest >= 10 ? 0 : 1
        default: largest >= 100 ? 0 : largest >= 10 ? 1 : 2
        }
        let numbers = NumberFormatter()
        numbers.locale = locale; numbers.numberStyle = .decimal
        numbers.minimumFractionDigits = 0; numbers.maximumFractionDigits = digits
        let formatter = measurementFormatter(locale: locale, numbers: numbers)
        let last = formatter.string(from: Measurement(value: values[values.count-1], unit: unit.dimension))
        let leading = values.dropLast().map { numbers.string(from: NSNumber(value: $0)) ?? "\($0)" }
        return (leading + [last]).joined(separator: separator)
    }

    /// A height in feet and inches: "5 ft 11 in".
    static func feetAndInches(_ inches: Double, locale: Locale) -> String {
        let total = Int(inches.rounded()), feet = total/12, rest = total%12
        let numbers = NumberFormatter(); numbers.locale = locale; numbers.maximumFractionDigits = 0
        let formatter = measurementFormatter(locale: locale, numbers: numbers)
        let foot = formatter.string(from: Measurement(value: Double(feet), unit: UnitLength.feet))
        return rest == 0 ? foot : foot + " " + formatter.string(from: Measurement(value: Double(rest), unit: UnitLength.inches))
    }

    private static func measurementFormatter(locale: Locale, numbers: NumberFormatter) -> MeasurementFormatter {
        let formatter = MeasurementFormatter()
        formatter.locale = locale; formatter.unitOptions = .providedUnit; formatter.unitStyle = .medium
        formatter.numberFormatter = numbers
        return formatter
    }

    /// "Kilometres", "Degrees Fahrenheit": a unit's name as the person would say it.
    public static func name(of unit: MeasureUnit, locale: Locale = .current) -> String {
        let formatter = MeasurementFormatter()
        formatter.locale = locale; formatter.unitOptions = .providedUnit; formatter.unitStyle = .long
        let spelled = formatter.string(from: Measurement(value: 2, unit: unit.dimension))
        // The name without its number.
        let name = spelled.drop { !$0.isLetter && $0 != "°" }.trimmingCharacters(in: .whitespaces)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A number as written: "1,500" is fifteen hundred, "2,5" two and a half.
    static func number(_ written: String) -> Double? {
        var text = written.replacingOccurrences(of: "−", with: "-")
        if text.range(of: "^-?\\d{1,3}(?:[,\\u00a0\\u202f]\\d{3})+(?:\\.\\d+)?$", options: .regularExpression) != nil {
            text = text.replacingOccurrences(of: "[,\\u00a0\\u202f]", with: "", options: .regularExpression)
        } else {
            text = text.replacingOccurrences(of: ",", with: ".")
        }
        return Double(text)
    }

    private static let space = "[ \\u00a0\\u202f]?"
    private static let numberText = "[-−]?(?:\\d{1,3}(?:[,\\u00a0\\u202f]\\d{3})+(?:\\.\\d+)?|\\d+(?:[.,]\\d+)?)"
    private static let numberPattern = try! NSRegularExpression(pattern: numberText)
    /// Longest first, so "km/h" isn't "km", nor "miles per hour" "miles". A lone "m" or "g" is
    /// lower case, as "5M" is five million and "5G" a network; "5m ago" is a time. "in" ends
    /// what's written, so "1 in 10" and "5 in stock" aren't inches.
    private static let units = [
        "(?i:km/hr?|kmph|kmh|kph|kilomet(?:re|er)s? per hour|mph|miles? per hour|m/s|met(?:re|er)s? per second|knots?|kts)",
        "[°º˚]\(space)[CF](?![\\p{L}])", "℃", "℉",
        "(?i:degrees?\(space)(?:celsius|centigrade|fahrenheit|c|f)|celsius|centigrade|fahrenheit|kelvin)",
        "(?i:millimet(?:re|er)s?|centimet(?:re|er)s?|kilomet(?:re|er)s?|met(?:re|er)s?|inch(?:es)?|feet|foot|yards?|yds?|miles?|mm|cm|kms?|ft|mi)",
        "(?i:kilogram(?:me)?s?|gram(?:me)?s?|kilos?|kgs?|tonnes?|ounces?|oz|pounds?|lbs?|stones?)",
        "m(?!\\s+ago)", "g", "in(?=\\s*(?:$|[^\\s\\p{L}\\p{N}]))", "″", "′",
    ].joined(separator: "|")
    /// Numbers a measurement's: one, a range's two ("5–10 km", "5 to 10 km") or a size's sides ("30 x 20 cm").
    private static let numbers = "\(numberText)(?:(?:\(space)[-–—]\(space)|\\sto\\s|\(space)[x×]\(space)|\\sby\\s)\(numberText)){0,2}"
    private static let pattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.,$€£¥₹:/])(\(numbers))\(space)(\(units))(?![\\p{L}\\p{N}/])")
    private static let heights = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.,])(\\d{1,2})\(space)(?:′|'|ft|feet|foot),?\(space)(\\d{1,2}(?:\\.\\d+)?)\(space)(?:″|\"|''|inch(?:es)?|in)(?![\\p{L}\\p{N}])")
}
