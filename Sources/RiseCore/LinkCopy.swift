import Foundation

/// What a link's context menu copies: the email address of a `mailto:` link, the phone number of
/// one that calls or texts, a map link's coordinates, or else the link itself. On the Mac's menu
/// for a link and the iPhone's for a held one.
public struct LinkCopy: Equatable, Sendable {
    /// "Copy Email Address", "Copy Phone Number"… or "Copy Link".
    public let title: String
    /// The address, number or coordinates alone, or nil to copy the link.
    public let text: String?
    /// The SF Symbol for what's copied: an envelope, a phone, a pin…
    public let symbol: String
    /// A link that's a file to fetch; one that writes an email or rings a number isn't.
    public var isDownloadable: Bool { text == nil }

    private static let phoneSchemes: Set = ["tel", "telprompt", "callto", "sms", "smsto", "mms", "mmsto", "imessage"]
    private static let faceTimeSchemes: Set = ["facetime", "facetime-audio", "facetime-group"]

    public init(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "mailto":
            self = Self.listed(Self.target(of: url, cuttingAt: "?#"), noun: "Email Address")
        case _ where Self.phoneSchemes.contains(scheme):
            self = Self.listed(Self.target(of: url, cuttingAt: "?#;"), noun: "Phone Number")
        case _ where Self.faceTimeSchemes.contains(scheme):
            let target = Self.target(of: url, cuttingAt: "?#;")
            self = Self.listed(target, noun: target.contains("@") ? "Email Address" : "Phone Number")
        case "geo":
            // `geo:37.78,-122.41;u=35`, or `geo:0,0?q=…` for a place by its address.
            let coordinates = Self.target(of: url, cuttingAt: "?#;")
            let query = URLComponents(string: url.absoluteString.replacingOccurrences(of: "geo:", with: "geo://", options: [.anchored, .caseInsensitive]))?
                .queryItems?.first { $0.name == "q" }?.value?.trimmingCharacters(in: .whitespaces)
            if let query, !query.isEmpty, coordinates.split(separator: ",").allSatisfy({ Double($0) == 0 }) {
                self.init(title: "Copy Address", text: query, symbol: "mappin.and.ellipse")
            } else if !coordinates.isEmpty {
                self.init(title: "Copy Coordinates", text: coordinates, symbol: "location")
            } else { self = .link }
        default:
            self = .link
        }
    }
    private init(title: String, text: String?, symbol: String) { self.title = title; self.text = text; self.symbol = symbol }
    private static let link = LinkCopy(title: "Copy Link", text: nil, symbol: "link")

    /// What follows the scheme, up to the first of `stops`, decoded: `a@b.com` from
    /// `mailto:a@b.com?subject=Hi`, `+1 555 0100` from `tel:+1%20555%200100;ext=2`.
    private static func target(of url: URL, cuttingAt stops: String) -> String {
        var rest = Substring(url.absoluteString)
        if let colon = rest.firstIndex(of: ":") { rest = rest[rest.index(after: colon)...] }
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }
        if let stop = rest.firstIndex(where: { stops.contains($0) }) { rest = rest[..<stop] }
        return (String(rest).removingPercentEncoding ?? String(rest)).trimmingCharacters(in: .whitespaces)
    }
    /// One, or several between commas: "Copy Email Addresses".
    private static func listed(_ target: String, noun: String) -> LinkCopy {
        let items = target.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !items.isEmpty else { return .link }
        let plural = noun.hasSuffix("s") ? noun+"es" : noun+"s"
        return LinkCopy(title: "Copy \(items.count > 1 ? plural : noun)", text: items.joined(separator: ", "),
                        symbol: noun == "Email Address" ? "envelope" : "phone")
    }
}
