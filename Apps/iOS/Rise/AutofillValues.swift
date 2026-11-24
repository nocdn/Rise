import Contacts
import Foundation

/// One thing the keyboard bar can fill into a field: what its menu shows, and the ways it can be
/// written, the page taking whichever of them the field accepts (`FormAutofillScript`).
struct AutofillChoice: Equatable {
    var title: String
    var subtitle: String?
    var variants: [AutofillVariant]
    /// Which of the card's addresses it comes from, so the one picked last can lead the menu.
    var address: Int?
}

/// A way of writing a value, with what kind of way it is ("intl", "national", "compact"…), so the
/// page can prefer the one a field's placeholder or neighbours ask for.
struct AutofillVariant: Equatable, Encodable {
    var value: String
    var tags: [String] = []
    enum CodingKeys: String, CodingKey { case value = "v", tags = "t" }
}

/// What the card holds for each kind of field the page script recognises.
enum AutofillValues {
    static let kinds: Set<String> = [
        "name", "given-name", "additional-name", "additional-name-initial", "family-name", "honorific-prefix", "honorific-suffix", "nickname",
        "organization", "organization-title", "email", "tel", "tel-national", "tel-country-code",
        "street-address", "address-line1", "address-line2", "address-line3", "street-name", "house-number", "address-full",
        "address-level3", "address-level2", "address-level1", "county", "postal-code", "country",
        "bday", "bday-day", "bday-month", "bday-year", "age", "url", "url-linkedin", "url-github", "url-x",
    ]

    /// Each value the card has for `kind`, the same value only once. `multiline` is a textarea's,
    /// where an address keeps its lines; `language` is the page's, for country and month names.
    static func choices(for kind: String, in profile: AutofillProfile, multiline: Bool = false,
                        language: String? = nil, now: Date = Date()) -> [AutofillChoice] {
        var choices: [AutofillChoice] = []
        func add(_ title: String, _ subtitle: String? = nil, variants: [AutofillVariant]? = nil, address: Int? = nil) {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !choices.contains(where: { $0.title == title }) else { return }
            let variants = (variants ?? [AutofillVariant(value: title)]).filter { !$0.value.isEmpty }
            guard !variants.isEmpty else { return }
            choices.append(AutofillChoice(title: title, subtitle: subtitle?.isEmpty == true ? nil : subtitle,
                                          variants: unique(variants), address: address))
        }
        func each(_ part: (AutofillProfile.Address) -> String, subtitle: (AutofillProfile.Address) -> String?,
                  variants: ((AutofillProfile.Address, String) -> [AutofillVariant])? = nil) {
            for (index, address) in profile.addresses.enumerated() {
                let value = part(address)
                add(value, subtitle(address), variants: variants?(address, value), address: index)
            }
        }
        let place: (AutofillProfile.Address) -> String? = { address in
            [address.label, streetLines(address).first ?? address.city].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let town: (AutofillProfile.Address) -> String? = { address in
            [address.label, address.city.isEmpty ? address.postalCode : address.city].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        switch kind {
        case "name": add(fullName(profile))
        case "given-name": add(profile.givenName)
        // A field with room for only a letter gets the initial.
        case "additional-name":
            add(profile.middleName, variants: [AutofillVariant(value: profile.middleName)]+middleInitials(profile))
        case "additional-name-initial":
            if let initial = middleInitials(profile).first { add(initial.value, variants: middleInitials(profile)) }
        case "family-name": add(profile.familyName)
        case "honorific-prefix": add(profile.namePrefix)
        case "honorific-suffix": add(profile.nameSuffix)
        case "nickname": add(profile.nickname.isEmpty ? profile.givenName : profile.nickname)
        case "organization": add(profile.organization)
        case "organization-title": add(profile.jobTitle)
        case "email":
            for email in profile.emails { add(email.value, email.label) }
        case "tel", "tel-national":
            for phone in profile.phones {
                add(phone.number, phone.label, variants: PhoneFormats.variants(phone.number, region: phone.region))
            }
        case "tel-country-code":
            for phone in profile.phones {
                guard let code = PhoneFormats.parse(phone.number, region: phone.region)?.code else { continue }
                add("+"+code, phone.label, variants: [AutofillVariant(value: "+"+code), AutofillVariant(value: code, tags: ["digits"])])
            }
        case "street-address":
            each({ streetAndLocality($0).joined(separator: multiline ? "\n" : ", ") }, subtitle: town)
        case "address-line1": each({ streetLines($0).first ?? "" }, subtitle: town)
        // A UK card's locality ("Great Baddow") is line 2 on most forms, as its own line or its own field.
        case "address-line2": each({ streetAndLocality($0).dropFirst().prefix(1).joined() }, subtitle: place)
        case "address-line3": each({ streetLines($0).dropFirst(2).joined(separator: ", ") }, subtitle: place)
        case "street-name": each({ splitStreet($0)?.street ?? streetLines($0).first ?? "" }, subtitle: town)
        case "house-number": each({ splitStreet($0)?.number ?? "" }, subtitle: place)
        case "address-full":
            each({ fullAddress($0, multiline: multiline) }, subtitle: { $0.label })
        case "address-level3": each(\.subLocality, subtitle: place)
        case "address-level2": each(\.city, subtitle: place)
        // A UK address's county (Essex) rather than its nation (England), as UK forms mean.
        case "address-level1": each({ $0.region }, subtitle: place, variants: { address, value in stateVariants(value, country: address.isoCountryCode) })
        case "county": each({ $0.county.isEmpty ? $0.state : $0.county }, subtitle: place)
        case "postal-code":
            each(\.postalCode, subtitle: place) { _, value in
                [AutofillVariant(value: value), AutofillVariant(value: value.replacingOccurrences(of: " ", with: ""), tags: ["compact"]),
                 AutofillVariant(value: value.uppercased())]
            }
        case "country":
            each({ countryName($0) }, subtitle: { $0.label }) { address, _ in countryVariants(address, language: language) }
        case "bday":
            guard let birthday = profile.birthday, let year = birthday.year else { break }
            let iso = String(format: "%04d-%02d-%02d", year, birthday.month, birthday.day)
            add(formatted(birthday), variants: [AutofillVariant(value: iso, tags: ["date"])])
        case "bday-day":
            guard let day = profile.birthday?.day else { break }
            add(String(format: "%02d", day), variants: [AutofillVariant(value: String(format: "%02d", day)), AutofillVariant(value: "\(day)")])
        case "bday-month":
            guard let month = profile.birthday?.month else { break }
            var variants = [AutofillVariant(value: String(format: "%02d", month)), AutofillVariant(value: "\(month)")]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language ?? Locale.current.identifier)
            for name in [formatter.standaloneMonthSymbols, formatter.monthSymbols, formatter.shortMonthSymbols] {
                if let name = name?[month-1] { variants.append(AutofillVariant(value: name, tags: ["name"])) }
            }
            add(String(format: "%02d", month), variants: variants)
        case "bday-year":
            guard let year = profile.birthday?.year else { break }
            add("\(year)", variants: [AutofillVariant(value: "\(year)"), AutofillVariant(value: String(format: "%02d", year%100), tags: ["short"])])
        case "age":
            guard let age = age(profile.birthday, now: now) else { break }
            add("\(age)")
        case "url", "url-linkedin", "url-github", "url-x":
            let hosts = ["url-linkedin": ["linkedin.com"], "url-github": ["github.com"], "url-x": ["x.com", "twitter.com"]][kind]
            for url in profile.urls {
                let host = URL(string: url.value.contains("://") ? url.value : "https://"+url.value)?.host()?.lowercased() ?? ""
                if let hosts, !hosts.contains(where: { host == $0 || host.hasSuffix("."+$0) }) { continue }
                add(url.value, url.label, variants: urlVariants(url.value))
            }
        default: break
        }
        return choices
    }

    /// Given and family names in the order the name's script writes them, as a form's single
    /// name field wants, without middle names or titles.
    /// The middle name's initial, as forms asking for a middle initial want it: "A", then "A.".
    static func middleInitials(_ profile: AutofillProfile) -> [AutofillVariant] {
        guard let letter = profile.middleName.first(where: \.isLetter) else { return [] }
        let initial = String(letter).uppercased()
        return [AutofillVariant(value: initial, tags: ["initial"]), AutofillVariant(value: initial+".", tags: ["initial"])]
    }

    static func fullName(_ profile: AutofillProfile) -> String {
        var components = PersonNameComponents()
        components.givenName = profile.givenName.isEmpty ? nil : profile.givenName
        components.familyName = profile.familyName.isEmpty ? nil : profile.familyName
        guard components.givenName != nil || components.familyName != nil else { return "" }
        return PersonNameComponentsFormatter.localizedString(from: components, style: .default)
    }

    /// The street's lines, then its locality where the card keeps that apart and no line has it.
    static func streetAndLocality(_ address: AutofillProfile.Address) -> [String] {
        let lines = streetLines(address)
        guard !address.subLocality.isEmpty, !lines.contains(where: { $0.localizedCaseInsensitiveContains(address.subLocality) }) else { return lines }
        return lines+[address.subLocality]
    }

    /// As the card has it, then as https (which some forms insist on) and without its scheme.
    static func urlVariants(_ stored: String) -> [AutofillVariant] {
        let bare = stored.replacingOccurrences(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*://"#, with: "", options: .regularExpression)
        return [AutofillVariant(value: stored), AutofillVariant(value: "https://"+bare, tags: ["https"]), AutofillVariant(value: bare, tags: ["bare"])]
    }

    static func streetLines(_ address: AutofillProfile.Address) -> [String] {
        address.street.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The street and its house number apart, for forms that ask for each: "Hauptstraße 12",
    /// "10 Downing Street", "ul. Marszałkowska 10/12", "Calle Mayor, 5". A flat's line is passed
    /// over for the street's.
    static func splitStreet(_ address: AutofillProfile.Address) -> (street: String, number: String)? {
        let flat = /^(flat|apt\.?|apartment|unit|suite|room|floor|lokal|m\.|wohnung|appartement|piso)\b/.ignoresCase()
        for line in streetLines(address) where (try? flat.prefixMatch(in: line)) == nil {
            if let match = try? /^(?<number>\d+[a-zA-Z]?(?:[\/\-]\d+[a-zA-Z]?)?)[,\s]+(?<street>\D.*)$/.wholeMatch(in: line) {
                return (String(match.street).trimmingCharacters(in: .whitespaces), String(match.number))
            }
            if let match = try? /^(?<street>.*\D)[,\s]+(?:n[or]?\.?\s*|nº\s*)?(?<number>\d+[a-zA-Z]?(?:\s?[\/\-]\s?\d+[a-zA-Z]?)?)$/.ignoresCase().wholeMatch(in: line) {
                return (String(match.street).trimmingCharacters(in: CharacterSet(charactersIn: ", ")), String(match.number))
            }
        }
        return nil
    }

    static func fullAddress(_ address: AutofillProfile.Address, multiline: Bool) -> String {
        let postal = CNMutablePostalAddress()
        postal.street = address.street
        postal.subLocality = address.subLocality
        postal.city = address.city
        // A UK address's county, where the card has only its nation.
        postal.subAdministrativeArea = address.isUK ? "" : address.subAdministrativeArea
        postal.state = address.region
        postal.postalCode = address.postalCode
        postal.country = countryName(address)
        postal.isoCountryCode = address.isoCountryCode
        let lines = CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.joined(separator: multiline ? "\n" : ", ")
    }

    static func countryName(_ address: AutofillProfile.Address) -> String {
        if !address.country.isEmpty { return address.country }
        guard !address.isoCountryCode.isEmpty else { return "" }
        return Locale.current.localizedString(forRegionCode: address.isoCountryCode.uppercased()) ?? ""
    }

    /// The card's name for the country first, then its English and local names and its code.
    static func countryVariants(_ address: AutofillProfile.Address, language: String?) -> [AutofillVariant] {
        var variants = [AutofillVariant(value: countryName(address))]
        let code = address.isoCountryCode.uppercased()
        guard !code.isEmpty else { return variants }
        for identifier in [language, "en", Locale.current.identifier].compactMap({ $0 }) {
            if let name = Locale(identifier: identifier).localizedString(forRegionCode: code) { variants.append(AutofillVariant(value: name)) }
        }
        variants.append(AutofillVariant(value: code, tags: ["code"]))
        return variants
    }

    /// A US state as the card has it, then as its name or two-letter code, whichever that isn't.
    static func stateVariants(_ state: String, country: String) -> [AutofillVariant] {
        var variants = [AutofillVariant(value: state)]
        guard country.isEmpty || country == "us" else { return variants }
        if let name = usStates[state.uppercased()] { variants.append(AutofillVariant(value: name)) }
        if let code = usStates.first(where: { $0.value.caseInsensitiveCompare(state) == .orderedSame })?.key {
            variants.append(AutofillVariant(value: code, tags: ["code"]))
        }
        return variants
    }

    static func formatted(_ birthday: AutofillProfile.Birthday) -> String {
        var components = DateComponents()
        components.year = birthday.year; components.month = birthday.month; components.day = birthday.day
        guard let date = Calendar(identifier: .gregorian).date(from: components) else { return "" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Whole years since the birthday, counting this year's once it's been.
    static func age(_ birthday: AutofillProfile.Birthday?, now: Date) -> Int? {
        guard let birthday, let year = birthday.year else { return nil }
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: now)
        guard let thisYear = today.year, let month = today.month, let day = today.day else { return nil }
        let had = month > birthday.month || (month == birthday.month && day+1 > birthday.day)
        let age = thisYear-year-(had ? 0 : 1)
        return (0..<150).contains(age) ? age : nil
    }

    private static func unique(_ variants: [AutofillVariant]) -> [AutofillVariant] {
        var seen = Set<String>()
        return variants.filter { seen.insert($0.value).inserted }
    }

    static let usStates = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
        "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota",
        "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
        "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming", "PR": "Puerto Rico",
    ]
}

/// A phone number in the ways forms ask for it: as the card writes it, internationally
/// (+447700900123), nationally with the country's trunk prefix (07700900123), and without either
/// (7700900123), for a field beside a separate country code.
enum PhoneFormats {
    struct Parsed: Equatable {
        /// The country calling code, without its plus ("44").
        var code: String
        /// The national significant number: no country code, no trunk prefix.
        var number: String
        var region: String?
    }

    static func variants(_ stored: String, region: String?) -> [AutofillVariant] {
        let written = stored.trimmingCharacters(in: .whitespaces)
        let international = written.hasPrefix("+") || written.hasPrefix("00")
        var variants = [AutofillVariant(value: written, tags: ["stored", international ? "intl" : "national"])]
        if let parsed = parse(written, region: region) {
            let trunk = parsed.region.flatMap { trunkPrefixes[$0] } ?? ""
            variants += [AutofillVariant(value: "+"+parsed.code+parsed.number, tags: ["intl", "compact"]),
                         AutofillVariant(value: trunk+parsed.number, tags: ["national", "compact"]),
                         AutofillVariant(value: parsed.number, tags: ["nsn", "compact"]),
                         AutofillVariant(value: parsed.code+parsed.number, tags: ["intl", "digits"])]
        } else {
            let digits = written.filter(\.isASCIIDigit)
            variants.append(AutofillVariant(value: (written.hasPrefix("+") ? "+" : "")+digits, tags: [international ? "intl" : "national", "compact"]))
        }
        var seen = Set<String>()
        return variants.filter { !$0.value.isEmpty && seen.insert($0.value).inserted }
    }

    /// The number's country code and national number, from its own plus, or from the country it's
    /// dialled in when it has none. An extension is left off.
    static func parse(_ stored: String, region: String?) -> Parsed? {
        var text = stored
        if let range = text.range(of: #"(?i)\s*(ext\.?|x|#|;|,).*$"#, options: .regularExpression) { text.removeSubrange(range) }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var digits = trimmed.filter(\.isASCIIDigit)
        guard digits.count >= 4 else { return nil }
        var international = trimmed.hasPrefix("+")
        if !international, digits.hasPrefix("00"), digits.count > 8 { digits.removeFirst(2); international = true }
        if international {
            for length in 1...3 where digits.count > length {
                let code = String(digits.prefix(length))
                guard let home = regionsByCode[code] else { continue }
                let country = region.flatMap { callingCodes[$0] == code ? $0 : nil } ?? home
                return Parsed(code: code, number: String(digits.dropFirst(length)), region: country)
            }
            return nil
        }
        guard let region, let code = callingCodes[region] else { return nil }
        var number = digits
        if let trunk = trunkPrefixes[region], number.hasPrefix(trunk), number.count > trunk.count+5 { number.removeFirst(trunk.count) }
        else if code == "1", number.count == 11, number.hasPrefix("1") { number.removeFirst() }
        return Parsed(code: code, number: number, region: region)
    }

    /// ITU country calling codes, by ISO 3166 region.
    static let callingCodes: [String: String] = {
        let table = """
        ad376 ae971 af93 ag1 ai1 al355 am374 ao244 ar54 as1 at43 au61 aw297 az994 ba387 bb1 bd880 be32 bf226 bg359 bh973 \
        bi257 bj229 bm1 bn673 bo591 br55 bs1 bt975 bw267 by375 bz501 ca1 cd243 cf236 cg242 ch41 ci225 cl56 cm237 cn86 co57 \
        cr506 cu53 cv238 cy357 cz420 de49 dj253 dk45 dm1 do1 dz213 ec593 ee372 eg20 er291 es34 et251 fi358 fj679 fo298 fr33 \
        ga241 gb44 gd1 ge995 gg44 gh233 gi350 gl299 gm220 gn224 gp590 gq240 gr30 gt502 gu1 gw245 gy592 hk852 hn504 hr385 \
        ht509 hu36 id62 ie353 il972 im44 in91 iq964 ir98 is354 it39 je44 jm1 jo962 jp81 ke254 kg996 kh855 km269 kn1 kr82 \
        kw965 ky1 kz7 la856 lb961 lc1 li423 lk94 lr231 ls266 lt370 lu352 lv371 ly218 ma212 mc377 md373 me382 mg261 mk389 \
        ml223 mm95 mn976 mo853 mq596 mr222 mt356 mu230 mv960 mw265 mx52 my60 mz258 na264 ne227 ng234 ni505 nl31 no47 np977 \
        nz64 om968 pa507 pe51 pf689 pg675 ph63 pk92 pl48 pr1 ps970 pt351 py595 qa974 re262 ro40 rs381 ru7 rw250 sa966 sb677 \
        sc248 sd249 se46 sg65 si386 sk421 sl232 sm378 sn221 so252 sr597 ss211 sv503 sy963 sz268 tc1 td235 tg228 th66 tj992 \
        tl670 tm993 tn216 to676 tr90 tt1 tw886 tz255 ua380 ug256 us1 uy598 uz998 va39 vc1 ve58 vg1 vi1 vn84 vu678 ws685 \
        xk383 ye967 yt262 za27 zm260 zw263
        """
        var codes: [String: String] = [:]
        for entry in table.split(separator: " ") { codes[String(entry.prefix(2))] = String(entry.dropFirst(2)) }
        return codes
    }()

    /// Each code's main country, where several share it.
    static let regionsByCode: [String: String] = {
        var regions: [String: String] = [:]
        for (region, code) in callingCodes where regions[code] == nil || region < regions[code]! { regions[code] = region }
        for (code, region) in ["1": "us", "7": "ru", "44": "gb", "39": "it", "47": "no", "61": "au", "262": "re", "590": "gp"] {
            regions[code] = region
        }
        return regions
    }()

    /// What's dialled before a national number within the country, where there's something.
    static let trunkPrefixes: [String: String] = {
        var prefixes: [String: String] = [:]
        for region in """
        gb im je gg ie de at ch nl be fr se fi au nz in jp cn kr tw tr za ua sk ro il eg ng pk bd id my th ph vn ae sa ar br \
        bg hr si rs ba mk al me md ge am az ke gh ma dz lk np ir iq jo lb sy af ug tz zm zw rw et ps kh mm la mn
        """.split(separator: " ") { prefixes[String(region)] = "0" }
        for region in ["ru", "kz", "by"] { prefixes[region] = "8" }
        prefixes["hu"] = "06"
        return prefixes
    }()
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
