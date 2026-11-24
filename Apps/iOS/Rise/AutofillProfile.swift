import Contacts
import CoreLocation
import Foundation
import Security

/// What Autofill My Information fills into forms: a copy of the person's own contact card, taken
/// when they pick it from the system's contact picker. The picker hands over only the card picked,
/// without asking for access to Contacts, so the copy stays as it was until it's picked again.
struct AutofillProfile: Codable, Equatable {
    struct Labeled: Codable, Equatable {
        var label: String
        var value: String
        /// Added in Rise rather than copied from the card, so picking the card again keeps it.
        var added: Bool? = nil
    }
    struct Phone: Codable, Equatable {
        var label: String
        var number: String
        /// The country it's dialled in when it's written without one, as ISO 3166 ("gb").
        var region: String?
        /// Added in Rise rather than copied from the card, so picking the card again keeps it.
        var added: Bool? = nil
    }
    /// What Autofill Information edits of the card's one-of-a-kind details, the address's being
    /// its first address's.
    enum Detail: String, CaseIterable {
        case namePrefix, givenName, middleName, familyName, organization, jobTitle, birthday
        case line1, line2, city, county, postalCode, country
        static let address: [Detail] = [.line1, .line2, .city, .county, .postalCode, .country]
    }
    struct Address: Codable, Equatable {
        var label: String
        /// Lines as the card has them, the first first.
        var street: String
        var subLocality: String
        var city: String
        var subAdministrativeArea: String
        var state: String
        var postalCode: String
        var country: String
        /// ISO 3166 alpha-2, lowercased as Contacts keeps it ("gb").
        var isoCountryCode: String
        /// A UK address's county as Apple's maps have it ("Essex"), looked up when the card has none
        /// of its own: nil until it's been looked up, empty if none was found.
        var lookedUpCounty: String? = nil

        /// The UK's nations, which Apple's address search writes as a UK address's county.
        static let nations: Set<String> = ["england", "scotland", "wales", "northern ireland", "cymru", "alba"]

        var isUK: Bool {
            isoCountryCode.isEmpty ? ["united kingdom", "uk", "great britain"].contains(country.lowercased()) : isoCountryCode == "gb"
        }

        /// Its county: the card's own, unless that's only the UK nation ("England"), and then the
        /// one looked up for it.
        var county: String {
            if !subAdministrativeArea.isEmpty { return subAdministrativeArea }
            if !state.isEmpty, !(isUK && Self.nations.contains(state.lowercased())) { return state }
            return lookedUpCounty ?? ""
        }

        /// What a form's state, province or county takes: in the UK, the county where it's known
        /// (Essex, not England), and elsewhere the state.
        var region: String { isUK && !county.isEmpty ? county : state }

        /// A UK address whose card names no county, and that hasn't been looked up yet.
        var needsCountyLookup: Bool { isUK && county.isEmpty && lookedUpCounty == nil && !(street+city+postalCode).isEmpty }

        /// The street's first line.
        var line1: String {
            get { lines.first ?? "" }
            set { lines = [newValue]+lines.dropFirst() }
        }

        /// The street's second line, or its locality where the card keeps that apart (Great Baddow).
        var line2: String {
            get { lines.count > 1 ? lines[1] : subLocality }
            set {
                if lines.count > 1 || subLocality.isEmpty {
                    var lines = self.lines
                    if lines.isEmpty { lines = [""] }
                    if lines.count > 1 { lines[1] = newValue } else { lines.append(newValue) }
                    self.lines = lines
                } else {
                    subLocality = newValue
                }
            }
        }

        private var lines: [String] {
            get {
                street.isEmpty ? [] : street.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            set {
                // Empty lines go, but not the first while a second follows it.
                var lines = newValue.map { $0.trimmingCharacters(in: .whitespaces) }
                while lines.last?.isEmpty == true { lines.removeLast() }
                street = lines.enumerated().filter { $0.offset == 0 || !$0.element.isEmpty }.map(\.element).joined(separator: "\n")
            }
        }

        /// The county as Autofill Information shows it: as forms' county fields get it.
        var shownCounty: String { county.isEmpty ? state : county }

        subscript(detail: Detail) -> String {
            get {
                switch detail {
                case .line1: line1
                case .line2: line2
                case .city: city
                case .county: shownCounty
                case .postalCode: postalCode
                case .country: country
                default: ""
                }
            }
            set {
                switch detail {
                case .line1: line1 = newValue
                case .line2: line2 = newValue
                case .city: city = newValue
                // Typed in, it's the county, whatever the card or the lookup said.
                case .county: state = newValue; subAdministrativeArea = ""; lookedUpCounty = ""
                case .postalCode: postalCode = newValue
                case .country: country = newValue
                default: break
                }
            }
        }

        /// The same place, for keeping its looked-up county when the card's picked again.
        func isSamePlace(as other: Address) -> Bool {
            street == other.street && city == other.city && postalCode == other.postalCode
                && state == other.state && isoCountryCode == other.isoCountryCode
        }

        static func empty(label: String = "Home") -> Address {
            Address(label: label, street: "", subLocality: "", city: "", subAdministrativeArea: "", state: "",
                    postalCode: "", country: "", isoCountryCode: "")
        }
    }
    struct Birthday: Codable, Equatable {
        var day: Int
        var month: Int
        var year: Int?
    }

    var namePrefix = "", givenName = "", middleName = "", familyName = "", nameSuffix = "", nickname = ""
    var organization = "", jobTitle = ""
    var emails: [Labeled] = []
    /// Websites and profiles: LinkedIn, GitHub and the like, as job applications ask for.
    var urls: [Labeled] = []
    var phones: [Phone] = []
    var addresses: [Address] = []
    var birthday: Birthday?
    /// What was typed or chosen in Rise, which picking the card again keeps where the card has none.
    var edited: Set<String> = []

    var isEmpty: Bool {
        [namePrefix, givenName, middleName, familyName, nameSuffix, nickname, organization, jobTitle].allSatisfy(\.isEmpty)
            && emails.isEmpty && urls.isEmpty && phones.isEmpty && addresses.isEmpty && birthday == nil
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String { (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil ?? "" }
        namePrefix = text(.namePrefix); givenName = text(.givenName); middleName = text(.middleName)
        familyName = text(.familyName); nameSuffix = text(.nameSuffix); nickname = text(.nickname)
        organization = text(.organization); jobTitle = text(.jobTitle)
        emails = (try? values.decodeIfPresent([Labeled].self, forKey: .emails)) ?? nil ?? []
        urls = (try? values.decodeIfPresent([Labeled].self, forKey: .urls)) ?? nil ?? []
        phones = (try? values.decodeIfPresent([Phone].self, forKey: .phones)) ?? nil ?? []
        addresses = (try? values.decodeIfPresent([Address].self, forKey: .addresses)) ?? nil ?? []
        birthday = (try? values.decodeIfPresent(Birthday.self, forKey: .birthday)) ?? nil
        edited = (try? values.decodeIfPresent(Set<String>.self, forKey: .edited)) ?? nil ?? []
    }

    subscript(detail: Detail) -> String {
        get {
            switch detail {
            case .namePrefix: namePrefix
            case .givenName: givenName
            case .middleName: middleName
            case .familyName: familyName
            case .organization: organization
            case .jobTitle: jobTitle
            case .birthday: ""
            default: addresses.first?[detail] ?? ""
            }
        }
        set {
            switch detail {
            case .namePrefix: namePrefix = newValue
            case .givenName: givenName = newValue
            case .middleName: middleName = newValue
            case .familyName: familyName = newValue
            case .organization: organization = newValue
            case .jobTitle: jobTitle = newValue
            case .birthday: break
            default:
                if addresses.isEmpty { addresses = [.empty()] }
                addresses[0][detail] = newValue
            }
        }
    }

    /// Sets a detail as it was typed in Rise, remembering that it was.
    mutating func set(_ detail: Detail, to value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self[detail] != value else { return }
        self[detail] = value
        edited.insert(detail.rawValue)
    }

    /// The card picked again, over this copy: whatever the card has replaces what's here, while
    /// what was typed or added in Rise that the card hasn't stays.
    func refreshed(with card: AutofillProfile) -> AutofillProfile {
        var merged = card
        merged.edited = []
        let mine = edited
        for detail in Detail.allCases where mine.contains(detail.rawValue) {
            switch detail {
            case .birthday:
                guard card.birthday == nil, let birthday else { continue }
                merged.birthday = birthday
            default:
                let value = self[detail]
                // A card's county that's only the nation ("England") is no county.
                let theirs = detail == .county ? card.addresses.first?.county ?? "" : card[detail]
                guard theirs.isEmpty, !value.isEmpty else { continue }
                if Detail.address.contains(detail), merged.addresses.isEmpty, let first = addresses.first {
                    merged.addresses = [.empty(label: first.label)]
                }
                merged[detail] = value
                if detail == .country, let first = addresses.first { merged.addresses[0].isoCountryCode = first.isoCountryCode }
            }
            merged.edited.insert(detail.rawValue)
        }
        // Its county, looked up already, if it's still the same place.
        if let first = addresses.first, let theirs = merged.addresses.first, first.isSamePlace(as: theirs), theirs.lookedUpCounty == nil {
            merged.addresses[0].lookedUpCounty = first.lookedUpCounty
        }
        func key(_ value: String) -> String { value.lowercased().filter { !$0.isWhitespace } }
        func digits(_ value: String) -> String { value.filter(\.isNumber) }
        merged.emails += emails.filter { email in email.added == true && !card.emails.contains { key($0.value) == key(email.value) } }
        merged.urls += urls.filter { url in url.added == true && !card.urls.contains { key($0.value) == key(url.value) } }
        merged.phones += phones.filter { phone in phone.added == true && !card.phones.contains { digits($0.number) == digits(phone.number) } }
        return merged
    }

    /// Every detail the card has that a form might ask for. The picker's copy carries them all,
    /// but each is checked first, as reading one that wasn't fetched throws.
    init(contact: CNContact, region: String? = Locale.current.region?.identifier) {
        func string(_ key: String, _ value: @autoclosure () -> String) -> String {
            contact.isKeyAvailable(key) ? value().trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
        namePrefix = string(CNContactNamePrefixKey, contact.namePrefix)
        givenName = string(CNContactGivenNameKey, contact.givenName)
        middleName = string(CNContactMiddleNameKey, contact.middleName)
        familyName = string(CNContactFamilyNameKey, contact.familyName)
        nameSuffix = string(CNContactNameSuffixKey, contact.nameSuffix)
        nickname = string(CNContactNicknameKey, contact.nickname)
        organization = string(CNContactOrganizationNameKey, contact.organizationName)
        jobTitle = string(CNContactJobTitleKey, contact.jobTitle)
        if contact.isKeyAvailable(CNContactEmailAddressesKey) {
            emails = contact.emailAddresses.compactMap { email in
                let value = (email.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : Labeled(label: Self.label(email.label), value: value)
            }
        }
        if contact.isKeyAvailable(CNContactUrlAddressesKey) {
            urls = contact.urlAddresses.compactMap { url in
                let value = (url.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : Labeled(label: Self.label(url.label), value: value)
            }
        }
        if contact.isKeyAvailable(CNContactPostalAddressesKey) {
            addresses = contact.postalAddresses.map { labeled in
                let address = labeled.value
                func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
                return Address(label: Self.label(labeled.label), street: clean(address.street), subLocality: clean(address.subLocality),
                               city: clean(address.city), subAdministrativeArea: clean(address.subAdministrativeArea),
                               state: clean(address.state), postalCode: clean(address.postalCode),
                               country: clean(address.country), isoCountryCode: clean(address.isoCountryCode).lowercased())
            }.filter { !($0.street+$0.city+$0.postalCode+$0.state+$0.country).isEmpty }
        }
        // A number without a country is dialled where the card's first address is, or else here.
        let home = addresses.first.map(\.isoCountryCode).flatMap { $0.isEmpty ? nil : $0 } ?? region?.lowercased()
        if contact.isKeyAvailable(CNContactPhoneNumbersKey) {
            phones = contact.phoneNumbers.compactMap { phone in
                let number = phone.value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return number.isEmpty ? nil : Phone(label: Self.label(phone.label), number: number, region: home)
            }
        }
        if contact.isKeyAvailable(CNContactBirthdayKey), let birthday = contact.birthday,
           let day = birthday.day, let month = birthday.month, (1...31).contains(day), (1...12).contains(month) {
            // A birthday saved without its year has NSDateComponentUndefined there.
            let year = birthday.year.flatMap { (1...9999).contains($0) ? $0 : nil }
            self.birthday = Birthday(day: day, month: month, year: year)
        }
    }

    /// Contacts' own name for a label ("home", "iCloud"), capitalised as the menu shows it.
    private static func label(_ label: String?) -> String {
        guard let label, !label.isEmpty else { return "" }
        let name = CNLabeledValue<NSString>.localizedString(forLabel: label)
        return name.prefix(1).uppercased()+name.dropFirst()
    }
}

/// Whether Autofill My Information is on, and the card it fills from, kept in this device's
/// Keychain rather than the app's files, as the AI keys are.
@MainActor final class AutofillStore {
    static let shared = AutofillStore()
    static let didChange = Notification.Name("AutofillStore.didChange")
    private static let enabledKey = "AutofillMyInformation"
    private let defaults: UserDefaults
    private let service: String
    private var cached: AutofillProfile??
    private var lookingUpCounties = false

    init(defaults: UserDefaults = .standard, service: String = "dev.bartosz.Rise.autofill") {
        self.defaults = defaults
        self.service = service
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    /// The card's copy, if one's been picked. Read once, then kept; a read the Keychain refuses
    /// (the phone still locked since it started) isn't kept, so the next one tries again.
    var profile: AutofillProfile? {
        if let cached { return cached }
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let profile = (result as? Data).flatMap { try? JSONDecoder().decode(AutofillProfile.self, from: $0) }
            cached = .some(profile)
            return profile
        case errSecItemNotFound:
            cached = .some(nil)
            return nil
        default:
            return nil
        }
    }

    var hasCard: Bool { profile != nil }

    /// On, with a card to fill from.
    var isActive: Bool { isEnabled && profile.map { !$0.isEmpty } == true }

    func save(_ profile: AutofillProfile) throws {
        let data = try JSONEncoder().encode(profile)
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(item.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.save }
        cached = .some(profile)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Finds the county of each UK address on the card that names none (its County left empty or
    /// only the nation, "England", as Apple's address search writes it), as Maps has it, so forms'
    /// county, state or province get "Essex". The address goes to Apple's maps once, as it would
    /// typed into Maps; a lookup that can't reach them is tried again when Rise is next opened.
    func lookUpCounties() {
        guard isEnabled, !lookingUpCounties, let profile, profile.addresses.contains(where: \.needsCountyLookup) else { return }
        lookingUpCounties = true
        Task {
            defer { lookingUpCounties = false }
            for address in profile.addresses where address.needsCountyLookup {
                guard let county = await Self.county(of: address) else { continue }
                // Saved only into the card it was looked up for, still as it was.
                guard var current = self.profile, let index = current.addresses.firstIndex(of: address) else { return }
                current.addresses[index].lookedUpCounty = county
                try? save(current)
            }
        }
    }

    /// The county Apple's maps put the address in, empty if they found no such place in the UK, or
    /// nil if they couldn't be reached. The whole address first, as a postcode can straddle a
    /// county's edge, then only its town and postcode, for a street they don't know ("Flat 2…").
    nonisolated private static func county(of address: AutofillProfile.Address) async -> String? {
        func postal(withStreet: Bool) -> CNPostalAddress {
            let postal = CNMutablePostalAddress()
            if withStreet { postal.street = address.street; postal.subLocality = address.subLocality }
            postal.city = address.city
            postal.postalCode = address.postalCode
            postal.country = address.country
            postal.isoCountryCode = address.isoCountryCode
            return postal
        }
        var attempts = [postal(withStreet: true)]
        if !(address.street+address.subLocality).isEmpty, !(address.city+address.postalCode).isEmpty { attempts.append(postal(withStreet: false)) }
        for attempt in attempts {
            do {
                let places = try await CLGeocoder().geocodePostalAddress(attempt)
                if let county = places.first(where: { $0.isoCountryCode?.uppercased() == "GB" })?.subAdministrativeArea, !county.isEmpty {
                    return county
                }
            } catch let error as CLError where [.geocodeFoundNoResult, .geocodeFoundPartialResult].contains(error.code) {
                continue
            } catch {
                return nil
            }
        }
        return ""
    }

    /// Forgets the card: Rise keeps no other copy of it.
    func revoke() {
        SecItemDelete(item as CFDictionary)
        cached = .some(nil)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "contact-card"]
    }

    enum Failure: LocalizedError {
        case save
        var errorDescription: String? { "Rise couldn’t keep your contact card securely. Please try again." }
    }
}
