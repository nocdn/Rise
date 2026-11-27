import Foundation

/// The places people name when converting times — cities, countries, US states, zone abbreviations
/// and offsets — and how a time there is labelled: "JST", "CET", "BST", rather than "GMT+9".
enum CalculationZones {
    struct Place {
        let zone: TimeZone
        /// The zone as written, for abbreviations and offsets that name a fixed offset: "EST", "UTC+2".
        let label: String?
        /// How the place reads in a sentence: "Tokyo", "PST".
        let name: String
    }

    static let utc = TimeZone(secondsFromGMT: 0)!

    static func place(_ written: String, local: TimeZone) -> Place? {
        var name = written.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("the ") { name.removeFirst(4) }
        for suffix in [" time zone", " timezone", " local time", " time", " tz"] where name.hasSuffix(suffix) && name.count > suffix.count {
            name.removeLast(suffix.count)
            break
        }
        guard !name.isEmpty, name.count <= 40, !name.contains(where: \.isNewline) else { return nil }
        if ["local", "my time", "my", "my local", "my own", "here", "my zone", "home", "mine", "me", "my place", "local time"].contains(name) {
            return Place(zone: local, label: nil, name: localName(local))
        }
        if ["utc", "z", "zulu", "coordinated universal"].contains(name) { return Place(zone: utc, label: "UTC", name: "UTC") }
        if name == "gmt" || name == "greenwich mean" { return Place(zone: utc, label: "GMT", name: "GMT") }
        if let match = AddressCalculation.groups(#"^(utc|gmt)? ?([+-]) ?(\d{1,2})(?::?([0-5]\d))?$"#, in: name),
           let hours = Int(match[3]), hours <= 14 {
            let minutes = Int(match[4]) ?? 0
            guard hours < 14 || minutes == 0 else { return nil }
            let seconds = (hours*60+minutes)*60*(match[2] == "-" ? -1 : 1)
            let label = (match[1] == "gmt" ? "GMT" : "UTC") + offsetText(seconds)
            return TimeZone(secondsFromGMT: seconds).map { Place(zone: $0, label: label, name: label) }
        }
        if let offset = fixedAbbreviations[name] {
            let label = name.uppercased()
            return TimeZone(secondsFromGMT: Int(offset*3600)).map { Place(zone: $0, label: label, name: label) }
        }
        if let id = named[name] ?? cities[name] ?? cities[name.replacingOccurrences(of: "-", with: " ")],
           let zone = TimeZone(identifier: id) {
            return Place(zone: zone, label: nil, name: AddressCalculation.titled(name))
        }
        return nil
    }

    static func isAbbreviation(_ word: String) -> Bool {
        fixedAbbreviations[word] != nil || ["utc", "gmt", "pt", "mt", "ct", "et", "akt", "ht", "aet", "nzt", "uk", "usa", "us", "uae", "nyc", "la", "sf", "dc"].contains(word)
    }

    /// The local zone's place in a sentence: "London" for Europe/London.
    static func localName(_ zone: TimeZone) -> String {
        zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "local time"
    }

    /// "JST", "CEST", "EST", or the offset where a zone has no abbreviation people know: "UTC+4".
    static func label(_ zone: TimeZone, at date: Date) -> String {
        if zone.secondsFromGMT(for: date) == 0, zone.identifier == "GMT" || zone.identifier == "UTC" { return "UTC" }
        let daylight = zone.isDaylightSavingTime(for: date)
        if let names = abbreviations[zone.identifier] { return daylight ? names.1 : names.0 }
        if let system = zone.abbreviation(for: date), system.allSatisfy({ $0.isLetter }), system.count <= 5 { return system }
        return "UTC" + offsetText(zone.secondsFromGMT(for: date))
    }

    /// "+9", "-3:30", "" for none.
    static func offsetText(_ seconds: Int) -> String {
        guard seconds != 0 else { return "" }
        let minutes = abs(seconds)/60
        let sign = seconds < 0 ? "-" : "+"
        return minutes%60 == 0 ? "\(sign)\(minutes/60)" : String(format: "%@%d:%02d", sign, minutes/60, minutes%60)
    }

    /// Abbreviations that name one offset all year, however the places using them change theirs:
    /// "9am EST" in July is still five hours behind UTC.
    static let fixedAbbreviations: [String: Double] = [
        "bst": 1, "ist": 5.5, "wet": 0, "west": 1, "cet": 1, "cest": 2, "eet": 2, "eest": 3, "msk": 3, "trt": 3,
        "gst": 4, "pkt": 5, "npt": 5.75, "ict": 7, "wib": 7, "hkt": 8, "sgt": 8, "pht": 8, "myt": 8, "awst": 8,
        "jst": 9, "kst": 9, "acst": 9.5, "acdt": 10.5, "aest": 10, "aedt": 11, "nzst": 12, "nzdt": 13,
        "hst": -10, "akst": -9, "akdt": -8, "pst": -8, "pdt": -7, "mst": -7, "mdt": -6, "cst": -6, "cdt": -5,
        "est": -5, "edt": -4, "ast": -4, "adt": -3, "nst": -3.5, "ndt": -2.5, "brt": -3, "art": -3,
        "sast": 2, "cat": 2, "eat": 3, "wat": 1, "irst": 3.5, "aft": 4.5, "idt": 3, "cot": -5, "pet": -5, "clt": -4
    ]

    /// Standard and daylight abbreviations for zones the system writes only as offsets.
    private static let abbreviations: [String: (String, String)] = {
        var table: [String: (String, String)] = [
            "Europe/London": ("GMT", "BST"), "Europe/Belfast": ("GMT", "BST"), "Europe/Jersey": ("GMT", "BST"),
            "Europe/Guernsey": ("GMT", "BST"), "Europe/Isle_of_Man": ("GMT", "BST"), "Europe/Dublin": ("GMT", "IST"),
            "Europe/Lisbon": ("WET", "WEST"), "Atlantic/Canary": ("WET", "WEST"), "Atlantic/Madeira": ("WET", "WEST"),
            "Asia/Jerusalem": ("IST", "IDT"), "Asia/Tel_Aviv": ("IST", "IDT"), "Europe/Moscow": ("MSK", "MSK"),
            "Europe/Istanbul": ("TRT", "TRT"), "Asia/Tokyo": ("JST", "JST"), "Asia/Seoul": ("KST", "KST"),
            "Asia/Hong_Kong": ("HKT", "HKT"), "Asia/Singapore": ("SGT", "SGT"), "Asia/Kolkata": ("IST", "IST"),
            "Asia/Calcutta": ("IST", "IST"), "Asia/Karachi": ("PKT", "PKT"), "Asia/Bangkok": ("ICT", "ICT"),
            "Asia/Ho_Chi_Minh": ("ICT", "ICT"), "Asia/Saigon": ("ICT", "ICT"), "Asia/Phnom_Penh": ("ICT", "ICT"),
            "Asia/Vientiane": ("ICT", "ICT"), "Asia/Jakarta": ("WIB", "WIB"), "Asia/Manila": ("PHT", "PHT"),
            "Asia/Kuala_Lumpur": ("MYT", "MYT"), "Asia/Kathmandu": ("NPT", "NPT"), "Asia/Dubai": ("GST", "GST"),
            "Asia/Muscat": ("GST", "GST"), "Asia/Tehran": ("IRST", "IRST"), "Asia/Kabul": ("AFT", "AFT"),
            "Australia/Sydney": ("AEST", "AEDT"), "Australia/Melbourne": ("AEST", "AEDT"), "Australia/Hobart": ("AEST", "AEDT"),
            "Australia/Canberra": ("AEST", "AEDT"), "Australia/ACT": ("AEST", "AEDT"), "Australia/Brisbane": ("AEST", "AEST"),
            "Australia/Adelaide": ("ACST", "ACDT"), "Australia/Darwin": ("ACST", "ACST"), "Australia/Perth": ("AWST", "AWST"),
            "Pacific/Auckland": ("NZST", "NZDT"), "America/Sao_Paulo": ("BRT", "BRT"), "America/Argentina/Buenos_Aires": ("ART", "ART"),
            "America/Buenos_Aires": ("ART", "ART"), "America/Bogota": ("COT", "COT"), "America/Lima": ("PET", "PET"),
            "America/Santiago": ("CLT", "CLST"), "Africa/Johannesburg": ("SAST", "SAST"), "Africa/Nairobi": ("EAT", "EAT"),
            "Africa/Lagos": ("WAT", "WAT"), "Africa/Cairo": ("EET", "EEST"), "Africa/Maputo": ("CAT", "CAT"),
            "Africa/Harare": ("CAT", "CAT"), "Africa/Addis_Ababa": ("EAT", "EAT"), "Africa/Casablanca": ("WET", "WEST")
        ]
        for city in ["Paris", "Berlin", "Madrid", "Rome", "Amsterdam", "Brussels", "Vienna", "Prague", "Warsaw", "Stockholm",
                     "Oslo", "Copenhagen", "Zurich", "Budapest", "Belgrade", "Zagreb", "Ljubljana", "Bratislava", "Luxembourg",
                     "Monaco", "Malta", "Tirane", "Sarajevo", "Skopje", "Podgorica", "Andorra", "Gibraltar", "Vaduz",
                     "San_Marino", "Vatican", "Busingen"] {
            table["Europe/" + city] = ("CET", "CEST")
        }
        for city in ["Athens", "Helsinki", "Kyiv", "Kiev", "Bucharest", "Sofia", "Riga", "Tallinn", "Vilnius", "Chisinau", "Nicosia"] {
            table["Europe/" + city] = ("EET", "EEST")
        }
        table["Asia/Nicosia"] = ("EET", "EEST"); table["Asia/Beirut"] = ("EET", "EEST")
        return table
    }()

    /// Names that aren't the last part of a zone's identifier: countries, states, big cities that share
    /// a zone with another, and the names US zones go by.
    private static let named: [String: String] = {
        var table: [String: String] = [:]
        func add(_ id: String, _ names: String) {
            for name in names.split(separator: ",") { table[name.trimmingCharacters(in: .whitespaces)] = id }
        }
        add("America/Los_Angeles", "pt, pacific, pacific standard, pacific daylight, west coast, california, san francisco, sf, bay area, silicon valley, seattle, portland, las vegas, san diego, san jose, sacramento, oregon, nevada, washington state, hollywood, la")
        add("America/Denver", "mt, mountain, colorado, utah, salt lake city, albuquerque, new mexico, wyoming, montana, idaho")
        add("America/Phoenix", "arizona")
        add("America/Chicago", "ct, central, texas, dallas, houston, austin, san antonio, minneapolis, minnesota, new orleans, nashville, st louis, saint louis, kansas city, milwaukee, illinois, missouri, tennessee, oklahoma, iowa, wisconsin, louisiana, alabama")
        add("America/New_York", "et, eastern, east coast, nyc, new york city, manhattan, brooklyn, boston, washington dc, washington, dc, miami, atlanta, philadelphia, pittsburgh, orlando, charlotte, baltimore, florida, massachusetts, new jersey, pennsylvania, ohio, virginia, north carolina, south carolina, maryland, connecticut, us, usa, united states, united states of america, america")
        add("America/Detroit", "michigan")
        add("America/Anchorage", "akt, alaska")
        add("Pacific/Honolulu", "ht, hawaii")
        add("America/Halifax", "atlantic, nova scotia")
        add("America/St_Johns", "newfoundland")
        add("America/Toronto", "canada, ontario, montreal, ottawa, quebec")
        add("America/Edmonton", "calgary, alberta")
        add("America/Vancouver", "british columbia")
        add("America/Mexico_City", "mexico")
        add("America/Sao_Paulo", "brazil, rio, rio de janeiro, brasilia")
        add("America/Argentina/Buenos_Aires", "argentina, buenos aires")
        add("America/Santiago", "chile")
        add("America/Bogota", "colombia")
        add("America/Lima", "peru")
        add("America/Caracas", "venezuela")
        add("America/Guayaquil", "ecuador, quito")
        add("America/Havana", "cuba")
        add("Europe/London", "uk, united kingdom, britain, great britain, gb, england, scotland, wales, northern ireland, manchester, birmingham, edinburgh, glasgow, cardiff, liverpool, leeds, bristol, oxford, cambridge, newcastle, sheffield, nottingham, brighton")
        add("Europe/Dublin", "ireland, eire, cork")
        add("Europe/Paris", "france, lyon, marseille, nice, toulouse, bordeaux")
        add("Europe/Berlin", "germany, munich, frankfurt, hamburg, cologne, dusseldorf, stuttgart")
        add("Europe/Madrid", "spain, barcelona, valencia, seville, malaga")
        add("Europe/Rome", "italy, milan, florence, venice, naples, turin")
        add("Europe/Lisbon", "portugal, porto")
        add("Europe/Amsterdam", "netherlands, holland, the netherlands, rotterdam, the hague, utrecht")
        add("Europe/Brussels", "belgium, antwerp, ghent")
        add("Europe/Zurich", "switzerland, geneva, basel, bern, lausanne")
        add("Europe/Vienna", "austria, salzburg")
        add("Europe/Warsaw", "poland, krakow, cracow, gdansk, wroclaw, poznan, lodz, katowice, szczecin, lublin, bydgoszcz")
        add("Europe/Prague", "czechia, czech republic, brno")
        add("Europe/Bratislava", "slovakia")
        add("Europe/Budapest", "hungary")
        add("Europe/Bucharest", "romania, cluj")
        add("Europe/Sofia", "bulgaria")
        add("Europe/Athens", "greece, thessaloniki")
        add("Europe/Istanbul", "turkey, turkiye, ankara, izmir")
        add("Europe/Kyiv", "ukraine, kyiv, kiev, lviv, odesa, odessa, kharkiv")
        add("Europe/Moscow", "russia, st petersburg, saint petersburg")
        add("Europe/Stockholm", "sweden, gothenburg")
        add("Europe/Oslo", "norway, bergen")
        add("Europe/Copenhagen", "denmark")
        add("Europe/Helsinki", "finland")
        add("Atlantic/Reykjavik", "iceland")
        add("Europe/Tallinn", "estonia")
        add("Europe/Riga", "latvia")
        add("Europe/Vilnius", "lithuania")
        add("Europe/Zagreb", "croatia, split, dubrovnik")
        add("Europe/Belgrade", "serbia")
        add("Europe/Ljubljana", "slovenia")
        add("Asia/Nicosia", "cyprus")
        add("Europe/Malta", "malta")
        add("Asia/Jerusalem", "israel, tel aviv")
        add("Africa/Cairo", "egypt")
        add("Asia/Riyadh", "saudi arabia, saudi, mecca, jeddah")
        add("Asia/Dubai", "uae, united arab emirates, emirates, abu dhabi")
        add("Asia/Qatar", "qatar, doha")
        add("Asia/Tehran", "iran")
        add("Asia/Baghdad", "iraq")
        add("Asia/Karachi", "pakistan, lahore, islamabad")
        add("Asia/Kolkata", "india, mumbai, bombay, delhi, new delhi, bangalore, bengaluru, chennai, hyderabad, pune, goa")
        add("Asia/Dhaka", "bangladesh")
        add("Asia/Kathmandu", "nepal")
        add("Asia/Colombo", "sri lanka")
        add("Asia/Shanghai", "china, beijing, shenzhen, guangzhou, hangzhou, chengdu, wuhan, xian")
        add("Asia/Taipei", "taiwan")
        add("Asia/Tokyo", "japan, osaka, kyoto, yokohama, nagoya, sapporo, fukuoka")
        add("Asia/Seoul", "korea, south korea, busan")
        add("Asia/Pyongyang", "north korea")
        add("Asia/Kuala_Lumpur", "malaysia")
        add("Asia/Bangkok", "thailand, phuket")
        add("Asia/Ho_Chi_Minh", "vietnam, hanoi, saigon")
        add("Asia/Manila", "philippines")
        add("Asia/Jakarta", "indonesia")
        add("Asia/Makassar", "bali")
        add("Australia/Sydney", "australia, aet, canberra, nsw, new south wales")
        add("Australia/Melbourne", "victoria")
        add("Australia/Brisbane", "queensland, gold coast")
        add("Pacific/Auckland", "new zealand, nz, nzt, wellington, christchurch")
        add("Africa/Johannesburg", "south africa, cape town, durban, pretoria")
        add("Africa/Lagos", "nigeria, abuja")
        add("Africa/Nairobi", "kenya")
        add("Africa/Addis_Ababa", "ethiopia")
        add("Africa/Casablanca", "morocco, marrakech, rabat")
        add("Africa/Accra", "ghana")
        add("Asia/Singapore", "singapore")
        add("Asia/Hong_Kong", "hong kong, hk")
        return table
    }()

    /// The last part of every zone's identifier, "tokyo" for Asia/Tokyo, unless two zones share it.
    private static let cities: [String: String] = {
        var zones: [String: String] = [:], ambiguous = Set<String>()
        for id in TimeZone.knownTimeZoneIdentifiers where !id.hasPrefix("Etc/") {
            let name = id.lowercased().replacingOccurrences(of: "_", with: " ")
            zones[name] = id
            guard let leaf = name.split(separator: "/").last.map(String.init) else { continue }
            if zones[leaf] != nil { ambiguous.insert(leaf) } else { zones[leaf] = id }
        }
        for key in ambiguous { zones.removeValue(forKey: key) }
        return zones
    }()
}
