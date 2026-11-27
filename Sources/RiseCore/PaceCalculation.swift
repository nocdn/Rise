import Foundation

/// Running pace, finish time and speed, each from the other two: "5k in 24 minutes" is 4:48 per km,
/// "marathon at 5:00/km" finishes in 3 hr 30 min 59 sec, "5:00/km to mph" is 7.46 mph, and "12 km/h to
/// pace" is 5:00 per km. "Marathon in 3:30" is three and a half hours; "5k in 24:00", 24 minutes.
enum PaceCalculation {
    private static let mile = 1.609344
    private static let distancePattern = #"(?:a |the )?(half[- ]marathon|marathon|parkrun|mile|(\d{1,5}(?:\.\d{1,4})?) ?(k|km|kms|kilometers?|kilometres?|mi|miles?|m|meters?|metres?))(?![a-z])"#
    private static let pacePattern = #"(\d{1,2}(?::[0-5]\d)?|\d{1,2}(?:\.\d+)?) ?(?:min(?:ute)?s? ?)?(?:/|per|a) ?(km|kilometer|kilometre|k|mi|mile)|(\d{1,2}(?::[0-5]\d)?) ?min(?:ute)?s? (mile|km|k)s?(?: pace)?"#
    private static let speedPattern = #"(\d{1,3}(?:\.\d+)?) ?(km/h|kmh|kph|km per hour|kilometres per hour|kilometers per hour|mph|miles per hour|m/s)"#

    static func evaluate(_ query: String) -> AddressCalculation? {
        var text = query
        for prefix in ["running ", "run ", "my "] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        // Pace or speed for a distance in a time: "pace for 5k in 24 minutes", "10k in 50:00 to mph"
        if let match = AddressCalculation.groups(#"^(pace|speed|average pace|average speed)?(?: for| of)? ?"# + distancePattern + #" (?:in|at|run in|done in|finished in) (.+?)(?: (pace|speed))?((?: (?:to|in|per|then|as) (?:km|mi|kilometers?|kilometres?|miles?|mph|km/h|kmh|kph|m/s|per km|per mile|per mi|min/km|min/mi|min/mile))*)$"#, in: text),
           let kilometers = distance(match[2], match[3], match[4]),
           let seconds = duration(match[5], kilometers: kilometers), seconds > 0 {
            let asked = match[1].isEmpty ? match[6] : match[1]
            let targets = match[7]
            let secondsPerKm = seconds/kilometers
            let inMiles = match[4].hasPrefix("mi") || match[2] == "mile"
            // Without "pace", a distance in a time is a pace when someone could run it, and a speed when
            // it's faster or slower than that: "100m in 10 seconds", "200 miles in 4 hours".
            let runnable = (120...1200).contains(secondsPerKm)
            let wantsSpeed = asked.contains("speed") || targets.contains("mph") || targets.contains("/h") || targets.contains("kmh") || targets.contains("kph") || targets.contains("m/s")
                || (asked.isEmpty && targets.isEmpty && !runnable)
            if wantsSpeed { return speedText(3600/secondsPerKm, targets.isEmpty && inMiles ? " mph" : targets) }
            let perMile = targets.contains(" mi") || targets.contains("mile") || (targets.isEmpty && inMiles)
            return paceText(secondsPerKm, perMile: perMile)
        }
        // Finish time for a distance at a pace or speed: "marathon at 5:00/km", "5:00 per km for 10k"
        var distanceText = "", rateText = ""
        if let match = AddressCalculation.groups(#"^(?:finish time|time|how long)?(?: for| to run)? ?(.+?) (?:at|@) (.+?)(?: (?:pace|finish time|time))?$"#, in: text) {
            (distanceText, rateText) = (match[1], match[2])
        } else if let match = AddressCalculation.groups(#"^(.+?) (?:for|over) (?:a |the )?(.+?)(?: (?:finish time|time))?$"#, in: text) {
            (distanceText, rateText) = (match[2], match[1])
        }
        if !distanceText.isEmpty, let distanceMatch = AddressCalculation.groups("^" + distancePattern + "$", in: distanceText),
           let kilometers = distance(distanceMatch[1], distanceMatch[2], distanceMatch[3]),
           let secondsPerKm = rate(rateText) {
            return AddressCalculation(CalendarCalculation.elapsed(Int((secondsPerKm*kilometers).rounded())))
        }
        // A pace or speed in other units: "5:00/km to per mile", "8 min mile to km", "12 km/h to pace"
        if let match = AddressCalculation.groups(#"^(.+?) (?:to|in|as|into) (pace|per km|per mile|per mi|min/km|min/mi|min/mile|/km|/mi|/mile|km|mi|miles?|mph|km/h|kmh|kph|m/s|speed)$|^(.+?) (pace)$"#, in: text) {
            let source = match[1].isEmpty ? match[3] : match[1]
            let target = match[2].isEmpty ? match[4] : match[2]
            guard let secondsPerKm = rate(source) else { return nil }
            let sourceIsSpeed = AddressCalculation.groups("^" + speedPattern + "$", in: source) != nil
            switch target {
            case "mph", "km/h", "kmh", "kph", "m/s", "speed": return speedText(3600/secondsPerKm, " " + (target == "speed" ? (source.contains("/mi") || source.contains("mile") ? "mph" : "km/h") : target))
            case "pace": return paceText(secondsPerKm, perMile: source.contains("mph") || source.contains("mile"))
            default:
                guard !sourceIsSpeed || target.contains("/") || target.hasPrefix("per") || target.hasPrefix("min") else {
                    return paceText(secondsPerKm, perMile: target.hasPrefix("mi"))
                }
                return paceText(secondsPerKm, perMile: target.contains("mi"))
            }
        }
        return nil
    }

    private static func distance(_ whole: String, _ number: String, _ unit: String) -> Double? {
        switch whole.replacingOccurrences(of: "-", with: " ") {
        case "marathon": return 42.195
        case "half marathon": return 21.0975
        case "parkrun": return 5
        case "mile": return mile
        default: break
        }
        guard let value = Double(number), value > 0 else { return nil }
        if unit.hasPrefix("mi") { return value*mile }
        if unit == "m" || unit.hasPrefix("met") { return value/1000 }
        return value
    }

    /// A race time. "3:30" is hours and minutes for a long race and minutes and seconds for a short
    /// one: whichever gives a pace a person can run.
    private static func duration(_ text: String, kilometers: Double) -> Double? {
        if let match = AddressCalculation.groups(#"^(\d{1,3}):([0-5]\d):([0-5]\d)$"#, in: text),
           let hours = Double(match[1]), let minutes = Double(match[2]), let seconds = Double(match[3]) {
            return hours*3600+minutes*60+seconds
        }
        if let match = AddressCalculation.groups(#"^(\d{1,3}):([0-5]\d)$"#, in: text), let first = Double(match[1]), let second = Double(match[2]) {
            let asMinutes = first*60+second, asHours = first*3600+second*60
            let plausible = { (seconds: Double) in (120...1200).contains(seconds/kilometers) }
            return plausible(asMinutes) || !plausible(asHours) ? asMinutes : asHours
        }
        var cursor = Cursor(text)
        guard let span = CalendarCalculation.span(&cursor), cursor.isAtEnd else { return nil }
        return span.fixedSeconds
    }

    /// Seconds per kilometre from a pace ("5:00/km", "8 min mile") or a speed ("12 km/h", "7.5 mph").
    private static func rate(_ text: String) -> Double? {
        if let match = AddressCalculation.groups("^" + pacePattern + "$", in: text) {
            let amount = match[1].isEmpty ? match[3] : match[1]
            let unit = match[2].isEmpty ? match[4] : match[2]
            let seconds: Double
            if let colon = AddressCalculation.groups(#"^(\d{1,2}):([0-5]\d)$"#, in: amount), let m = Double(colon[1]), let s = Double(colon[2]) {
                seconds = m*60+s
            } else if let minutes = Double(amount) { seconds = minutes*60 }
            else { return nil }
            guard seconds > 0 else { return nil }
            return unit.hasPrefix("mi") ? seconds/mile : seconds
        }
        if let match = AddressCalculation.groups("^" + speedPattern + "$", in: text), let value = Double(match[1]), value > 0 {
            let kmPerHour: Double
            switch match[2] {
            case "mph", "miles per hour": kmPerHour = value*mile
            case "m/s": kmPerHour = value*3.6
            default: kmPerHour = value
            }
            return 3600/kmPerHour
        }
        return nil
    }

    private static func paceText(_ secondsPerKm: Double, perMile: Bool) -> AddressCalculation? {
        let pace = Int((secondsPerKm*(perMile ? mile : 1)).rounded())
        guard pace > 0, pace < 360000 else { return nil }
        let clock = pace >= 3600 ? String(format: "%d:%02d:%02d", pace/3600, pace/60%60, pace%60) : String(format: "%d:%02d", pace/60, pace%60)
        return AddressCalculation("\(clock) per \(perMile ? "mi" : "km")")
    }

    private static func speedText(_ kmPerHour: Double, _ targets: String) -> AddressCalculation? {
        guard kmPerHour.isFinite, kmPerHour > 0 else { return nil }
        if targets.contains("mph") || targets.hasSuffix(" mi") || targets.contains("mile") {
            return AddressCalculation(AddressCalculation.number(kmPerHour/mile, digits: 2)+" mph")
        }
        if targets.contains("m/s") { return AddressCalculation(AddressCalculation.number(kmPerHour/3.6, digits: 2)+" m/s") }
        return AddressCalculation(AddressCalculation.number(kmPerHour, digits: 2)+" km/h")
    }
}
