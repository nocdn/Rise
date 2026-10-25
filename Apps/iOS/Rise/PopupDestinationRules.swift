import Foundation
import CryptoKit

/// Popup-only AdGuard Base/EasyList and Mobile Ads rules. Ordinary browsing and
/// resource requests never enter this matcher; exceptions override blocking rules.
struct PopupDestinationRules {
    private struct Catalog: Decodable { let rules: [Rule] }
    struct Rule: Codable, Sendable {
        let pattern: String, exception: Bool, include: [String], exclude: [String]
        let party: Int, matchCase: Bool, important: Bool
        var original: String? = nil
    }
    private struct Compiled {
        let rule: Rule
        let regex: NSRegularExpression
    }
    private let rules: [Compiled]
    private(set) var catalogID = "custom"
    struct Match: Codable, Sendable {
        let index: Int
        let filter: String?
        let pattern: String
        let important: Bool
        let party: Int
    }
    struct Evaluation: Codable, Sendable {
        let blocked: Bool
        let catalogID: String
        let thirdParty: Bool
        let blockingCount: Int
        let exceptionCount: Int
        let blocking: [Match]
        let exceptions: [Match]
    }

    static let bundled: PopupDestinationRules = {
        guard let url = Bundle.main.url(forResource: "popup-rules", withExtension: "json"),
              let data = try? Data(contentsOf: url), let rules = try? PopupDestinationRules(data: data) else {
            assertionFailure("Missing bundled popup rules")
            return PopupDestinationRules(rules: [])
        }
        return rules
    }()

    private struct InvalidPattern: Error {}
    init(data: Data) throws {
        let decoded = try JSONDecoder().decode(Catalog.self, from: data).rules
        self.init(rules: decoded)
        guard rules.count == decoded.count else { throw InvalidPattern() }
        catalogID = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    init(rules: [Rule]) {
        self.rules = rules.compactMap { rule in
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.matchCase ? [] : .caseInsensitive) else { return nil }
            return Compiled(rule: rule, regex: regex)
        }
    }
    var count: Int { rules.count }

    static func host(_ url: URL?) -> String {
        (url?.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    private static func matches(_ domain: String, host: String, permissiveEntity: Bool = false) -> Bool {
        if domain.hasSuffix(".*") {
            // Entity exceptions deliberately err toward allowing a legitimate link.
            let label = String(domain.dropLast(2))
            if permissiveEntity { return host.hasPrefix(label+".") || host.contains("."+label+".") }
            // Do not apply a blocking entity to a lookalike such as kat.com.evil.
            // Unknown multi-label suffixes are conservatively left unblocked.
            let labels = host.split(separator: ".")
            let commonSecondLevels: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
            let suffixCount = labels.count >= 3 && labels.last?.count == 2 && commonSecondLevels.contains(String(labels[labels.count-2])) ? 2 : 1
            let prefix = labels.dropLast(suffixCount).joined(separator: ".")
            return prefix == label || prefix.hasSuffix("."+label)
        }
        return host == domain || host.hasSuffix("."+domain)
    }
    static func sameParty(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return true }
        if a == b || a.hasSuffix("."+b) || b.hasSuffix("."+a) { return true }
        // Conservatively treat a shared two-label suffix as first party. This can
        // miss an ad between two co.uk sites, but never blocks sibling sign-in hosts
        // because of an incomplete hand-maintained public-suffix list.
        let left = a.split(separator: "."), right = b.split(separator: ".")
        return left.count > 1 && right.count > 1 && left.suffix(2) == right.suffix(2)
    }
    static func canonical(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        parts.user = nil; parts.password = nil; parts.fragment = nil
        if parts.host != nil { parts.host = host(url) }
        return parts.url ?? url
    }
    func blocks(_ destination: URL, from source: URL?) -> Bool {
        evaluate(destination, from: source).blocked
    }
    func evaluate(_ destination: URL, from source: URL?) -> Evaluation {
        let url = Self.canonical(destination).absoluteString
        let host = Self.host(source), thirdParty = !Self.sameParty(host, Self.host(destination))
        let range = NSRange(url.startIndex..., in: url)
        var blocked = false, excepted = false, important = false
        var blocking: [Match] = [], exceptions: [Match] = []
        var blockingCount = 0, exceptionCount = 0
        for (index, entry) in rules.enumerated() {
            let rule = entry.rule
            guard (rule.include.isEmpty || rule.include.contains { Self.matches($0, host: host, permissiveEntity: rule.exception) }),
                  !rule.exclude.contains(where: { Self.matches($0, host: host, permissiveEntity: true) }),
                  rule.party == 0 || (rule.party == 1 ? thirdParty : !thirdParty),
                  entry.regex.firstMatch(in: url, range: range) != nil else { continue }
            let match = Match(index: index, filter: rule.original, pattern: rule.pattern, important: rule.important, party: rule.party)
            if rule.exception {
                excepted = true; exceptionCount += 1
                if exceptions.count < 8 { exceptions.append(match) }
            } else {
                blocked = true; blockingCount += 1; important = important || rule.important
                if blocking.count < 8 { blocking.append(match) }
            }
        }
        return Evaluation(blocked: important || (blocked && !excepted), catalogID: catalogID, thirdParty: thirdParty,
            blockingCount: blockingCount, exceptionCount: exceptionCount, blocking: blocking, exceptions: exceptions)
    }
}
