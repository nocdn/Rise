import Foundation

/// A selected postal address, for the right-click menu to open in Google Maps in a Peek.
///
/// The system's address detector finds full addresses ("10 Downing Street, London SW1A 2AA"), but
/// misses ones that are only a street and a town, as listings write them: "100 Newland Park
/// Drive, York". Those this reads itself, from a street's name ("… Drive", "Rue …",
/// "…straße 5") with a house number or a town after it, or from a postcode. Only a selection that
/// is mostly an address counts, so a sentence that mentions one doesn't.
public enum SelectionAddresses {
    static let maximumLength = 200, maximumLines = 6, maximumWords = 24

    /// What to search Maps for, from the address's start to the selection's end, or nil when the
    /// selection isn't an address.
    public static func find(in text: String) -> String? {
        guard let text = normalized(text) else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        // The detector's address, if it's most of the selection.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue),
           let match = detector.firstMatch(in: text, range: whole), match.range.length*2 >= whole.length {
            return query(text, from: match.range.location)
        }
        let parts = text.components(separatedBy: ",")
        var offset = 0
        for (index, part) in parts.enumerated() {
            defer { offset += part.utf16.count+1 }
            let range = NSRange(location: 0, length: part.utf16.count)
            guard let street = streetPatterns.lazy.compactMap({ $0.firstMatch(in: part, range: range) }).first else { continue }
            let found = street.range(withName: "street")
            let numbered = street.range(withName: "number").location != NSNotFound
            // Words before the street ("Visit us at …") need its number to tell where it starts.
            if found.location > 0, !numbered { continue }
            let rest = parts[(index+1)...]
            let town = rest.contains { $0.trimmingCharacters(in: .whitespaces).first.map { $0.isUppercase || $0.isNumber } ?? false }
            if numbered || town || hasPostcode(text) { return query(text, from: offset+found.location) }
        }
        // A postcode precise enough on its own, with a town or street beside it: "York YO10 3HP".
        if let match = ukPostcode.firstMatch(in: text, range: whole), text.utf16.count > match.range.length+2 { return text }
        if usPostcode.firstMatch(in: text, range: whole) != nil, parts.count >= 2 { return text }
        return nil
    }

    /// Google Maps' search for `address`, which shows its place when it finds one.
    public static func mapsURL(for address: String) -> URL {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        let encoded = address.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://www.google.com/maps/search/?api=1&query=\(encoded)")!
    }

    /// One line, with the selection's line breaks as commas, or nil when it's too long or holds
    /// something that is never part of an address, as a link or a question.
    static func normalized(_ text: String) -> String? {
        guard text.utf16.count <= maximumLength*2 else { return nil }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard (1...maximumLines).contains(lines.count) else { return nil }
        var joined = lines.map { $0.hasSuffix(",") ? String($0.dropLast()) : $0 }.joined(separator: ", ")
        joined = joined.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".,;:")))
        let lowered = joined.lowercased()
        guard (4...maximumLength).contains(joined.count), joined.contains(where: \.isLetter),
              joined.split(separator: " ").count <= maximumWords,
              !["://", "www.", "@", "?", "!"].contains(where: lowered.contains) else { return nil }
        return joined
    }

    static func query(_ text: String, from location: Int) -> String {
        let start = String.Index(utf16Offset: location, in: text)
        return String(text[start...]).trimmingCharacters(in: .whitespaces)
    }

    static func hasPostcode(_ text: String) -> Bool {
        let whole = NSRange(text.startIndex..., in: text)
        return [ukPostcode, usPostcode, otherPostcode].contains { $0.firstMatch(in: text, range: whole) != nil }
    }

    // Street names. A word of a name starts with a capital, or is an ordinal ("5th"), or one of
    // the small words names carry ("Stratford upon Avon Road").
    static let word = "(?:\\p{Lu}[\\p{L}'’.-]*|\\d+(?:st|nd|rd|th))"
    static let joiner = "(?:of|the|de|la|le|du|des|del|da|van|von|upon|on|in)"
    static let number = "(?<number>(?:(?:Flat|Apartment|Apt\\.?|Unit|Suite)\\s+\\w+\\s+)?\\d+[A-Za-z]?(?:[-–/]\\d+[A-Za-z]?)?\\s+)"
    /// Names that end in what kind of street they are: "100 Newland Park Drive".
    static let englishTypes = ["Street", "St", "Road", "Rd", "Drive", "Dr", "Avenue", "Ave", "Lane", "Ln", "Way", "Close",
        "Court", "Ct", "Crescent", "Cres", "Place", "Pl", "Terrace", "Boulevard", "Blvd", "Parkway", "Pkwy", "Square", "Sq",
        "Grove", "Gardens", "Gdns", "Highway", "Hwy", "Row", "Mews", "Parade", "Circle", "Cir", "Trail", "Alley", "Quay",
        "Esplanade", "Promenade", "Embankment", "Circus", "Walk", "Wynd", "Broadway"]
    /// Names that start with it: "Rue de Rivoli 99", "ul. Marszałkowska 10".
    static let leadingTypes = ["Rue", "Avenue", "Av\\.", "Boulevard", "Bd", "Chemin", "Impasse", "Allée", "Quai", "Place",
        "Via", "Viale", "Piazza", "Piazzale", "Corso", "Calle", "Avenida", "Plaza", "Paseo", "Carrer", "Rua", "Travessa",
        "Largo", "ul\\.", "ulica", "al\\.", "aleja", "pl\\.", "os\\."]
    /// Names the kind is part of, with their number after: "Hauptstraße 5", "Prinsengracht 263".
    static let compoundTypes = ["straße", "strasse", "str\\.", "weg", "platz", "gasse", "allee", "damm", "ring", "ufer",
        "straat", "gracht", "laan", "plein", "kade", "vägen", "gatan", "gata", "vej", "gade", "veien", "gate"]
    static let streetPatterns: [NSRegularExpression] = [
        "(?<street>\(number)?\(word)(?:\\s+(?:\(word)|\(joiner)))*\\s+(?:\(englishTypes.joined(separator: "|")))\\.?(?:\\s+(?:N|S|E|W|NE|NW|SE|SW))?)\\s*$",
        "(?<street>(?<number>\\d+[A-Za-z]?,?\\s+)?(?:\(leadingTypes.joined(separator: "|")))\\s+(?:\(word)|\(joiner))(?:\\s+(?:\(word)|\(joiner)|\\d+[A-Za-z]?))*)\\s*$",
        "(?<street>\\p{Lu}[\\p{L}-]*(?:\(compoundTypes.joined(separator: "|")))(?<number>\\s+\\d+[A-Za-z]?))\\s*$",
    ].map { try! NSRegularExpression(pattern: $0) }
    static let ukPostcode = try! NSRegularExpression(pattern: "\\b(?:[A-Z]{1,2}\\d[A-Z\\d]?|GIR) ?\\d[A-Z]{2}\\b")
    static let usPostcode = try! NSRegularExpression(pattern: "\\b[A-Z]{2} \\d{5}(?:-\\d{4})?\\b")
    static let otherPostcode = try! NSRegularExpression(pattern: "\\b(?:\\d{2}-\\d{3}|\\d{4,5}) \\p{Lu}")
}
